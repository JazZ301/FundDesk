import Foundation

public enum MarketClock {
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    public static func day(_ date: Date = .now) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func timestamp(day: String, time: String = "00:00") -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let clock = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3, clock.count >= 2,
              (0...23).contains(clock[0]), (0...59).contains(clock[1]) else { return nil }
        let date = calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: clock[0], minute: clock[1],
            second: clock.count > 2 ? clock[2] : 0
        ))
        guard let date, self.day(date) == day else { return nil }
        return date
    }

    public static func canPollEstimates(_ date: Date = .now) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = parts.hour! * 60 + parts.minute!
        return (2...6).contains(parts.weekday!) && ((550...705).contains(minute) || (775...975).contains(minute))
    }

    public static func isFreshEstimate(_ quote: Estimate, now: Date) -> Bool {
        guard quote.marketDay == day(now), quote.timestamp <= now.addingTimeInterval(120) else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = parts.hour! * 60 + parts.minute!
        let movingMarket = (570...690).contains(minute) || (780...900).contains(minute)
        let maxAge: TimeInterval = movingMarket ? 25 * 60 : 9 * 60 * 60
        return now.timeIntervalSince(quote.timestamp) <= maxAge
    }
}

public enum RefreshInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30
    case sixtySeconds = 60

    public static let defaultValue: RefreshInterval = .tenSeconds
    public var id: Int { rawValue }
    public var label: String { "\(rawValue) 秒" }
}

public enum AppearanceTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public static let defaultValue: AppearanceTheme = .system
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "白色"
        case .dark: return "黑色"
        }
    }
}

public func decimal(_ value: String?) -> Decimal? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          value.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil
    else { return nil }
    return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
}

public struct Fund: Codable, Equatable, Identifiable, Sendable {
    public var id: String { code }
    public let code: String
    public var name: String
    public var kind: String
    public var initials: String
    public var pinyin: String
    public var isMoney: Bool { kind.contains("货币") }
    public var isCrossBorder: Bool {
        kind.localizedCaseInsensitiveContains("QDII") || name.localizedCaseInsensitiveContains("QDII")
            || kind.contains("海外") || kind.contains("跨境")
    }

    public init(code: String, name: String, kind: String = "", initials: String = "", pinyin: String = "") {
        self.code = code
        self.name = name
        self.kind = kind
        self.initials = initials
        self.pinyin = pinyin
    }

    public func matchesSearch(_ keyword: String) -> Bool {
        let normalized = keyword.filter { !$0.isWhitespace }.uppercased()
        guard !normalized.isEmpty else { return true }
        return code.hasPrefix(normalized)
            || name.filter { !$0.isWhitespace }.uppercased().contains(normalized)
            || initials.uppercased().hasPrefix(normalized)
            || pinyin.uppercased().contains(normalized)
    }

