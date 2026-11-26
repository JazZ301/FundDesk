import Foundation

public enum MarketIndex: String, CaseIterable, Codable, Sendable, Identifiable {
    case shenzhenComposite = "sz399001"
    case shanghaiComposite = "sh000001"
    case csi300 = "sh000300"
    case chinext = "sz399006"
    case hangSeng = "hkHSI"
    case sp500 = "usINX"
    case nasdaq = "usIXIC"

    public static let displayOrder: [Self] = [.shanghaiComposite, .csi300, .shenzhenComposite, .chinext, .hangSeng, .sp500, .nasdaq]
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .shanghaiComposite: return "上证指数"
        case .shenzhenComposite: return "深证成指"
        case .csi300: return "沪深300"
        case .chinext: return "创业板指"
        case .hangSeng: return "恒生指数"
        case .sp500: return "标普500"
        case .nasdaq: return "纳斯达克综合"
        }
    }

    public var isUS: Bool { self == .sp500 || self == .nasdaq }
    var quoteKey: String { self == .hangSeng ? "r_hkHSI" : rawValue }

    public var tradingSession: IndexTradingSession {
        if isUS { return .unitedStates }
        if self == .hangSeng { return .hongKong }
        return .mainlandChina
    }
}

public struct IndexTradingWindow: Equatable, Sendable {
    public let startMinute: Int
    public let endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public var duration: Int { endMinute - startMinute }
}

public struct IndexAxisMark: Equatable, Sendable {
    public let position: Int
    public let title: String

    public init(position: Int, title: String) {
        self.position = position
        self.title = title
    }
}

public struct IndexTradingSession: Equatable, Sendable {
    public let timeZoneIdentifier: String
    public let timeZoneLabel: String
    public let windows: [IndexTradingWindow]
    public let axisMarks: [IndexAxisMark]

    public var totalMinutes: Int {
        windows.reduce(0) { $0 + $1.duration }
    }

    public static let mainlandChina = IndexTradingSession(
        timeZoneIdentifier: "Asia/Shanghai",
        timeZoneLabel: "北京时间",
        windows: [
            IndexTradingWindow(startMinute: 9 * 60 + 30, endMinute: 11 * 60 + 30),
            IndexTradingWindow(startMinute: 13 * 60, endMinute: 15 * 60)
        ],
        axisMarks: [
            IndexAxisMark(position: 0, title: "09:30"),
            IndexAxisMark(position: 60, title: "10:30"),
            IndexAxisMark(position: 120, title: "11:30/13:00"),
            IndexAxisMark(position: 180, title: "14:00"),
            IndexAxisMark(position: 240, title: "15:00")
        ]
    )

    public static let hongKong = IndexTradingSession(
        timeZoneIdentifier: "Asia/Hong_Kong",
        timeZoneLabel: "香港时间",
        windows: [
            IndexTradingWindow(startMinute: 9 * 60 + 30, endMinute: 12 * 60),
            IndexTradingWindow(startMinute: 13 * 60, endMinute: 16 * 60)
        ],
        axisMarks: [
            IndexAxisMark(position: 0, title: "09:30"),
            IndexAxisMark(position: 60, title: "10:30"),
            IndexAxisMark(position: 120, title: "11:30"),
            IndexAxisMark(position: 150, title: "12:00/13:00"),
            IndexAxisMark(position: 210, title: "14:00"),
            IndexAxisMark(position: 270, title: "15:00"),
            IndexAxisMark(position: 330, title: "16:00")
        ]
    )

    public static let unitedStates = IndexTradingSession(
        timeZoneIdentifier: "America/New_York",
        timeZoneLabel: "美东时间",
        windows: [
            IndexTradingWindow(startMinute: 9 * 60 + 30, endMinute: 16 * 60)
        ],
        axisMarks: [
            IndexAxisMark(position: 0, title: "09:30"),
            IndexAxisMark(position: 60, title: "10:30"),
            IndexAxisMark(position: 120, title: "11:30"),
            IndexAxisMark(position: 180, title: "12:30"),
            IndexAxisMark(position: 240, title: "13:30"),
            IndexAxisMark(position: 300, title: "14:30"),
            IndexAxisMark(position: 360, title: "15:30"),
            IndexAxisMark(position: 390, title: "16:00")
        ]
    )

