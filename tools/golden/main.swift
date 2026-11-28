import Foundation

func iso(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)!
}

func numberText(_ value: Decimal?) -> Any {
    value.map { NSDecimalNumber(decimal: $0).stringValue } ?? NSNull()
}

func doubleText(_ value: Double?) -> Any {
    value.map { NSNumber(value: $0) } ?? NSNull()
}

func dayString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = MarketClock.calendar
    formatter.timeZone = MarketClock.calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

let now = iso("2026-11-26T02:00:00Z")
let scenarioPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "crates/core/tests/fixtures/scenario-metrics.json"
let board = try! JSONDecoder().decode(Board.self, from: Data(contentsOf: URL(fileURLWithPath: scenarioPath)))

var report: [String: Any] = [:]

// MARK: - Clock

let clockInstants = [
    "2026-11-25T16:30:00Z",
    "2026-11-26T01:30:00Z",
    "2026-11-26T08:16:00Z",
    "2026-11-28T02:00:00Z"
]
report["clock"] = clockInstants.map { instant -> [String: Any] in
    let date = iso(instant)
    return ["instant": instant, "day": MarketClock.day(date), "canPoll": MarketClock.canPollEstimates(date)]
}

let freshness: [(String, String, String, Bool)] = [
    ("2026-11-26T02:00:00Z", "2026-11-26T01:55:00Z", "2026-11-26", true),
    ("2026-11-26T02:00:00Z", "2026-11-26T01:30:00Z", "2026-11-26", false),
    ("2026-11-26T04:10:00Z", "2026-11-26T01:30:00Z", "2026-11-26", true),
    ("2026-11-26T02:00:00Z", "2026-11-26T01:55:00Z", "2026-11-25", false),
    ("2026-11-26T02:00:00Z", "2026-11-26T02:01:00Z", "2026-11-26", true),
    ("2026-11-26T02:00:00Z", "2026-11-26T02:03:00Z", "2026-11-26", false)
]
report["freshness"] = freshness.map { row -> [String: Any] in
    let quote = Estimate(timestamp: iso(row.1), marketDay: row.2, baseDay: nil,
                         value: 1, percent: 0)
    return [
        "now": row.0,
        "timestamp": row.1,
        "marketDay": row.2,
        "expected": MarketClock.isFreshEstimate(quote, now: iso(row.0))
    ]
}

// MARK: - Metrics

let metricsRows = board.holdings.map { holding -> [String: Any] in
    let metrics = FundMetrics(holding: holding, snapshot: board.snapshots[holding.id] ?? Snapshot(), now: now)
    return [
        "code": holding.id,
        "value": numberText(metrics.value),
        "rate": numberText(metrics.rate),
        "profit": numberText(metrics.profit),
        "estimated": numberText(metrics.estimatedDayProfit),
        "published": numberText(metrics.publishedDayProfit),
        "exclusion": metrics.dayProfitExclusion?.rawValue ?? NSNull()
    ]
}
let portfolio = Portfolio(board: board, now: now)
let health = EstimateHealth(board: board, failures: ["050025"], now: now)
report["metrics"] = [
    "now": "2026-11-26T02:00:00Z",
    "holdings": metricsRows,
    "portfolio": [
        "value": numberText(portfolio.value),
        "dayProfit": numberText(portfolio.dayProfit),
        "estimated": numberText(portfolio.estimatedDayProfit),
        "published": numberText(portfolio.publishedDayProfit),
        "estimatedCount": portfolio.estimatedDayCount,
        "publishedCount": portfolio.publishedDayCount,
        "holdingCount": portfolio.holdingCount,
        "coverage": numberText(portfolio.estimatedCoverage),
        "missingValuationCount": portfolio.missingValuationCount,
        "profit": numberText(portfolio.profit),
        "exclusions": Dictionary(uniqueKeysWithValues: portfolio.dayProfitExclusions.map {
            ($0.key.rawValue, $0.value)
        })
    ],
    "health": [
        "fresh": health.freshCount,
        "stale": health.staleCount,
        "failed": health.failedCount,
        "missing": health.missingCount
    ]
]

// MARK: - Journal

let fund = Fund(code: "007339", name: "易方达沪深300ETF联接C", kind: "指数型")
var base = Holding(fund: fund)
var records: [PositionRecord] = []
var steps: [[String: Any]] = []

func recordStep(_ change: PositionChange, _ holding: inout Holding, _ records: inout [PositionRecord]) {
    let (updated, record) = try! change.applying(to: holding, now: now)
    holding = updated
    records.append(record)
    steps.append([
        "shares": numberText(updated.shares),
        "cost": numberText(updated.costPerShare),
        "cash": numberText(record.cash),
        "realized": numberText(record.realized),
        "fee": numberText(record.fee),
        "action": record.action.rawValue
    ])
}

let buy = PositionChange(action: .buy, day: "2026-11-20",
                         shares: 10000, price: 1.5, fee: 0)
recordStep(buy, &base, &records)

let add = PositionChange(action: .buy, day: "2026-11-21",
                         shares: 5000, price: 1.2, fee: 5)
recordStep(add, &base, &records)

let sell = PositionChange(action: .sell, day: "2026-11-22",
                          shares: 3000, price: 1.8, fee: 2)
recordStep(sell, &base, &records)

