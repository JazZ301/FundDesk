import Foundation

public struct PlotPoint: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { time }
    public let time: Date
    public let value: Decimal

    public init(time: Date, value: Decimal) {
        self.time = time
        self.value = value
    }
}

public enum HistoryPeriod: String, CaseIterable, Codable, Sendable {
    case month = "近1月"
    case quarter = "近3月"
    case half = "近6月"
    case year = "近1年"
    case threeYears = "近3年"
    case fiveYears = "近5年"
    case sinceStart = "成立以来"

    var months: Int? {
        switch self {
        case .month: return 1
        case .quarter: return 3
        case .half: return 6
        case .year: return 12
        case .threeYears: return 36
        case .fiveYears: return 60
        case .sinceStart: return nil
        }
    }
}

public struct FundHistory: Codable, Sendable {
    public let navs: [NAV]
    public let accumulated: [PlotPoint]
    public let degraded: Bool?
    public let degradationNote: String?

    public var isDegraded: Bool { degraded == true }

    public init(
        navs: [NAV], accumulated: [PlotPoint] = [],
        degraded: Bool? = nil, degradationNote: String? = nil
    ) {
        self.navs = navs.sorted { $0.day < $1.day }
        self.accumulated = accumulated
        self.degraded = degraded
        self.degradationNote = degradationNote
    }

    public func mergingRecent(_ recent: [NAV]) -> FundHistory {
        guard !recent.isEmpty else { return self }
        var byDay = Dictionary(grouping: navs, by: \.day).compactMapValues(\.last)
        var accumulatedByDay = Dictionary(grouping: accumulated, by: { MarketClock.day($0.time) })
            .compactMapValues(\.last)
        for row in recent {
            if byDay[row.day]?.source != "天天基金" || row.source == "天天基金" {
                byDay[row.day] = row
            }
            if let latest = row.cumulativeValue, let time = MarketClock.timestamp(day: row.day) {
                accumulatedByDay[row.day] = PlotPoint(time: time, value: latest)
            }
        }
        return FundHistory(
            navs: Array(byDay.values), accumulated: accumulatedByDay.values.sorted { $0.time < $1.time },
            degraded: degraded, degradationNote: degradationNote
        )
    }

    public func rows(in period: HistoryPeriod) -> [NAV] {
        guard let cut = cutoff(period) else { return navs }
        return navs.filter { $0.day >= cut }
    }

    public func returns(in period: HistoryPeriod, money: Bool) -> [PlotPoint] {
        let slice: ArraySlice<NAV>
        if let cut = cutoff(period), let base = navs.lastIndex(where: { $0.day <= cut }) {
            slice = navs[base...]
        } else {
            slice = navs[...]
        }

        // A missing daily return breaks the chain. Restart from the first known base after the gap.
        var result: [PlotPoint] = []
        var value: Decimal = 1
        var previous: NAV?
        for row in slice {
            defer { previous = row }
            guard let time = MarketClock.timestamp(day: row.day) else { continue }
            if result.isEmpty {
                result.append(PlotPoint(time: time, value: 0))
            } else if let fraction = returnFraction(row, previous: previous, money: money), fraction > -1 {
                value *= 1 + fraction
                result.append(PlotPoint(time: time, value: (value - 1) * 100))
            } else {
                value = 1
                result = [PlotPoint(time: time, value: 0)]
            }
        }
        return result
    }

    private func returnFraction(_ row: NAV, previous: NAV?, money: Bool) -> Decimal? {
        if money { return row.value / 10_000 }
        guard let disclosed = row.rate else { return nil }
        if let base = previous?.value, base > 0 {
            let unrounded = (row.value - base) / base
            // Keep the NAV precision when both values round to the same disclosed daily return.
            // Use the disclosed return when a distribution or split changes that relationship.
            if abs(unrounded * 100 - disclosed) <= Decimal(sign: .plus, exponent: -4, significand: 51) {
                return unrounded
            }
        }
        return disclosed / 100
    }

    private func cutoff(_ period: HistoryPeriod) -> String? {
        guard let months = period.months, let end = navs.last.flatMap({ MarketClock.timestamp(day: $0.day) }),
              let start = MarketClock.calendar.date(byAdding: .month, value: -months, to: end) else { return nil }
        return MarketClock.day(start)
    }
}