    public func position(for date: Date) -> Int? {
        let minute = minuteOfDay(date)
        var offset = 0
        for window in windows {
            if (window.startMinute...window.endMinute).contains(minute) {
                return offset + minute - window.startMinute
            }
            offset += window.duration
        }
        return nil
    }

    public func timeLabel(for date: Date) -> String {
        formatted(date, format: "HH:mm")
    }

    public func dateTimeLabel(for date: Date) -> String {
        formatted(date, format: "yyyy-MM-dd HH:mm")
    }

    public func timestamp(day: String, time: String) -> Date? {
        let dayParts = day.split(separator: "-").compactMap { Int($0) }
        let timeParts = time.split(separator: ":").compactMap { Int($0) }
        guard dayParts.count == 3, timeParts.count >= 2,
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: dayParts[0], month: dayParts[1], day: dayParts[2],
            hour: timeParts[0], minute: timeParts[1],
            second: timeParts.count > 2 ? timeParts[2] : 0
        ))
    }

    private func minuteOfDay(_ date: Date) -> Int {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return -1 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

public struct IndexQuote: Codable, Sendable, Identifiable {
    public var id: MarketIndex { index }
    public let index: MarketIndex
    public let value: Decimal
    public let change: Decimal
    public let rate: Decimal
    public let timestamp: String
    public let turnover: Decimal?
}

public struct IndexTrend: Codable, Sendable {
    public let source: String
    public let points: [PlotPoint]
    public let previousClose: Decimal?
    public let volumes: [PlotPoint]?

    public init(source: String, points: [PlotPoint], previousClose: Decimal? = nil,
                volumes: [PlotPoint]? = nil) {
        self.source = source
        self.points = points
        self.previousClose = previousClose
        self.volumes = volumes
    }
}

public struct MarketBreadth: Codable, Sendable {
    public let turnover: Decimal
    public let advancing: Int?
    public let flat: Int?
    public let declining: Int?
    public let asOf: Date?
    public let source: String
    public var cachedCountsAsOf: Date?

    public var hasCounts: Bool { advancing != nil && flat != nil && declining != nil }
    public var countsAsOf: Date? { hasCounts ? (cachedCountsAsOf ?? asOf) : nil }

    public func preservingCounts(from cached: Self) -> Self {
        guard !hasCounts, let asOf, let countsTime = cached.countsAsOf,
              MarketClock.day(asOf) == MarketClock.day(countsTime) else { return self }
        return Self(turnover: turnover, advancing: cached.advancing, flat: cached.flat,
                    declining: cached.declining, asOf: asOf, source: source,
                    cachedCountsAsOf: countsTime)
    }
}

public enum FlowKind: String, CaseIterable, Codable, Sendable {
    case main = "主力"
    case huge = "超大单"
    case large = "大单"
    case medium = "中单"
    case small = "小单"
}

public struct MarketFlow: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { time }
    public let time: Date
    public let main: Decimal
    public let small: Decimal
    public let medium: Decimal
    public let large: Decimal
    public let huge: Decimal

    public func amount(_ kind: FlowKind) -> Decimal {
        switch kind {
        case .main: return main
        case .huge: return huge
        case .large: return large
        case .medium: return medium
        case .small: return small
        }
    }
}

public struct MarketFlowSeries: Codable, Sendable {
    public let points: [MarketFlow]
    public let intraday: Bool
}

public enum SectorCategory: String, CaseIterable, Sendable {
    case industry = "行业板块"
    case style = "风格板块"
    case concept = "概念板块"
    case region = "地域板块"

