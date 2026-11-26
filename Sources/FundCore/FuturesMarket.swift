import Foundation

public enum FuturesInstrument: String, CaseIterable, Codable, Sendable, Identifiable {
    case vix = "VX"
    case wtiOil = "CL"
    case brentOil = "OIL"
    case gold = "GC"
    case spotGold = "XAU"
    case silver = "SI"
    case comexCopper = "HG"
    case londonCopper = "CAD"
    case chinaA50 = "CHA50CFD"
    case sp500 = "ES"
    case dow = "YM"

    public var id: String { rawValue }
    public var quoteKind: String { self == .spotGold ? "现货报价（CFD）" : "CFD" }

    public var title: String {
        switch self {
        case .vix: return "VIX 恐慌指数期货"
        case .wtiOil: return "纽约原油"
        case .brentOil: return "布伦特原油"
        case .gold: return "纽约黄金"
        case .spotGold: return "伦敦金（现货黄金）"
        case .silver: return "纽约白银"
        case .comexCopper: return "美铜"
        case .londonCopper: return "伦铜"
        case .chinaA50: return "富时中国 A50 期货"
        case .sp500: return "标普 500 指数期货"
        case .dow: return "道琼斯指数期货"
        }
    }

    /// Daily trading session of the underlying exchange, expressed in that exchange's local time.
    public var session: FuturesSession {
        switch self {
        case .vix, .wtiOil, .gold, .spotGold, .silver, .comexCopper, .sp500, .dow:
            // CME Globex 18:00–17:00 ET, 23 hours a day.
            return FuturesSession(timeZoneIdentifier: "America/New_York",
                                  startMinute: 18 * 60, endMinute: 17 * 60)
        case .brentOil:
            // ICE Brent 01:00–23:00 London.
            return FuturesSession(timeZoneIdentifier: "Europe/London",
                                  startMinute: 60, endMinute: 23 * 60)
        case .londonCopper:
            // LME Select 01:00–19:00 London.
            return FuturesSession(timeZoneIdentifier: "Europe/London",
                                  startMinute: 60, endMinute: 19 * 60)
        case .chinaA50:
            // SGX T+1 17:00–05:15 and T 09:00–16:30, treated as one 17:00–16:30 session.
            return FuturesSession(timeZoneIdentifier: "Asia/Singapore",
                                  startMinute: 17 * 60, endMinute: 16 * 60 + 30)
        }
    }
}

public struct FuturesSession: Equatable, Sendable {
    public let timeZoneIdentifier: String
    public let startMinute: Int
    /// Earlier than `startMinute` when the session closes on the following local day.
    public let endMinute: Int

    public init(timeZoneIdentifier: String, startMinute: Int, endMinute: Int) {
        self.timeZoneIdentifier = timeZoneIdentifier
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// The session window containing an instant, in absolute time. Exchange time zones follow
    /// daylight saving, so the Beijing-clock bounds shift by an hour in summer.
    public func window(containing date: Date) -> DateInterval? {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let closesNextDay = endMinute <= startMinute
        for offset in -1...1 {
            guard let start = moment(startMinute, dayOffset: offset, near: date, calendar: calendar),
                  let end = moment(endMinute, dayOffset: offset + (closesNextDay ? 1 : 0),
                                   near: date, calendar: calendar),
                  date >= start, date <= end else { continue }
            return DateInterval(start: start, end: end)
        }
        return nil
    }

    private func moment(_ minute: Int, dayOffset: Int, near date: Date, calendar: Calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: dayOffset,
                                      to: calendar.startOfDay(for: date)) else { return nil }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }
}

public struct FuturesQuote: Codable, Sendable {
    public let instrument: FuturesInstrument
    public let price: Decimal
    public let reference: Decimal?
    public let time: Date
    public let open: Decimal?
    public let high: Decimal?
    public let low: Decimal?
    public let openInterest: Decimal?

    public var amplitude: Decimal? {
        guard let high, let low, let reference, reference != 0 else { return nil }
        return (high - low) / abs(reference) * 100
    }

    public var change: Decimal? { reference.map { price - $0 } }

    public var rate: Decimal? {
        guard let reference, reference != 0 else { return nil }
        return (price - reference) / abs(reference) * 100
    }
}