    public static func validCode(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

public enum FundGroup: String, Codable, CaseIterable, Sendable {
    case macd
    case red

    public var title: String {
        switch self {
        case .macd: return "MACD 观察"
        case .red: return "红利观察"
        }
    }
}

public struct Holding: Codable, Equatable, Identifiable, Sendable {
    public var id: String { fund.code }
    public var fund: Fund
    public var shares: Decimal?
    public var costPerShare: Decimal?
    public var groups: [FundGroup]?

    public init(fund: Fund, shares: Decimal? = nil, costPerShare: Decimal? = nil,
                groups: [FundGroup] = []) {
        self.fund = fund
        self.shares = shares
        self.costPerShare = costPerShare
        self.groups = groups.isEmpty ? nil : groups
    }

    public var groupValues: [FundGroup] { groups ?? [] }

    public mutating func add(_ group: FundGroup) {
        var values = groups ?? []
        guard !values.contains(group) else { return }
        values.append(group)
        groups = values
    }
}

public struct NAV: Codable, Equatable, Identifiable, Sendable {
    public var id: String { day }
    public var day: String
    public var value: Decimal
    public var rate: Decimal?
    public var annualizedRate: Decimal?
    public var cumulativeValue: Decimal?
    public var source: String
    public init(day: String, value: Decimal, rate: Decimal? = nil, annualizedRate: Decimal? = nil,
                cumulativeValue: Decimal? = nil, source: String) {
        self.day = day
        self.value = value
        self.rate = rate
        self.annualizedRate = annualizedRate
        self.cumulativeValue = cumulativeValue
        self.source = source
    }
}

public struct Estimate: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var marketDay: String
    public var baseDay: String?
    public var value: Decimal
    public var percent: Decimal
    public init(timestamp: Date, marketDay: String, baseDay: String?, value: Decimal, percent: Decimal) {
        self.timestamp = timestamp
        self.marketDay = marketDay
        self.baseDay = baseDay
        self.value = value
        self.percent = percent
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var history: [NAV] = []
    public var estimate: Estimate?
    public var navCheckedAt: Date?
    public var estimateCheckedAt: Date?
    public var estimateAvailable: Bool?
    public var nav: NAV? { history.last }

    public init() {}

    public mutating func mergeHistory(_ rows: [NAV]) {
        var byDay = Dictionary(grouping: history, by: \.day).compactMapValues(\.last)
        for row in rows {
            if let existing = byDay[row.day], existing.source == "天天基金", row.source == "新浪财经" {
                continue
            }
            byDay[row.day] = row
        }
        history = Array(byDay.values.sorted { $0.day < $1.day }.suffix(365))
    }

    public mutating func mergeEstimate(_ quote: Estimate) {
        guard estimate.map({ $0.timestamp > quote.timestamp }) != true else { return }
        estimate = quote
    }

    public func effectiveEstimate(now: Date) -> Estimate? {
        guard estimateAvailable != false, let estimate, MarketClock.isFreshEstimate(estimate, now: now),
              nav.map({ estimate.marketDay > $0.day }) ?? true else { return nil }
        return estimate
    }
}

public struct ObservationMetric: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let value: String
    public let note: String?

    public init(key: String, label: String, value: String, note: String? = nil) {
        self.key = key
        self.label = label
        self.value = value
        self.note = note
    }
}

public struct ObservationPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: String { day }
    public let day: String
    public let value: Decimal

    public init(day: String, value: Decimal) {
        self.day = day
        self.value = value
    }
}

public struct MACDRating: Codable, Equatable, Sendable {
    public var score: Decimal?
    public var grade: String
    public var recommendation: String
    public var fee8: Decimal?
    public var reasons: [String]

    public init(score: Decimal?, grade: String, recommendation: String,
                fee8: Decimal? = nil, reasons: [String] = []) {
        self.score = score
        self.grade = grade
        self.recommendation = recommendation
        self.fee8 = fee8
        self.reasons = reasons
    }
}

public struct ValuationAnchor: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let value: String
    public let score: Int
    public let label: String
    public let rule: String?

    public init(key: String, name: String, value: String, score: Int,
                label: String, rule: String? = nil) {
        self.key = key
        self.name = name
        self.value = value
        self.score = score
        self.label = label
        self.rule = rule
    }
}

public struct RedValuation: Codable, Equatable, Sendable {
    public var total: Int
    public var maximum: Int
    public var level: String
    public var levelDescription: String?
    public var advice: String
    public var anchors: [ValuationAnchor]
    public var oneYearPercentile: Decimal?
    public var oneYearHigh: Decimal?
    public var oneYearLow: Decimal?
    public var oneYearReturn: Decimal?
    public var fromHigh: Decimal?
    public var relativeDifference: Decimal?
    public var relativeLabel: String?
    public var relativeAdvice: String?