    var providerCode: String {
        switch self {
        case .industry: return "m:90+s:4"
        case .style: return "m:90+e:4"
        case .concept: return "m:90+t:3"
        case .region: return "m:90+t:1"
        }
    }
}

public enum SectorPeriod: String, CaseIterable, Sendable {
    case today = "今日"
    case fiveDays = "近5日"
    case tenDays = "近10日"

    var providerField: String {
        switch self {
        case .today: return "f62"
        case .fiveDays: return "f164"
        case .tenDays: return "f174"
        }
    }
}

public struct SectorFlow: Codable, Sendable, Identifiable {
    public var id: String { code }
    public let code: String
    public let name: String
    public let amount: Decimal
}

extension MarketProviders {
    public func indices() async throws -> [IndexQuote] {
        let codes = MarketIndex.displayOrder.map(\.quoteKey).joined(separator: ",")
        let payload = try await fetch(host: "qt.gtimg.cn", path: "/q=" + codes)
        return try Self.decodeIndices(payload)
    }

    public func indexTrend(_ index: MarketIndex) async throws -> IndexTrend {
        if index.isUS {
            do {
                let symbol = index == .sp500 ? "^GSPC" : "^IXIC"
                let data = try await fetch(host: "query1.finance.yahoo.com", path: "/v8/finance/chart/" + symbol,
                                           query: ["range": "1d", "interval": "5m"])
                return try Self.decodeUSChartTrend(data, symbol: symbol)
            } catch {
                try Task.checkCancellation()
                return try await eastQuote(path: "/api/qt/stock/trends2/get", query: [
                    "secid": index == .sp500 ? "100.SPX" : "100.NDX", "ndays": "1",
                    "fields1": "f1,f2,f3,f6,f7,f8", "fields2": "f51,f53,f56"
                ], hosts: ["push2his", "push2", "push2delay"]) { data, _ -> IndexTrend in
                    let root = try Self.json(data)
                    guard let body = root["data"] as? [String: Any], let rows = body["trends"] as? [String]
                    else { throw FeedError.incomplete }
                    var points: [PlotPoint] = []
                    var volumes: [PlotPoint] = []
                    for row in rows {
                        let cells = row.split(separator: ",")
                        guard cells.count >= 3, let value = decimal(String(cells[1])) else { continue }
                        let stamp = cells[0].split(separator: " ")
                        guard stamp.count == 2,
                              let time = MarketClock.timestamp(day: String(stamp[0]), time: String(stamp[1])) else {
                            continue
                        }
                        points.append(PlotPoint(time: time, value: value))
                        if let volume = decimal(String(cells[2])), volume >= 0 {
                            volumes.append(PlotPoint(time: time, value: volume))
                        }
                    }
                    guard !points.isEmpty else { throw FeedError.incomplete }
                    return IndexTrend(source: "东方财富", points: points,
                                      previousClose: decimal(Self.field(body, "preClose")),
                                      volumes: volumes)
                }
            }
        }
        let data = try await fetch(host: "web.ifzq.gtimg.cn", path: "/appstock/app/minute/query", query: ["code": index.rawValue])
        return try Self.decodeTencentIndexTrend(data, index: index)
    }