let dividend = PositionChange(action: .distribution, day: "2026-11-23",
                              fee: 0, distribution: 12.34)
recordStep(dividend, &base, &records)

let inferred = PositionJournalReplay.inferBase(current: base, records: records)
let replayed = try! PositionJournalReplay.replay(base: inferred!, records: records)
report["journal"] = [
    "steps": steps,
    "base": [
        "shares": numberText(inferred?.shares),
        "cost": numberText(inferred?.costPerShare)
    ],
    "replayed": [
        "shares": numberText(replayed.shares),
        "cost": numberText(replayed.costPerShare)
    ]
]

// MARK: - CSV

let csvHoldings = [
    Holding(fund: Fund(code: "007339", name: "易方达, \"沪深300\"", kind: "指数型"),
            shares: Decimal(string: "10000"), costPerShare: Decimal(string: "1.5"), groups: [.macd]),
    Holding(fund: Fund(code: "050025", name: "=博时标普", kind: "QDII"),
            shares: 0, costPerShare: nil, groups: [.red])
]
let exportData = HoldingCSV.export(csvHoldings)
let exported = String(decoding: exportData, as: UTF8.self)
let catalog = ["007339": Fund(code: "007339", name: "目录名称", kind: "目录类型")]
let parsed = try! HoldingCSV.parse(exportData, catalog: catalog)
report["csv"] = [
    "exported": exported,
    "exportedHex": exportData.map { String(format: "%02x", $0) }.joined(),
    "invalid": parsed.invalid,
    "parsed": parsed.holdings.map { holding -> [String: Any] in
        [
            "code": holding.id,
            "name": holding.fund.name,
            "kind": holding.fund.kind,
            "shares": numberText(holding.shares),
            "cost": numberText(holding.costPerShare),
            "groups": holding.groupValues.map(\.rawValue)
        ]
    }
]

// MARK: - Search

let searchCatalog = [
    Fund(code: "007339", name: "易方达沪深300ETF联接C", kind: "指数型", initials: "YFD", pinyin: "yifangda"),
    Fund(code: "050025", name: "博时标普500ETF联接A", kind: "QDII", initials: "BS", pinyin: "boshi"),
    Fund(code: "161725", name: "招商中证白酒指数", kind: "指数型", initials: "ZS", pinyin: "zhaoshang")
]
report["search"] = ["0073", "沪深", "yfd", "boshi", "050025", "白酒", "不存在"].map { keyword -> [String: Any] in
    [
        "keyword": keyword,
        "codes": FundSearch.catalogResults(searchCatalog, keyword: keyword).map(\.code)
    ]
}

// MARK: - Observation

func makeSeries(_ values: [Double]) -> [ObservationPoint] {
    values.enumerated().map { index, value in
        let day = dayString(Calendar.current.date(byAdding: .day, value: index, to: iso("2026-09-01T00:00:00Z"))!)
        return ObservationPoint(day: day, value: Decimal(string: String(format: "%.6f", value))!)
    }
}

let smooth = makeSeries((0..<80).map { 1.0 + sin(Double($0) / 7.0) * 0.1 + Double($0) * 0.001 })
let reboundValues: [Double] = (0..<80).map { index -> Double in
    if index < 74 {
        return 1.5 - Double(index) * 0.004
    }
    let bottom = 1.5 - 74.0 * 0.004
    return bottom + Double(index - 74) * 0.02
}
let rebound = makeSeries(reboundValues)

func macdReport(_ series: [ObservationPoint]) -> [String: Any] {
    let analysis = ObservationAnalysis.macd(series)!
    return [
        "signal": analysis.currentSignal,
        "bullish": analysis.isBullish,
        "count": analysis.points.count,
        "last": analysis.points.suffix(3).map { point -> [String: Any] in
            [
                "day": point.day,
                "nav": point.nav,
                "dif": point.dif,
                "dea": point.dea,
                "histogram": point.histogram,
                "crossing": point.crossing
            ]
        }
    ]
}

func bandReport(_ series: [ObservationPoint]) -> [String: Any] {
    let history = ObservationAnalysis.bands(series)!
    let last = history.points.last!
    return [
        "count": history.points.count,
        "boxHigh": history.boxHigh,
        "boxLow": history.boxLow,
        "last": [
            "day": last.day,
            "nav": last.nav,
            "percentile": last.percentile,
            "movingAverage": doubleText(last.movingAverage),
            "upper": doubleText(last.bollingerUpper),
            "lower": doubleText(last.bollingerLower)
        ]
    ]
}

report["observation"] = [
    "smooth": ["macd": macdReport(smooth), "bands": bandReport(smooth)],
    "rebound": ["macd": macdReport(rebound), "bands": bandReport(rebound)]
]

// MARK: - Futures axis

let dayStart = iso("2026-11-26T01:00:00Z")
let dayTimes = (0...36).map { dayStart.addingTimeInterval(Double($0) * 600) }
let nightStart = iso("2026-11-26T10:00:00Z")
let nightTimes = (0...276).map { nightStart.addingTimeInterval(Double($0) * 300) }

report["futures"] = [
    ["label": "day", "indices": FuturesAxis.tickIndices(times: dayTimes, visible: 0...36)],
    ["label": "night", "indices": FuturesAxis.tickIndices(times: nightTimes, visible: 0...276)]
]

// MARK: - Output

let output = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write(Data("\n".utf8))