    public init(
        total: Int, maximum: Int, level: String, levelDescription: String? = nil,
        advice: String, anchors: [ValuationAnchor], oneYearPercentile: Decimal? = nil,
        oneYearHigh: Decimal? = nil, oneYearLow: Decimal? = nil,
        oneYearReturn: Decimal? = nil, fromHigh: Decimal? = nil,
        relativeDifference: Decimal? = nil, relativeLabel: String? = nil,
        relativeAdvice: String? = nil
    ) {
        self.total = total
        self.maximum = maximum
        self.level = level
        self.levelDescription = levelDescription
        self.advice = advice
        self.anchors = anchors
        self.oneYearPercentile = oneYearPercentile
        self.oneYearHigh = oneYearHigh
        self.oneYearLow = oneYearLow
        self.oneYearReturn = oneYearReturn
        self.fromHigh = fromHigh
        self.relativeDifference = relativeDifference
        self.relativeLabel = relativeLabel
        self.relativeAdvice = relativeAdvice
    }
}

public struct FundObservation: Codable, Equatable, Sendable {
    public var updatedDay: String
    public var source: String
    public var metrics: [ObservationMetric]
    public var series: [ObservationPoint]?
    public var macd: MACDRating?
    public var valuation: RedValuation?

    public init(
        updatedDay: String, source: String, metrics: [ObservationMetric],
        series: [ObservationPoint]? = nil, macd: MACDRating? = nil,
        valuation: RedValuation? = nil
    ) {
        self.updatedDay = updatedDay
        self.source = source
        self.metrics = metrics
        self.series = series
        self.macd = macd
        self.valuation = valuation
    }
}

public enum FundTableColumn: String, CaseIterable, Sendable {
    case name
    case estimateRate
    case dayProfit
    case value
    case profit
    case profitRate
    case estimateTime
    case code
    case nav
    case navDate
    case navRate
    case estimate
}

public enum HoldingPlacement: Sendable {
    case before
    case after
}

public enum FundDetailTab: String, CaseIterable, Sendable {
    case estimate
    case history
    case returns
    case holdings
    case profile
    case observation
}

public struct Board: Codable, Equatable, Sendable {
    public var holdings: [Holding] = []
    public var snapshots: [String: Snapshot] = [:]
    public var observations: [String: FundObservation]?
    public var journals: [String: [PositionRecord]]?
    public var refreshInterval: Int?
    public var appearanceTheme: String?
    public var fundColumnOrder: [String]?
    public var hiddenFundColumnIDs: [String]?
    public var fundDetailTabOrder: [String]?
    public init() {}

    public var refreshIntervalValue: RefreshInterval {
        RefreshInterval(rawValue: refreshInterval ?? RefreshInterval.defaultValue.rawValue)
            ?? .defaultValue
    }

    public var appearanceThemeValue: AppearanceTheme {
        AppearanceTheme(rawValue: appearanceTheme ?? "") ?? .defaultValue
    }

    public var fundColumns: [FundTableColumn] {
        let saved = (fundColumnOrder ?? []).compactMap(FundTableColumn.init(rawValue:))
        var seen: Set<FundTableColumn> = []
        return (saved + FundTableColumn.allCases).filter { seen.insert($0).inserted }
    }

    public var visibleFundColumns: [FundTableColumn] {
        let hidden = Set(hiddenFundColumnIDs ?? [])
        return fundColumns.filter { $0 == .name || !hidden.contains($0.rawValue) }
    }

    public mutating func setVisibleFundColumns(_ columns: Set<FundTableColumn>) {
        let hidden = FundTableColumn.allCases.filter { $0 != .name && !columns.contains($0) }
        hiddenFundColumnIDs = hidden.isEmpty ? nil : hidden.map(\.rawValue)
    }

    public mutating func reorderVisibleFundColumns(_ columns: [FundTableColumn]) -> Bool {
        let visible = visibleFundColumns
        let visibleSet = Set(visible)
        guard columns != visible, columns.count == visible.count, Set(columns) == visibleSet else { return false }

        var ordered = fundColumns
        let visibleSlots = ordered.indices.filter { visibleSet.contains(ordered[$0]) }
        for (slot, column) in zip(visibleSlots, columns) {
            ordered[slot] = column
        }
        fundColumnOrder = ordered.map(\.rawValue)
        return true
    }