    static func decodeTencentIndexTrend(_ data: Data, index: MarketIndex) throws -> IndexTrend {
        let root = try Self.json(data)
        guard let source = (root["data"] as? [String: [String: Any]])?[index.rawValue],
              let series = source["data"] as? [String: Any],
              let day = Self.field(series, "date"), day.count == 8, let rows = series["data"] as? [String]
        else { throw FeedError.incomplete }
        let date = String(day.prefix(4)) + "-" + day.dropFirst(4).prefix(2) + "-" + day.suffix(2)
        var points: [PlotPoint] = []
        var volumes: [PlotPoint] = []
        var previousCumulativeVolume: Decimal?
        for row in rows {
            let parts = row.split(separator: " ")
            guard parts.count >= 2, parts[0].count == 4,
                  let time = MarketClock.timestamp(day: date, time: parts[0].prefix(2) + ":" + parts[0].suffix(2)),
                  let value = decimal(String(parts[1])) else { continue }
            points.append(PlotPoint(time: time, value: value))
            if parts.count >= 3, let cumulative = decimal(String(parts[2])), cumulative >= 0 {
                let volume = previousCumulativeVolume.map { max(cumulative - $0, 0) } ?? cumulative
                volumes.append(PlotPoint(time: time, value: volume))
                previousCumulativeVolume = cumulative
            }
        }
        guard !points.isEmpty else { throw FeedError.incomplete }
        let quotes = source["qt"] as? [String: Any]
        let quote = quotes?[index.rawValue] as? [Any]
        let previousClose = quote?.dropFirst(4).first.flatMap(Self.decimalText)
        return IndexTrend(source: "腾讯行情", points: points, previousClose: previousClose, volumes: volumes)
    }

    static func decodeUSChart(_ data: Data, symbol: String) throws -> [PlotPoint] {
        try decodeUSChartTrend(data, symbol: symbol).points
    }

    static func decodeUSChartTrend(_ data: Data, symbol: String) throws -> IndexTrend {
        let root = try json(data)
        guard let chart = root["chart"] as? [String: Any],
              let info = (chart["result"] as? [[String: Any]])?.first,
              let meta = info["meta"] as? [String: Any], field(meta, "symbol") == symbol,
              let times = info["timestamp"] as? [Double], let indicators = info["indicators"] as? [String: Any],
              let quote = (indicators["quote"] as? [[String: Any]])?.first,
              let close = quote["close"] as? [Any] else { throw FeedError.incomplete }
        let points = zip(times, close).compactMap { time, raw -> PlotPoint? in
            guard time > 0, let number = raw as? NSNumber, number.doubleValue > 0 else { return nil }
            return PlotPoint(time: Date(timeIntervalSince1970: time), value: number.decimalValue)
        }
        guard !points.isEmpty else { throw FeedError.incomplete }
        let volumes = zip(times, quote["volume"] as? [Any] ?? []).compactMap { time, raw -> PlotPoint? in
            guard time > 0, let number = raw as? NSNumber, number.doubleValue > 0 else { return nil }
            return PlotPoint(time: Date(timeIntervalSince1970: time), value: number.decimalValue)
        }
        let previousClose = decimal(field(meta, "previousClose") ?? field(meta, "chartPreviousClose"))
        return IndexTrend(source: "Yahoo Finance · 5 分钟间隔", points: points,
                          previousClose: previousClose, volumes: volumes)
    }

    public func marketBreadth() async throws -> MarketBreadth {
        do {
            return try await eastBreadth()
        } catch {
            try Task.checkCancellation()
            let quotes = try await indices()
            guard let sh = quotes.first(where: { $0.index == .shanghaiComposite }),
                  let sz = quotes.first(where: { $0.index == .shenzhenComposite }),
                  let a = sh.turnover, let b = sz.turnover else { throw FeedError.incomplete }
            let stamps = [sh.timestamp, sz.timestamp].compactMap { stamp -> Date? in
                let parts = stamp.split(separator: " ")
                guard parts.count == 2 else { return nil }
                return MarketClock.timestamp(day: String(parts[0]), time: String(parts[1]))
            }
            return MarketBreadth(turnover: a + b, advancing: nil, flat: nil, declining: nil,
                                 asOf: Self.sharedMarketTime(stamps), source: "腾讯行情")
        }
    }

