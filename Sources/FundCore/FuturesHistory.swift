import Foundation

public struct FuturesCandle: Codable, Sendable, Identifiable {
    public var id: Date { day }
    public let day: Date
    public let open: Decimal
    public let high: Decimal
    public let low: Decimal
    public let close: Decimal

    public enum Period: Sendable { case daily, weekly, monthly }

    public static func aggregate(_ daily: [Self], period: Period) -> [Self] {
        guard period != .daily else { return daily }
        var calendar = MarketClock.calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let component: Calendar.Component = period == .weekly ? .weekOfYear : .month
        var candles: [Self] = []
        var bucket: Date?
        for bar in daily {
            let interval = calendar.dateInterval(of: component, for: bar.day)?.start
            if interval == bucket, let prior = candles.last {
                candles[candles.count - 1] = Self(day: bar.day, open: prior.open, high: max(prior.high, bar.high),
                                                 low: min(prior.low, bar.low), close: bar.close)
            } else {
                candles.append(bar)
                bucket = interval
            }
        }
        return candles
    }
}

public struct FuturesFiveSessions: Codable, Sendable {
    public let sessions: [Session]
    public let isMinuteSeries: Bool
    public let reference: Decimal?

    public struct Session: Codable, Sendable {
        public let day: Date
        public let prices: [Decimal]
    }
}

extension MarketProviders {
    private struct FuturesHistoryEnvelope<Value: Decodable>: Decodable {
        struct Result: Decodable { let data: Value? }
        let result: Result
    }

    public func futuresDaily(_ instrument: FuturesInstrument) async throws -> [FuturesCandle] {
        try Self.decodeFuturesDaily(await futuresHistory("getGlobalFuturesDailyKLine", instrument: instrument))
    }

    public func futuresFiveSessions(_ instrument: FuturesInstrument, quoteDay: Date?) async throws -> FuturesFiveSessions {
        do {
            let data = try await futuresHistory("getGlobalFutures5MLine", instrument: instrument)
            return try Self.decodeFuturesFiveMinutes(data, instrument: instrument, quoteDay: quoteDay)
        } catch {
            try Task.checkCancellation()
            let candles = try await futuresDaily(instrument)
            return FuturesFiveSessions(
                sessions: candles.suffix(5).map { .init(day: $0.day, prices: [$0.close]) },
                isMinuteSeries: false, reference: candles.dropLast(5).last?.close
            )
        }
    }

    private func futuresHistory(_ method: String, instrument: FuturesInstrument) async throws -> Data {
        try await fetch(host: "stock2.finance.sina.com.cn",
                        path: "/futures/api/openapi.php/GlobalFuturesService." + method,
                        query: ["symbol": instrument.rawValue], referer: "https://finance.sina.com.cn/")
    }

    private struct RawCandle: Decodable {
        let date: String?
        let open: String?
        let high: String?
        let low: String?
        let close: String?
    }

    static func decodeFuturesDaily(_ data: Data) throws -> [FuturesCandle] {
        let response = try JSONDecoder().decode(FuturesHistoryEnvelope<[RawCandle]>.self, from: data)
        var byDay: [Date: FuturesCandle] = [:]
        for row in response.result.data ?? [] {
            guard let date = row.date, let day = MarketClock.timestamp(day: date),
                  let open = decimal(row.open), let close = decimal(row.close),
                  let high = decimal(row.high), let low = decimal(row.low), high >= low else { continue }
            byDay[day] = FuturesCandle(day: day, open: open, high: high, low: low, close: close)
        }
        guard !byDay.isEmpty else { throw FeedError.incomplete }
        return Array(byDay.values.sorted { $0.day < $1.day }.suffix(1_500))
    }

    static func decodeFuturesFiveMinutes(_ data: Data, instrument: FuturesInstrument,
                                        quoteDay: Date?) throws -> FuturesFiveSessions {
        typealias Rows = [String: [[[String?]]]]
        let response = try JSONDecoder().decode(FuturesHistoryEnvelope<Rows>.self, from: data)
        let days = response.result.data?[instrument.rawValue] ?? []
        var sessions: [FuturesFiveSessions.Session] = []
        var reference: Decimal?
        for rows in days {
            guard let first = rows.first, first.count >= 4, let date = first[0],
                  let day = MarketClock.timestamp(day: date),
                  sessions.last.map({ $0.day < day }) != false else { continue }
            let prices = ([first[first.count - 2]] + rows.dropFirst().compactMap { row in
                row.count >= 3 ? row[1] : nil
            }).compactMap { decimal($0) }
            guard prices.count >= 2 else { continue }
            if sessions.isEmpty, first.count >= 5 { reference = decimal(first[1]) }
            sessions.append(.init(day: day, prices: prices))
        }
        let cutoff = MarketClock.calendar.startOfDay(for: quoteDay ?? .now.addingTimeInterval(-3 * 86_400))
        guard sessions.count >= 5, let last = sessions.last, last.day >= cutoff
        else { throw FeedError.incomplete }
        return FuturesFiveSessions(sessions: Array(sessions.suffix(5)), isMinuteSeries: true, reference: reference)
    }
}
