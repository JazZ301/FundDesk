import Foundation

public enum PositionAction: String, CaseIterable, Codable, Sendable {
    case buy = "申购 / 加仓"
    case sell = "赎回 / 减仓"
    case distribution = "现金分红"
}

public struct PositionRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let action: PositionAction
    public let day: String
    public let shares: Decimal?
    public let price: Decimal?
    public let fee: Decimal
    public let cash: Decimal
    public let realized: Decimal?
}

public enum PositionError: LocalizedError {
    case invalid
    case costMissing
    case tooManyShares
    case positionMissing
    case recordMissing
    case journalBaseUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalid: return "请核对日期、份额、成交净值和费用。"
        case .costMissing: return "已有持仓缺少单位成本。请先填写成本，再记录加仓。"
        case .tooManyShares: return "赎回份额超过目前的持有份额。"
        case .positionMissing: return "该基金已不在本地自选中。"
        case .recordMissing: return "这条流水记录已不存在，请重新打开持仓流水。"
        case .journalBaseUnavailable: return "无法还原这条流水记录之前的持仓，暂时不能修改或删除。"
        }
    }
}

public struct PositionChange {
    public let action: PositionAction
    public let day: String
    public let shares: Decimal?
    public let price: Decimal?
    public let fee: Decimal
    public let distribution: Decimal?

    public init(action: PositionAction, day: String, shares: Decimal? = nil, price: Decimal? = nil,
                fee: Decimal = 0, distribution: Decimal? = nil) {
        self.action = action
        self.day = day
        self.shares = shares
        self.price = price
        self.fee = fee
        self.distribution = distribution
    }

    public func applying(to holding: Holding, now: Date = .now) throws -> (Holding, PositionRecord) {
        guard MarketClock.timestamp(day: day) != nil, day <= MarketClock.day(now), fee >= 0 else {
            throw PositionError.invalid
        }
        var updated = holding
        let balance = holding.shares ?? 0
        let cash: Decimal
        let realized: Decimal?
        switch action {
        case .distribution:
            guard let distribution, distribution > 0 else { throw PositionError.invalid }
            cash = distribution
            realized = distribution
        case .buy:
            guard let shares, let price, shares > 0, price > 0 else { throw PositionError.invalid }
            if balance > 0, holding.costPerShare == nil, !holding.fund.isMoney { throw PositionError.costMissing }
            let paid = shares * price + fee
            updated.shares = balance + shares
            updated.costPerShare = holding.fund.isMoney ? nil
                : ((holding.costPerShare ?? 0) * balance + paid) / (balance + shares)
            cash = -paid
            realized = nil
        case .sell:
            guard let shares, let price, shares > 0, price > 0, fee <= shares * price else {
                throw PositionError.invalid
            }
            guard shares <= balance else { throw PositionError.tooManyShares }
            updated.shares = balance - shares
            if balance == shares { updated.costPerShare = nil }
            cash = shares * price - fee
            realized = holding.costPerShare.map { cash - $0 * shares }
        }
        return (updated, PositionRecord(id: UUID(), action: action, day: day,
                                        shares: shares, price: price, fee: fee, cash: cash, realized: realized))
    }
}

public extension PositionRecord {
    func applying(to holding: Holding) throws -> Holding {
        guard fee >= 0 else { throw PositionError.invalid }
        var updated = holding
        let balance = holding.shares ?? 0
        switch action {
        case .distribution:
            return updated
        case .buy:
            guard let shares, let price, shares > 0, price > 0 else { throw PositionError.invalid }
            if balance > 0, holding.costPerShare == nil, !holding.fund.isMoney {
                throw PositionError.costMissing
            }
            let paid = shares * price + fee
            updated.shares = balance + shares
            updated.costPerShare = holding.fund.isMoney ? nil
                : ((holding.costPerShare ?? 0) * balance + paid) / (balance + shares)
            return updated
        case .sell:
            guard let shares, let price, shares > 0, price > 0, fee <= shares * price else {
                throw PositionError.invalid
            }
            guard shares <= balance else { throw PositionError.tooManyShares }
            updated.shares = balance - shares
            if balance == shares { updated.costPerShare = nil }
            return updated
        }
    }
}

public enum PositionJournalReplay {
    public static func replay(base: Holding, records: [PositionRecord]) throws -> Holding {
        var holding = base
        for record in records {
            holding = try record.applying(to: holding)
        }
        return holding
    }

    public static func inferBase(current: Holding, records: [PositionRecord]) -> Holding? {
        var holding = current
        for record in records.reversed() {
            let after = holding.shares ?? 0
            switch record.action {
            case .distribution:
                continue
            case .buy:
                guard let shares = record.shares, shares > 0,
                      let price = record.price, price > 0, record.fee >= 0,
                      after >= shares else { return nil }
                let before = after - shares
                if before == 0 {
                    holding.shares = 0
                    holding.costPerShare = nil
                } else if holding.fund.isMoney {
                    holding.shares = before
                } else {
                    guard let costAfter = holding.costPerShare else { return nil }
                    let paid = shares * price + record.fee
                    let costBefore = normalizedCost((costAfter * after - paid) / before)
                    guard costBefore > 0 else { return nil }
                    holding.shares = before
                    holding.costPerShare = costBefore
                }
            case .sell:
                guard let shares = record.shares, shares > 0 else { return nil }
                let before = after + shares
                if after == 0, let realized = record.realized, !holding.fund.isMoney {
                    let costBefore = normalizedCost((record.cash - realized) / shares)
                    guard costBefore > 0 else { return nil }
                    holding.costPerShare = costBefore
                }
                holding.shares = before
            }
        }
        return holding
    }

    private static func normalizedCost(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal.zero
        NSDecimalRound(&result, &input, 8, .bankers)
        return result
    }
}

public extension Board {
    mutating func deleteJournalRecord(code: String, recordID: UUID) throws {
        guard let index = holdings.firstIndex(where: { $0.id == code }) else {
            throw PositionError.positionMissing
        }
        guard let records = journals?[code], let recordIndex = records.firstIndex(where: { $0.id == recordID }) else {
            throw PositionError.recordMissing
        }
        guard let base = PositionJournalReplay.inferBase(current: holdings[index], records: records) else {
            throw PositionError.journalBaseUnavailable
        }
        var updatedRecords = records
        updatedRecords.remove(at: recordIndex)
        holdings[index] = try PositionJournalReplay.replay(base: base, records: updatedRecords)
        var updatedJournals = journals ?? [:]
        if updatedRecords.isEmpty {
            updatedJournals.removeValue(forKey: code)
        } else {
            updatedJournals[code] = updatedRecords
        }
        journals = updatedJournals
    }

    mutating func replaceJournalRecord(code: String, recordID: UUID, with change: PositionChange) throws {
        guard let index = holdings.firstIndex(where: { $0.id == code }) else {
            throw PositionError.positionMissing
        }
        guard let records = journals?[code], let recordIndex = records.firstIndex(where: { $0.id == recordID }) else {
            throw PositionError.recordMissing
        }
        guard let base = PositionJournalReplay.inferBase(current: holdings[index], records: records) else {
            throw PositionError.journalBaseUnavailable
        }

        var before = base
        for record in records[..<recordIndex] {
            before = try record.applying(to: before)
        }
        let (_, replacement) = try change.applying(to: before)
        var updatedRecords = records
        updatedRecords[recordIndex] = replacement
        holdings[index] = try PositionJournalReplay.replay(base: base, records: updatedRecords)
        var updatedJournals = journals ?? [:]
        updatedJournals[code] = updatedRecords
        journals = updatedJournals
    }
}