public struct FundProfile: Codable, Sendable {
    public struct PeriodResult: Codable, Sendable, Identifiable {
        public var id: String { period }
        public let period: String
        public let rate: Decimal
        public let rank: String?
        public let sample: String?
    }

    public let category: String?
    public let company: String?
    public let managerNames: String?
    public let size: Decimal?
    public let cumulativeNAV: Decimal?
    public let subscription: String?
    public let redemption: String?
    public let originalFee: String?
    public let purchaseFee: String?
    public let recent: [PeriodResult]
}

public struct FundManagerHistory: Codable, Sendable {
    public struct Manager: Codable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let since: String?
        public let education: String?
        public let resume: String?
    }

    public struct Tenure: Codable, Sendable, Identifiable {
        public var id: String { name + " " + (since ?? "") }
        public let name: String
        public let since: String?
        public let end: String?
        public let rate: Decimal?
    }

    public let current: [Manager]
    public let tenures: [Tenure]
}

public struct FundDisclosure: Codable, Sendable {
    public struct Holding: Codable, Sendable, Identifiable {
        public var id: String { type + " " + code }
        public let code: String
        public let name: String
        public let type: String
        public let weight: Decimal
        public let change: String?
        let stockMarket: StockMarket?

        public var stockQuoteSymbol: String? { stockMarket?.quoteSymbol(code: code) }
    }

    public var needsStockMarketRefresh: Bool {
        holdings.contains { $0.type == "股票" && $0.stockMarket == nil }
    }

    public let reportDay: String?
    public let targetCode: String?
    public let targetName: String?
    public let holdings: [Holding]
}

extension MarketProviders {
    public func fundHistory(_ fund: Fund) async throws -> FundHistory {
        async let latest = try? history(for: fund, limit: 20)
        do {
            let data = try await fetch(host: "fund.eastmoney.com", path: "/pingzhongdata/\(fund.code).js")
            let rows = try Self.decodeHistoryScript(data, money: fund.isMoney, limit: 20_000)
            let text = String(decoding: data, as: UTF8.self)
            let cumulative: [PlotPoint]
            if !fund.isMoney, let series = try? Self.scriptArray(text, variable: "Data_ACWorthTrend"),
               let values = try? JSONDecoder().decode([[Decimal]].self, from: series) {
                cumulative = Self.decimalPoints(values)
            } else {
                cumulative = []
            }
            let recent = await latest ?? []
            return FundHistory(navs: rows, accumulated: cumulative).mergingRecent(recent)
        } catch {
            try Task.checkCancellation()
            guard let rows = await latest, !rows.isEmpty else { throw error }
            return FundHistory(
                navs: [], degraded: true,
                degradationNote: "历史净值接口暂时不可用，当前显示最近披露数据。"
            ).mergingRecent(rows)
        }
    }

    public func fundProfile(code: String) async throws -> FundProfile {
        let response = try await fundEndpoint("FundMApi/FundBaseTypeInformation.ashx", code: code)
        return try Self.decodeProfile(response)
    }

    public func fundDisclosure(code: String) async throws -> FundDisclosure {
        let response = try await fundEndpoint("FundMNewApi/FundMNInverstPosition", code: code)
        return try Self.decodeDisclosure(response)
    }

    public func fundManagers(code: String) async throws -> FundManagerHistory {
        async let current = try? fundEndpoint("FundMApi/FundMangerDetail.ashx", code: code)
        async let tenures = try? fundEndpoint("FundMApi/FundManagerList.ashx", code: code)
        return try await Self.decodeManagers(current: current, tenures: tenures)
    }

    private func fundEndpoint(_ path: String, code: String) async throws -> Data {
        guard Fund.validCode(code) else { throw FeedError.incomplete }
        return try await fetch(host: "fundmobapi.eastmoney.com", path: "/" + path, query: [
            "FCODE": code, "deviceid": "Wap", "plat": "Wap", "product": "EFund", "version": "2.0.0"
        ])
    }