    public var fundDetailTabs: [FundDetailTab] {
        let saved = (fundDetailTabOrder ?? []).compactMap(FundDetailTab.init(rawValue:))
        var seen: Set<FundDetailTab> = []
        return (saved + FundDetailTab.allCases).filter { seen.insert($0).inserted }
    }

    public func visibleFundDetailTabs(showsObservation: Bool) -> [FundDetailTab] {
        fundDetailTabs.filter { showsObservation || $0 != .observation }
    }

    public mutating func moveFundDetailTab(_ source: FundDetailTab, to target: FundDetailTab, showsObservation: Bool) -> Bool {
        var ordered = fundDetailTabs
        let slots = ordered.indices.filter { showsObservation || ordered[$0] != .observation }
        var visible = slots.map { ordered[$0] }
        guard source != target,
              let from = visible.firstIndex(of: source),
              let to = visible.firstIndex(of: target)
        else { return false }
        visible.remove(at: from)
        visible.insert(source, at: to)
        for (slot, tab) in zip(slots, visible) {
            ordered[slot] = tab
        }
        fundDetailTabOrder = ordered.map(\.rawValue)
        return true
    }

    @discardableResult
    public mutating func moveHolding(
        _ code: String, relativeTo target: String, placement: HoldingPlacement, visibleCodes: Set<String>
    ) -> Bool {
        guard code != target else { return false }
        let slots = holdings.indices.filter { visibleCodes.contains(holdings[$0].id) }
        let visible = slots.map { holdings[$0] }
        guard let source = visible.firstIndex(where: { $0.id == code }),
              let destination = visible.firstIndex(where: { $0.id == target })
        else { return false }

        let insertion = destination + (placement == .after ? 1 : 0) - (source < destination ? 1 : 0)
        guard source != insertion else { return false }
        var reordered = visible
        let holding = reordered.remove(at: source)
        reordered.insert(holding, at: insertion)
        for (slot, holding) in zip(slots, reordered) {
            holdings[slot] = holding
        }
        return true
    }
}

public enum DayProfitExclusion: String, CaseIterable, Sendable {
    case missingNAV = "缺少正式净值"
    case moneyFund = "货币基金"
    case incompletePublishedNAV = "已披露，缺少涨跌幅或前一净值"
    case missingEstimate = "暂无可用估值"
    case differentMarketDay = "估值归属其他交易日"
    case staleEstimate = "估值时间超出有效范围"
    case mismatchedBase = "估值基准日与正式净值日不一致"
}

public struct FundMetrics {
    public let value: Decimal?
    public let rate: Decimal?
    public let profit: Decimal?
    public let estimatedDayProfit: Decimal?
    public let publishedDayProfit: Decimal?
    public let dayProfitExclusion: DayProfitExclusion?

    public init(holding: Holding, snapshot: Snapshot, now: Date = .now) {
        guard let shares = holding.shares, shares > 0, let nav = snapshot.nav else {
            value = nil
            rate = nil
            profit = nil
            estimatedDayProfit = nil
            publishedDayProfit = nil
            dayProfitExclusion = (holding.shares ?? 0) > 0 ? .missingNAV : nil
            return
        }
        let isMoney = holding.fund.isMoney || nav.annualizedRate != nil
        let unitValue: Decimal = isMoney ? 1 : nav.value
        value = shares * unitValue
        if let cost = holding.costPerShare, cost > 0, !isMoney {
            profit = (unitValue - cost) * shares
            rate = (unitValue - cost) / cost * 100
        } else {
            profit = nil
            rate = nil
        }

        let day = MarketClock.day(now)
        var estimated: Decimal?
        var published: Decimal?
        var exclusion: DayProfitExclusion?
        if isMoney {
            exclusion = .moneyFund
        } else if nav.day == day {
            if let rate = nav.rate, let previous = snapshot.history.dropLast().last,
               previous.day < nav.day, previous.annualizedRate == nil {
                published = previous.value * rate / 100 * shares
            } else {
                exclusion = .incompletePublishedNAV
            }
        } else if let quote = snapshot.estimate, quote.marketDay != day {
            exclusion = .differentMarketDay
        } else if let quote = snapshot.effectiveEstimate(now: now) {
            if quote.baseDay == nav.day {
                estimated = (quote.value - nav.value) * shares
            } else {
                exclusion = .mismatchedBase
            }
        } else {
            exclusion = snapshot.estimate == nil || snapshot.estimateAvailable == false
                ? .missingEstimate : .staleEstimate
        }
        estimatedDayProfit = estimated
        publishedDayProfit = published
        dayProfitExclusion = exclusion
    }
}

