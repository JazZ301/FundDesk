import Foundation

public enum FeedError: LocalizedError {
    case response(Int)
    case incomplete

    public var errorDescription: String? {
        switch self {
        case .response(let code): return "数据源响应 \(code)"
        case .incomplete: return "数据源未返回有效数据"
        }
    }
}

public protocol MarketData: Sendable {
    func catalog() async throws -> [Fund]
    func search(_ query: String) async throws -> [Fund]
    func history(for fund: Fund, limit: Int) async throws -> [NAV]
    func sina(for fund: Fund) async throws -> SinaSnapshot
}

public struct SinaSnapshot: Sendable {
    public let nav: NAV?
    public let estimate: Estimate?
    public let series: [Estimate]

    public init(nav: NAV?, estimate: Estimate?, series: [Estimate] = []) {
        self.nav = nav
        self.estimate = estimate
        self.series = series
    }
}

public struct MarketProviders: MarketData {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6
            config.timeoutIntervalForResource = 9
            config.httpMaximumConnectionsPerHost = 4
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func catalog() async throws -> [Fund] {
        let data = try await fetch(host: "fund.eastmoney.com", path: "/js/fundcode_search.js")
        let rows = try JSONDecoder().decode([[String]].self, from: Self.array(in: data))
        let funds = rows.compactMap { row -> Fund? in
            guard row.count >= 5, Fund.validCode(row[0]), !row[2].isEmpty else { return nil }
            return Fund(code: row[0], name: row[2], kind: row[3], initials: row[1], pinyin: row[4])
        }
        guard !funds.isEmpty else { throw FeedError.incomplete }
        return funds
    }

    public func search(_ query: String) async throws -> [Fund] {
        let data = try await fetch(host: "fundsuggest.eastmoney.com", path: "/FundSearch/api/FundSearchAPI.ashx",
                                   query: ["key": query, "m": "9"])
        let response = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        return (response.Datas ?? []).compactMap { row in
            guard Fund.validCode(row.CODE), let base = row.FundBaseInfo else { return nil }
            return Fund(code: row.CODE, name: row.NAME, kind: base.FTYPE ?? "", initials: row.JP ?? "")
        }
    }

    public func history(for fund: Fund, limit: Int) async throws -> [NAV] {
        do {
            let data = try await fetch(host: "api.fund.eastmoney.com", path: "/f10/lsjz", query: [
                "fundCode": fund.code, "pageIndex": "1", "pageSize": String(limit)
            ], referer: "https://fundf10.eastmoney.com/jjjz_\(fund.code).html")
            return try Self.decodeHistory(data, money: fund.isMoney)
        } catch {
            try Task.checkCancellation()
            let data = try await fetch(host: "fund.eastmoney.com", path: "/pingzhongdata/\(fund.code).js")
            return try Self.decodeHistoryScript(data, money: fund.isMoney, limit: limit)
        }
    }

    public func sina(for fund: Fund) async throws -> SinaSnapshot {
        let data = try await fetch(host: "stock.finance.sina.com.cn",
                                   path: "/fundInfo/api/openapi.php/FdFundService.getEstimateNetworthPic",
                                   query: ["symbol": fund.code])
        return try Self.decodeSina(data, fund: fund)
    }