    private func eastBreadth() async throws -> MarketBreadth {
        try await eastQuote(path: "/api/qt/ulist.np/get", query: [
            "fltt": "2", "fields": "f6,f12,f13,f104,f105,f106,f124", "secids": "1.000001,0.399001"
        ]) { payload, host in
            let base = try Self.json(payload)
            guard let detail = base["data"] as? [String: Any], let listings = detail["diff"] as? [[String: Any]],
                  let sh = listings.first(where: { Self.field($0, "f12") == "000001" }),
                  let sz = listings.first(where: { Self.field($0, "f12") == "399001" }) else { throw FeedError.incomplete }
            let fields = ["f6", "f104", "f106", "f105"]
            let sums = fields.compactMap { field -> Decimal? in
                guard let a = decimal(Self.field(sh, field)), let b = decimal(Self.field(sz, field)),
                      a >= 0, b >= 0 else { return nil }
                return a + b
            }
            guard sums.count == fields.count, sums[0] > 0 else { throw FeedError.incomplete }
            let stamps = [Self.field(sh, "f124"), Self.field(sz, "f124")]
                .compactMap { $0.flatMap(Double.init) }.filter { $0.isFinite && $0 > 0 }
                .map { Date(timeIntervalSince1970: $0) }
            let timestamp = Self.sharedMarketTime(stamps)
            if stamps.count == 2 && timestamp == nil { throw FeedError.incomplete }
            return MarketBreadth(turnover: sums[0], advancing: NSDecimalNumber(decimal: sums[1]).intValue,
                                 flat: NSDecimalNumber(decimal: sums[2]).intValue,
                                 declining: NSDecimalNumber(decimal: sums[3]).intValue,
                                 asOf: timestamp, source: host == "push2" ? "东方财富" : "东方财富 · 延时来源")
        }
    }

    private static func sharedMarketTime(_ stamps: [Date]) -> Date? {
        guard stamps.count == 2, MarketClock.day(stamps[0]) == MarketClock.day(stamps[1]) else { return nil }
        return stamps.min()
    }

    public func marketFlows() async throws -> MarketFlowSeries {
        let common = ["secid": "1.000001", "secid2": "0.399001", "fields1": "f1,f2,f3,f7"]
        do {
            let query = common.merging([
                "lmt": "0", "klt": "1", "fields2": "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63"
            ]) { _, new in new }
            let rows: [MarketFlow] = try await eastQuote(path: "/api/qt/stock/fflow/kline/get", query: query,
                                                        order: ["lmt", "klt", "secid", "secid2", "fields1", "fields2"]) { data, _ in
                try Self.decodeFlows(data, intraday: true)
            }
            return MarketFlowSeries(points: rows, intraday: true)
        } catch {
            try Task.checkCancellation()
            let query = common.merging(["lmt": "20", "klt": "101", "fields2": "f51,f52,f53,f54,f55,f56"]) { _, new in new }
            let rows: [MarketFlow] = try await eastQuote(path: "/api/qt/stock/fflow/daykline/get",
                                                        query: query, hosts: ["push2his", "push2"],
                                                        order: ["lmt", "klt", "secid", "secid2", "fields1", "fields2"]) { data, _ in
                try Self.decodeFlows(data, intraday: false)
            }
            return MarketFlowSeries(points: rows, intraday: false)
        }
    }

    private func eastQuote<Value>(
        path: String, query: [String: String], hosts: [String] = ["push2", "push2delay", "push2his"],
        order: [String]? = nil, decode: (Data, String) throws -> Value
    ) async throws -> Value {
        var failure: Error = FeedError.incomplete
        for name in hosts {
            try Task.checkCancellation()
            do {
                let data = try await fetch(host: name + ".eastmoney.com", path: path, query: query, queryOrder: order,
                                           referer: "https://data.eastmoney.com/zjlx/dpzjlx.html")
                return try decode(data, name)
            } catch {
                failure = error
            }
        }
        throw failure
    }

    public func sectorFlows(_ category: SectorCategory, period: SectorPeriod) async throws -> [SectorFlow] {
        let response = try await fetch(host: "data.eastmoney.com", path: "/dataapi/bkzj/getbkzj",
                                       query: ["key": period.providerField, "code": category.providerCode])
        return try Self.decodeSectors(response, period: period)
    }