    static func decodeProfile(_ data: Data) throws -> FundProfile {
        let root = try json(data)
        guard let value = root["Datas"] as? [String: Any], field(value, "FCODE") != nil else { throw FeedError.incomplete }
        let recent = [
            ("近1月", "SYL_Y", "RANKM", "MSC"), ("近3月", "SYL_3Y", "RANKQ", "QSC"),
            ("近6月", "SYL_6Y", "RANKHY", "HYSC"), ("近1年", "SYL_1N", "RANKY", "YSC")
        ].compactMap { label, rate, rank, sample -> FundProfile.PeriodResult? in
            guard let returns = decimal(field(value, rate)) else { return nil }
            return .init(period: label, rate: returns, rank: field(value, rank), sample: field(value, sample))
        }
        return FundProfile(category: field(value, "FTYPE"), company: field(value, "JJGS"),
                           managerNames: field(value, "JJJL"), size: decimal(field(value, "ENDNAV")),
                           cumulativeNAV: value["FundType"] as? String == "005" || field(value, "FTYPE")?.contains("货币") == true
                           ? nil : decimal(field(value, "LJJZ")),
                           subscription: field(value, "SGZT"), redemption: field(value, "SHZT"),
                           originalFee: field(value, "SOURCERATE"), purchaseFee: field(value, "RATE"), recent: recent)
    }

    static func decodeDisclosure(_ data: Data) throws -> FundDisclosure {
        let root = try json(data)
        guard let value = root["Datas"] as? [String: Any] else { throw FeedError.incomplete }
        let groups = [
            ("fundStocks", "股票", "GPDM", "GPJC", "JZBL"),
            ("fundboods", "债券", "ZQDM", "ZQMC", "ZJZBL"),
            ("fundfofs", "基金", "TZJJDM", "TZJJMC", "ZJZBL")
        ]
        let holdings = groups.flatMap { key, type, code, name, ratio in
            (value[key] as? [[String: Any]] ?? []).compactMap { entry -> FundDisclosure.Holding? in
                guard let code = field(entry, code), let name = field(entry, name),
                      let weight = decimal(field(entry, ratio)), weight >= 0 else { return nil }
                let market = key == "fundStocks"
                    ? StockMarket(exchange: field(entry, "NEWTEXCH"), legacyExchange: field(entry, "TEXCH"))
                    : nil
                let change = [field(entry, "PCTNVCHGTYPE"), field(entry, "PCTNVCHG").map { $0 + " 个百分点" }]
                    .compactMap { $0 }.joined(separator: " ").nilIfEmpty
                return .init(code: code, name: name, type: type, weight: weight,
                             change: change, stockMarket: market)
            }
        }
        let target = field(value, "ETFCODE").flatMap { Fund.validCode($0) ? $0 : nil }
        return FundDisclosure(reportDay: field(root, "Expansion"), targetCode: target,
                              targetName: field(value, "ETFSHORTNAME"), holdings: holdings)
    }

    static func decodeManagers(current: Data?, tenures: Data?) throws -> FundManagerHistory {
        let staff = current.flatMap { try? json($0)["Datas"] as? [[String: Any]] }
        let records = tenures.flatMap { try? json($0)["Datas"] as? [[String: Any]] }
        guard staff != nil || records != nil else { throw FeedError.incomplete }
        let managers = (staff ?? []).compactMap { row -> FundManagerHistory.Manager? in
            guard let id = field(row, "MGRID"), let name = field(row, "MGRNAME") else { return nil }
            return .init(id: id, name: name, since: field(row, "FEMPDATE"),
                         education: field(row, "EDUCATION"), resume: field(row, "RESUME"))
        }
        let history = (records ?? []).compactMap { row -> FundManagerHistory.Tenure? in
            guard let name = field(row, "MGRNAME") else { return nil }
            return .init(name: name, since: field(row, "FEMPDATE"), end: field(row, "LEMPDATE"),
                         rate: decimal(field(row, "PENAVGROWTH")))
        }
        return FundManagerHistory(current: managers, tenures: history)
    }

    static func decimalPoints(_ cells: [[Decimal]]) -> [PlotPoint] {
        cells.compactMap { row in
            guard row.count >= 2 else { return nil }
            return PlotPoint(time: Date(timeIntervalSince1970: NSDecimalNumber(decimal: row[0]).doubleValue / 1_000),
                             value: row[1])
        }.sorted { $0.time < $1.time }
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeedError.incomplete
        }
        return object
    }

    static func field(_ document: [String: Any], _ key: String) -> String? {
        let raw = (document[key] as? String) ?? (document[key] as? NSNumber)?.stringValue
        guard let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !["", "-", "--", "None", "null"].contains(clean) else { return nil }
        return clean
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
