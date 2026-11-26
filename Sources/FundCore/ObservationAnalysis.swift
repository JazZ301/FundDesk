import Foundation

public struct MACDAnalysisPoint: Equatable, Identifiable, Sendable {
    public var id: String { day }
    public let day: String
    public let nav: Double
    public let dif: Double
    public let dea: Double
    public let histogram: Double
    public let crossing: Int

    public init(day: String, nav: Double, dif: Double, dea: Double, histogram: Double, crossing: Int) {
        self.day = day
        self.nav = nav
        self.dif = dif
        self.dea = dea
        self.histogram = histogram
        self.crossing = crossing
    }
}

public struct MACDAnalysis: Sendable {
    public let points: [MACDAnalysisPoint]
    public let currentSignal: String
    public let isBullish: Bool

    public init(points: [MACDAnalysisPoint], currentSignal: String, isBullish: Bool) {
        self.points = points
        self.currentSignal = currentSignal
        self.isBullish = isBullish
    }
}

public struct BandHistoryPoint: Equatable, Identifiable, Sendable {
    public var id: String { day }
    public let day: String
    public let nav: Double
    public let percentile: Double
    public let movingAverage: Double?
    public let bollingerUpper: Double?
    public let bollingerLower: Double?

    public init(
        day: String, nav: Double, percentile: Double, movingAverage: Double?,
        bollingerUpper: Double?, bollingerLower: Double?
    ) {
        self.day = day
        self.nav = nav
        self.percentile = percentile
        self.movingAverage = movingAverage
        self.bollingerUpper = bollingerUpper
        self.bollingerLower = bollingerLower
    }
}

public struct BandHistory: Sendable {
    public let points: [BandHistoryPoint]
    public let boxHigh: Double
    public let boxLow: Double

    public init(points: [BandHistoryPoint], boxHigh: Double, boxLow: Double) {
        self.points = points
        self.boxHigh = boxHigh
        self.boxLow = boxLow
    }
}

public enum ObservationAnalysis {
    public static func macd(_ series: [ObservationPoint]) -> MACDAnalysis? {
        let sorted = series.sorted { $0.day < $1.day }
        guard sorted.count >= 35 else { return nil }
        let values = sorted.map { NSDecimalNumber(decimal: $0.value).doubleValue }
        let indicators = macdIndicators(values)
        var points: [MACDAnalysisPoint] = []
        points.reserveCapacity(values.count)
        for index in values.indices {
            var crossing = 0
            if index > 0 {
                let priorDelta = indicators[index - 1].histogram
                let currentDelta = indicators[index].histogram
                if priorDelta <= 0, currentDelta > 0 {
                    crossing = 1
                } else if priorDelta >= 0, currentDelta < 0 {
                    crossing = -1
                }
            }
            points.append(MACDAnalysisPoint(
                day: sorted[index].day,
                nav: values[index],
                dif: indicators[index].dif,
                dea: indicators[index].dea,
                histogram: indicators[index].histogram,
                crossing: crossing
            ))
        }
        guard let latest = points.last else { return nil }
        let bullish = latest.histogram >= 0
        if latest.crossing == 1 {
            return MACDAnalysis(points: points, currentSignal: "今日金叉 · 买入", isBullish: true)
        }
        if latest.crossing == -1 {
            return MACDAnalysis(points: points, currentSignal: "今日死叉 · 卖出", isBullish: false)
        }
        var run = 1
        var index = points.count - 2
        while index >= 0, (points[index].histogram >= 0) == bullish {
            run += 1
            index -= 1
        }
        return MACDAnalysis(
            points: points,
            currentSignal: bullish ? "红柱第 \(run) 日 · 持有" : "绿柱第 \(run) 日 · 空仓",
            isBullish: bullish
        )
    }

    public static func bands(_ series: [ObservationPoint], displayLimit: Int = 365) -> BandHistory? {
        let sorted = series.sorted { $0.day < $1.day }
        guard sorted.count >= 60 else { return nil }
        let values = sorted.map { NSDecimalNumber(decimal: $0.value).doubleValue }
        var points: [BandHistoryPoint] = []
        points.reserveCapacity(values.count)
        for index in values.indices {
            let percentile: Double
            if index >= 249 {
                let window = Array(values[(index - 249)...index])
                let low = window.min() ?? values[index]
                let high = window.max() ?? values[index]
                percentile = high > low ? min(100, max(0, (values[index] - low) / (high - low) * 100)) : 50
            } else {
                percentile = 50
            }
            let movingAverage = index >= 59 ? average(values[(index - 59)...index]) : nil
            let bollinger: (Double, Double)?
            if index >= 19 {
                let window = Array(values[(index - 19)...index])
                let mean = average(window)
                let variance = window.reduce(0) { $0 + pow($1 - mean, 2) } / Double(window.count)
                let deviation = sqrt(variance)
                bollinger = (mean + deviation * 2, mean - deviation * 2)
            } else {
                bollinger = nil
            }
            points.append(BandHistoryPoint(
                day: sorted[index].day,
                nav: values[index],
                percentile: percentile,
                movingAverage: movingAverage,
                bollingerUpper: bollinger?.0,
                bollingerLower: bollinger?.1
            ))
        }
        let visible = Array(points.suffix(max(60, displayLimit)))
        let boxWindow = Array(values.suffix(250))
        return BandHistory(
            points: visible,
            boxHigh: boxWindow.max() ?? values.last!,
            boxLow: boxWindow.min() ?? values.last!
        )
    }

    public static func macdIndicators(_ values: [Double]) -> [(dif: Double, dea: Double, histogram: Double)] {
        let fast = ema(values, period: 12)
        let slow = ema(values, period: 26)
        let dif = zip(fast, slow).map(-)
        return zip(dif, ema(dif, period: 9)).map { ($0, $1, 2 * ($0 - $1)) }
    }

    private static func ema(_ values: [Double], period: Int) -> [Double] {
        let multiplier = 2.0 / Double(period + 1)
        var result: [Double] = []
        result.reserveCapacity(values.count)
        for value in values {
            let prior = result.last
            result.append(prior.map { value * multiplier + $0 * (1 - multiplier) } ?? value)
        }
        return result
    }

    private static func average<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        let rows = Array(values)
        return rows.reduce(0, +) / Double(max(1, rows.count))
    }
}