    static func decodeIndices(_ data: Data) throws -> [IndexQuote] {
        // Tencent uses GB18030. The keys and numeric quote fields are ASCII; names come from MarketIndex.
        let text = String(decoding: data, as: UTF8.self)
        var byIndex: [MarketIndex: IndexQuote] = [:]
        for chunk in text.split(separator: ";") {
            let pair = chunk.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = MarketIndex.displayOrder.first(where: { "v_" + $0.quoteKey == key }) else { continue }
            let fields = pair[1].split(separator: "~", omittingEmptySubsequences: false)
            let timeIndex = 30
            guard fields.count > timeIndex + 2, let value = decimal(String(fields[3])), value > 0,
                  let change = decimal(String(fields[timeIndex + 1])), let rate = decimal(String(fields[timeIndex + 2]))
            else { continue }
            let rawTime = String(fields[timeIndex])
            let timestamp: String
            if rawTime.count == 14, rawTime.allSatisfy(\.isNumber) {
                let ymd = rawTime.prefix(8)
                timestamp = ymd.prefix(4) + "-" + ymd.dropFirst(4).prefix(2) + "-" + ymd.suffix(2)
                    + " " + rawTime.dropFirst(8).prefix(2) + ":" + rawTime.dropFirst(10).prefix(2)
                    + ":" + rawTime.suffix(2)
            } else {
                timestamp = rawTime.replacingOccurrences(of: "/", with: "-")
            }
            let turnover: Decimal?
            if fields.count > 35 && (index == .shanghaiComposite || index == .shenzhenComposite) {
                turnover = fields[35].split(separator: "/").last.flatMap { decimal(String($0)) }
            } else {
                turnover = nil
            }
            byIndex[index] = IndexQuote(index: index, value: value, change: change, rate: rate,
                                       timestamp: timestamp, turnover: turnover)
        }
        let results = MarketIndex.displayOrder.compactMap { byIndex[$0] }
        guard !results.isEmpty else { throw FeedError.incomplete }
        return results
    }

    static func decodeFlows(_ data: Data, intraday: Bool = true) throws -> [MarketFlow] {
        let root = try json(data)
        guard let detail = root["data"] as? [String: Any], let klines = detail["klines"] as? [String] else {
            throw FeedError.incomplete
        }
        let flows = klines.compactMap { line -> MarketFlow? in
            let cells = line.split(separator: ",")
            guard cells.count >= 6 else { return nil }
            let date = cells[0].split(separator: " ")
            let amounts = cells[1...5].compactMap { decimal(String($0)) }
            guard date.count == (intraday ? 2 : 1),
                  let time = MarketClock.timestamp(day: String(date[0]), time: intraday ? String(date[1]) : "00:00"),
                  time <= Date.now.addingTimeInterval(180), amounts.count == 5 else { return nil }
            return MarketFlow(time: time, main: amounts[0], small: amounts[1], medium: amounts[2],
                              large: amounts[3], huge: amounts[4])
        }
        guard !flows.isEmpty else { throw FeedError.incomplete }
        return flows.sorted { $0.time < $1.time }
    }

    static func decodeSectors(_ data: Data, period: SectorPeriod) throws -> [SectorFlow] {
        let root = try json(data)
        guard let payload = root["data"] as? [String: Any], let rows = payload["diff"] as? [[String: Any]] else {
            throw FeedError.incomplete
        }
        let entries = rows.compactMap { row -> SectorFlow? in
            guard let code = field(row, "f12"), let name = field(row, "f14"), let amount = decimal(field(row, period.providerField))
            else { return nil }
            return SectorFlow(code: code, name: name, amount: amount)
        }
        guard !entries.isEmpty else { throw FeedError.incomplete }
        return entries.sorted { $0.amount == $1.amount ? $0.code < $1.code : $0.amount > $1.amount }
    }

    private static func decimalText(_ value: Any) -> Decimal? {
        if let text = value as? String { return decimal(text) }
        if let number = value as? NSNumber { return decimal(number.stringValue) }
        return nil
    }
}