public struct FuturesIntraday: Codable, Sendable {
    public let reference: Decimal?
    public let points: [PlotPoint]
    public let averages: [PlotPoint]?
}

extension MarketProviders {
    public func futuresQuotes() async throws -> [FuturesQuote] {
        let symbols = FuturesInstrument.allCases.map { "hf_" + $0.rawValue }.joined(separator: ",")
        let response = try await fetch(host: "hq.sinajs.cn", path: "/list=" + symbols,
                                       referer: "https://finance.sina.com.cn/")
        return try Self.decodeFuturesQuotes(response)
    }

    public func futuresIntraday(_ instrument: FuturesInstrument) async throws -> FuturesIntraday {
        let response = try await fetch(host: "stock2.finance.sina.com.cn",
                                       path: "/futures/api/openapi.php/GlobalFuturesService.getGlobalFuturesMinLine",
                                       query: ["symbol": instrument.rawValue],
                                       referer: "https://finance.sina.com.cn/")
        return try Self.decodeFuturesIntraday(response)
    }

    static func decodeFuturesQuotes(_ data: Data) throws -> [FuturesQuote] {
        // Only the symbol, prices and times are used. Sina encodes instrument names in GB18030.
        let instruments = Dictionary(uniqueKeysWithValues: FuturesInstrument.allCases.map {
            ("var hq_str_hf_" + $0.rawValue, $0)
        })
        var quotes: [FuturesInstrument: FuturesQuote] = [:]
        for assignment in String(decoding: data, as: UTF8.self).split(separator: ";") {
            let pair = assignment.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  let instrument = instruments[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)],
                  let start = pair[1].firstIndex(of: "\""),
                  let end = pair[1].lastIndex(of: "\""), start < end else { continue }
            let fields = pair[1][pair[1].index(after: start)..<end]
                .split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > 12, let price = decimal(String(fields[0])),
                  let time = MarketClock.timestamp(day: String(fields[12]), time: String(fields[6]))
            else { continue }
            let quote = FuturesQuote(instrument: instrument, price: price,
                                     reference: decimal(String(fields[7])), time: time,
                                     open: decimal(String(fields[8])), high: decimal(String(fields[4])),
                                     low: decimal(String(fields[5])),
                                     openInterest: decimal(String(fields[9])).flatMap { $0 > 0 ? $0 : nil })
            if quotes[instrument].map({ $0.time <= quote.time }) != false {
                quotes[instrument] = quote
            }
        }
        let results = FuturesInstrument.allCases.compactMap { quotes[$0] }
        guard !results.isEmpty else { throw FeedError.incomplete }
        return results
    }

    private struct FuturesEnvelope: Decodable {
        struct Result: Decodable {
            struct Payload: Decodable { let minLine_1d: [[String]] }
            let data: Payload?
        }
        let result: Result
    }

    static func decodeFuturesIntraday(_ data: Data) throws -> FuturesIntraday {
        let response = try JSONDecoder().decode(FuturesEnvelope.self, from: data)
        guard let rows = response.result.data?.minLine_1d,
              let first = rows.first, first.count >= 10 else { throw FeedError.incomplete }

        // The first row starts with trading-day metadata. Each row ends with its actual Beijing timestamp,
        // which can belong to the preceding calendar day for the evening session.
        var points: [Date: PlotPoint] = [:]
        var averages: [Date: PlotPoint] = [:]
        for (index, row) in rows.enumerated() {
            let offset = index == 0 ? 4 : 0
            guard row.count >= offset + 6,
                  let price = decimal(row[offset + 1]) else { continue }
            let dateTime = row[offset + 5].split(separator: " ")
            guard dateTime.count == 2,
                  let time = MarketClock.timestamp(day: String(dateTime[0]), time: String(dateTime[1]))
            else { continue }
            points[time] = PlotPoint(time: time, value: price)
            averages[time] = decimal(row[offset + 4]).flatMap {
                $0 == 0 ? nil : PlotPoint(time: time, value: $0)
            }
        }
        guard !points.isEmpty else { throw FeedError.incomplete }
        return FuturesIntraday(reference: decimal(first[1]),
                               points: points.values.sorted { $0.time < $1.time },
                               averages: averages.values.sorted { $0.time < $1.time })
    }
}