    func fetch(host: String, path: String, query: [String: String] = [:], queryOrder: [String]? = nil, referer: String? = nil) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty {
            let keys = queryOrder ?? query.keys.sorted()
            components.queryItems = keys.compactMap { key in query[key].map { URLQueryItem(name: key, value: $0) } }
        }
        guard let url = components.url else { throw FeedError.incomplete }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedError.incomplete }
        guard (200..<300).contains(http.statusCode) else { throw FeedError.response(http.statusCode) }
        guard !data.isEmpty, data.count <= 10_000_000 else { throw FeedError.incomplete }
        return data
    }

    static func decodeHistory(_ data: Data, money: Bool) throws -> [NAV] {
        let response = try JSONDecoder().decode(HistoryEnvelope.self, from: data)
        let money = money || response.Data?.FundType == "005"
        let rows = (response.Data?.LSJZList ?? []).compactMap { row -> NAV? in
            guard MarketClock.timestamp(day: row.FSRQ) != nil, let value = decimal(row.DWJZ),
                  money || value > 0 else { return nil }
            return NAV(day: row.FSRQ, value: value, rate: money ? nil : decimal(row.JZZZL),
                       annualizedRate: money ? decimal(row.LJJZ) : nil,
                       cumulativeValue: money ? nil : decimal(row.LJJZ), source: "天天基金")
        }
        guard !rows.isEmpty else { throw FeedError.incomplete }
        return rows
    }

    public static func decodeHistoryScript(_ data: Data, money: Bool, limit: Int) throws -> [NAV] {
        guard let script = String(data: data, encoding: .utf8) else { throw FeedError.incomplete }
        if money || script.contains("var Data_millionCopiesIncome") {
            let incomes = try Self.currencySeries(script, variable: "Data_millionCopiesIncome")
            let annualized = (try? Self.currencySeries(script, variable: "Data_sevenDaysYearIncome")) ?? [:]
            let rows = incomes.keys.sorted().suffix(limit).compactMap { day -> NAV? in
                guard let value = incomes[day] else { return nil }
                return NAV(day: day, value: value, annualizedRate: annualized[day], source: "天天基金")
            }
            guard !rows.isEmpty else { throw FeedError.incomplete }
            return rows
        }
        let payload = try Self.scriptArray(script, variable: "Data_netWorthTrend")
        let decoded = try JSONDecoder().decode([HistoryPoint].self, from: payload)
        let rows = decoded.suffix(limit).filter { $0.y > 0 }.map {
            NAV(day: MarketClock.day(Date(timeIntervalSince1970: $0.x / 1000)),
                value: $0.y, rate: $0.equityReturn, source: "天天基金")
        }
        guard !rows.isEmpty else { throw FeedError.incomplete }
        return rows
    }

    public static func decodeCumulativeHistoryScript(_ data: Data, limit: Int) throws -> [NAV] {
        guard let script = String(data: data, encoding: .utf8) else { throw FeedError.incomplete }
        let payload = try Self.scriptArray(script, variable: "Data_ACWorthTrend")
        let decoded = try JSONDecoder().decode([[Decimal]].self, from: payload)
        let rows = decoded.compactMap { row -> NAV? in
            guard row.count >= 2, row[1] > 0 else { return nil }
            let timestamp = NSDecimalNumber(decimal: row[0]).doubleValue / 1_000
            guard timestamp > 0 else { return nil }
            let day = MarketClock.day(Date(timeIntervalSince1970: timestamp))
            return NAV(day: day, value: row[1], cumulativeValue: row[1], source: "天天基金")
        }.suffix(limit)
        guard !rows.isEmpty else { throw FeedError.incomplete }
        return Array(rows)
    }

    static func decodeSina(_ data: Data, fund: Fund) throws -> SinaSnapshot {
        let response = try JSONDecoder().decode(SinaEnvelope.self, from: data)
        guard response.result.status.code == 0, let payload = response.result.data else { throw FeedError.incomplete }
        let baseDay = payload.worth_date.flatMap(Self.normalizedDay)
        let official: NAV?
        if let baseDay, let worth = payload.worth?.decimal, worth > 0, !fund.isMoney {
            official = NAV(day: baseDay, value: worth, rate: payload.worth_rate?.decimal.map { $0 * 100 }, source: "新浪财经")
        } else {
            official = nil
        }
        let series = (payload.networth ?? []).compactMap { row -> Estimate? in
            guard row.symbol == fund.code, let day = row.pre_date.flatMap(Self.normalizedDay),
                  let time = row.min_time, let timestamp = MarketClock.timestamp(day: day, time: time),
                  let value = row.pre_nav2?.decimal, value > 0,
                  let rate = row.growthrate2?.decimal, rate > -1 else { return nil }
            let sessionDay = fund.isCrossBorder && time < "09:00"
                ? MarketClock.day(MarketClock.calendar.date(byAdding: .day, value: -1, to: timestamp) ?? timestamp)
                : day
            return Estimate(timestamp: timestamp, marketDay: sessionDay, baseDay: baseDay, value: value, percent: rate * 100)
        }.sorted { $0.timestamp < $1.timestamp }
        return SinaSnapshot(nav: official, estimate: series.last, series: series)
    }

    private static func currencySeries(_ script: String, variable: String) throws -> [String: Decimal] {
        let payload = try Self.scriptArray(script, variable: variable)
        let rows = try JSONDecoder().decode([[Decimal]].self, from: payload)
        var byDay: [String: Decimal] = [:]
        for row in rows where row.count == 2 {
            let timestamp = NSDecimalNumber(decimal: row[0]).doubleValue / 1000
            guard timestamp > 0 else { continue }
            byDay[MarketClock.day(Date(timeIntervalSince1970: timestamp))] = row[1]
        }
        return byDay
    }

    static func scriptArray(_ script: String, variable: String) throws -> Data {
        guard let start = script.range(of: "var " + variable),
              let end = script[start.upperBound...].firstIndex(of: ";") else { throw FeedError.incomplete }
        return try Self.array(in: Data(script[start.upperBound..<end].utf8))
    }

    private static func normalizedDay(_ input: String) -> String? {
        let cleaned = input.replacingOccurrences(of: "-", with: "")
        guard cleaned.count == 8, cleaned.allSatisfy(\.isNumber) else { return nil }
        let day = "\(cleaned.prefix(4))-\(cleaned.dropFirst(4).prefix(2))-\(cleaned.suffix(2))"
        return MarketClock.timestamp(day: day) == nil ? nil : day
    }

    private static func array(in data: Data) throws -> Data {
        guard let first = data.firstIndex(of: 91), let last = data.lastIndex(of: 93), first < last else {
            throw FeedError.incomplete
        }
        return data[first...last]
    }
}

private struct HistoryEnvelope: Decodable {
    struct Body: Decodable {
        let LSJZList: [Row]?
        let FundType: String?
    }
    struct Row: Decodable {
        let FSRQ: String
        let DWJZ: String?
        let LJJZ: String?
        let JZZZL: String?
    }
    let Data: Body?
}

private struct HistoryPoint: Decodable {
    let x: Double
    let y: Decimal
    let equityReturn: Decimal?
}

private struct SearchEnvelope: Decodable {
    struct Row: Decodable {
        struct Metadata: Decodable { let FTYPE: String? }
        let CODE: String
        let NAME: String
        let JP: String?
        let FundBaseInfo: Metadata?
    }
    let Datas: [Row]?
}

private struct NumericText: Decodable {
    let decimal: Decimal?
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if let string = try? values.decode(String.self) {
            self.decimal = FundCore.decimal(string)
        } else {
            self.decimal = try? values.decode(Decimal.self)
        }
    }
}

private struct SinaEnvelope: Decodable {
    struct Result: Decodable {
        struct Status: Decodable { let code: Int }
        struct Payload: Decodable {
            struct Point: Decodable {
                let symbol: String
                let min_time: String?
                let pre_date: String?
                let pre_nav2: NumericText?
                let growthrate2: NumericText?
            }
            let worth: NumericText?
            let worth_date: String?
            let worth_rate: NumericText?
            let networth: [Point]?
        }
        let status: Status
        let data: Payload?
    }
    let result: Result
}