public struct Portfolio {
    public let day: String
    public private(set) var value: Decimal?
    public private(set) var estimatedDayProfit: Decimal?
    public private(set) var publishedDayProfit: Decimal?
    public private(set) var estimatedDayCount = 0
    public private(set) var publishedDayCount = 0
    public private(set) var holdingCount = 0
    public private(set) var dayProfitExclusions: [DayProfitExclusion: Int] = [:]
    public private(set) var profit: Decimal?
    public private(set) var estimatedCoverage: Decimal?
    public private(set) var missingValuationCount = 0

    public var dayProfit: Decimal? {
        guard publishedDayProfit != nil || estimatedDayProfit != nil else { return nil }
        return (publishedDayProfit ?? 0) + (estimatedDayProfit ?? 0)
    }

    public var coveredDayCount: Int { estimatedDayCount + publishedDayCount }

    public init(board: Board, now: Date = .now) {
        day = MarketClock.day(now)
        var estimatedValue: Decimal = 0
        for holding in board.holdings where (holding.shares ?? 0) > 0 {
            holdingCount += 1
            let metrics = FundMetrics(holding: holding, snapshot: board.snapshots[holding.id] ?? Snapshot(), now: now)
            if let val = metrics.value {
                value = (value ?? 0) + val
                if metrics.estimatedDayProfit != nil { estimatedValue += val }
            } else {
                missingValuationCount += 1
            }
            if let gains = metrics.publishedDayProfit {
                publishedDayProfit = (publishedDayProfit ?? 0) + gains
                publishedDayCount += 1
            } else if let gains = metrics.estimatedDayProfit {
                estimatedDayProfit = (estimatedDayProfit ?? 0) + gains
                estimatedDayCount += 1
            } else if let exclusion = metrics.dayProfitExclusion {
                dayProfitExclusions[exclusion, default: 0] += 1
            }
            if let gains = metrics.profit { profit = (profit ?? 0) + gains }
        }
        if let value, value > 0, missingValuationCount == 0 {
            estimatedCoverage = estimatedValue / value * 100
        }
    }
}

public struct EstimateHealth {
    public let freshCount: Int
    public let staleCount: Int
    public let failedCount: Int
    public let missingCount: Int

    public var issueCount: Int { staleCount + failedCount }
    public var hasIssue: Bool { issueCount > 0 }

    public init(board: Board, failures: Set<String> = [], now: Date = .now) {
        var fresh = 0
        var stale = 0
        var failed = 0
        var missing = 0
        for holding in board.holdings where !holding.fund.isMoney {
            if failures.contains(holding.id) {
                failed += 1
                continue
            }
            let snapshot = board.snapshots[holding.id] ?? Snapshot()
            if snapshot.effectiveEstimate(now: now) != nil {
                fresh += 1
            } else if snapshot.estimate != nil {
                stale += 1
            } else {
                missing += 1
            }
        }
        freshCount = fresh
        staleCount = stale
        failedCount = failed
        missingCount = missing
    }
}
