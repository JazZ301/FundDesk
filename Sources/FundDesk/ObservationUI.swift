import Charts
import FundCore
import SwiftUI

struct ObservationMetricGrid: View {
    let metrics: [ObservationMetric]

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 5) {
                    Text(metric.label)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = metric.note {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .padding(10)
                .background(Display.panelRaised, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(Display.stroke)
                }
            }
        }
    }
}

struct MACDObservationDashboard: View {
    let observation: FundObservation
    let analysis: MACDAnalysis?

    private var sourceCaption: String {
        let source = "MACD 本地数据"
        if let day = observation.series?.last?.day {
            return source + " · 净值更新至 " + day
        }
        return observation.source == source ? source + " · 更新至 " + observation.updatedDay : source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            sourceHeader
            scoreCard
            if let analysis {
                MACDChartCard(analysis: analysis)
            }
        }
    }

    private var sourceHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("MACD 战法适配").font(.headline)
                Text(sourceCaption)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let analysis {
                Text(analysis.currentSignal)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(analysis.isBullish ? Display.up : Display.down)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (analysis.isBullish ? Display.up : Display.down).opacity(0.10),
                        in: Capsule()
                    )
            }
        }
    }

    @ViewBuilder private var scoreCard: some View {
        if let rating = observation.macd {
            HStack(spacing: 14) {
                VStack(spacing: 1) {
                    Text(rating.score.map { Display.number($0, digits: 0) } ?? "—")
                        .font(.system(size: 32, weight: .bold).monospacedDigit())
                    Text("适配度").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 66, height: 66)
                .background(gradeColor(rating.grade).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(gradeColor(rating.grade).opacity(0.28))
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(rating.grade)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 22)
                            .background(gradeColor(rating.grade), in: RoundedRectangle(cornerRadius: 6))
                        Text(rating.recommendation).font(.headline)
                    }
                    Text("评分综合波动空间、回测超额、回撤改善、近一年一致性和费率。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let fee = rating.fee8 {
                        Text("持有满 8 个自然日赎回费 " + Display.number(fee, digits: 2) + "%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !rating.reasons.isEmpty {
                        Text(rating.reasons.joined(separator: "；"))
                            .font(.caption).foregroundStyle(Display.warning)
                    }
                }
                Spacer()
            }
            .researchCard()
        }
    }

    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "S": return Display.primary
        case "A": return Color(red: 0.25, green: 0.55, blue: 0.92)
        case "B": return Display.warning
        case "C": return Display.danger
        default: return .secondary
        }
    }
}

private struct MACDChartCard: View {
    let analysis: MACDAnalysis

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let nav: Double
        let dif: Double
        let dea: Double
        let histogram: Double
        let crossing: Int
    }

    private var points: [Point] {
        analysis.points.compactMap { point in
            guard let date = MarketClock.timestamp(day: point.day) else { return nil }
            return Point(
                id: point.day,
                date: date,
                nav: point.nav,
                dif: point.dif,
                dea: point.dea,
                histogram: point.histogram,
                crossing: point.crossing
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("净值与 MACD（近 \(points.count) 个交易日）").font(.headline)
                Spacer()
                legend("累计净值", color: Display.primary)
                legend("DIF", color: Display.warning)
                legend("DEA", color: Color(red: 0.48, green: 0.35, blue: 0.96))
                legend("买入", color: Display.up)
                legend("卖出", color: Display.down)
            }
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("日期", point.date), y: .value("累计净值", point.nav))
                        .foregroundStyle(Display.primary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(points.filter { $0.crossing != 0 }) { point in
                    PointMark(x: .value("日期", point.date), y: .value("累计净值", point.nav))
                        .foregroundStyle(point.crossing > 0 ? Display.up : Display.down)
                        .symbolSize(28)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 230)

            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("日期", point.date),
                        y: .value("MACD 柱", point.histogram),
                        width: .fixed(1.4)
                    )
                    .foregroundStyle(point.histogram >= 0 ? Display.up.opacity(0.72) : Display.down.opacity(0.72))
                    LineMark(x: .value("日期", point.date), y: .value("DIF", point.dif))
                        .foregroundStyle(Display.warning)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    LineMark(x: .value("日期", point.date), y: .value("DEA", point.dea))
                        .foregroundStyle(Color(red: 0.48, green: 0.35, blue: 0.96))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
                RuleMark(y: .value("零轴", 0)).foregroundStyle(Display.stroke)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(String(MarketClock.day(date).suffix(5)))
                        }
                    }
                }
            }
            .frame(height: 165)
        }
        .researchCard()
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct RedObservationDashboard: View {
    let observation: FundObservation
    let fund: Fund
    let research: ResearchServices

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            sourceHeader
            if let valuation = observation.valuation {
                valuationHero(valuation)
                HStack(alignment: .top, spacing: 8) {
                    percentileCard(valuation)
                    relativeCard(valuation)
                }
                if !valuation.anchors.isEmpty {
                    anchorGrid(valuation.anchors)
                }
            }
        }
    }

    private var sourceHeader: some View {
        let source = "红利本地数据"
        let caption = observation.source == source ? source + " · 更新至 " + observation.updatedDay : source
        return VStack(alignment: .leading, spacing: 3) {
            Text("红利估值锚").font(.headline)
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func valuationHero(_ valuation: RedValuation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(valuation.level)
                    .font(.headline)
                    .foregroundStyle(levelColor(valuation.level))
                Text("综合得分 \(valuation.total > 0 ? "+" : "")\(valuation.total) / \(valuation.maximum)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(levelColor(valuation.level))
                Spacer()
                if let ret = valuation.oneYearReturn {
                    Text("近一年 " + Display.percent(ret))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Display.changeColor(ret))
                }
            }
            ValuationGauge(total: valuation.total, maximum: valuation.maximum)
            HStack {
                Text(valuation.advice).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let description = valuation.levelDescription {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .researchCard()
    }

    private func percentileCard(_ valuation: RedValuation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("近一年累计净值分位").font(.caption).foregroundStyle(.secondary)
            Text(valuation.oneYearPercentile.map { Display.number($0, digits: 1) + "%" } ?? "—")
                .font(.title2.weight(.bold).monospacedDigit())
            PercentileGauge(value: valuation.oneYearPercentile.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 50)
            if let high = valuation.oneYearHigh, let low = valuation.oneYearLow {
                Text("区间 " + Display.number(low, digits: 4) + " ~ " + Display.number(high, digits: 4))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .researchCard()
    }

    private func relativeCard(_ valuation: RedValuation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("40 日相对强弱").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(valuation.relativeLabel ?? "—")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(relativeColor(valuation.relativeDifference))
                Spacer()
                Text(valuation.relativeDifference.map {
                    Display.number($0, digits: 2) + "pp"
                } ?? "—")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(relativeColor(valuation.relativeDifference))
            }
            RelativeStrengthGauge(value: valuation.relativeDifference.map {
                NSDecimalNumber(decimal: $0).doubleValue
            } ?? 0)
            Text(valuation.relativeAdvice ?? "与中证全指比较")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .researchCard()
    }

    private func anchorGrid(_ anchors: [ValuationAnchor]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("四锚评分").font(.headline)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(anchors) { anchor in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(anchor.name).font(.caption.weight(.semibold))
                            Spacer()
                            Text(anchor.score > 0 ? "+\(anchor.score)" : "\(anchor.score)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(anchorColor(anchor.score))
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(anchor.value)
                                .font(.title3.weight(.semibold).monospacedDigit())
                            Spacer()
                            Text(anchor.label)
                                .font(.caption2).foregroundStyle(anchorColor(anchor.score))
                                .lineLimit(2)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Display.stroke)
                                Capsule()
                                    .fill(anchorColor(anchor.score))
                                    .frame(width: geometry.size.width * anchorProgress(anchor.score))
                            }
                        }
                        .frame(height: 5)
                    }
                    .padding(10)
                    .background(Display.panelRaised, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(Display.stroke)
                    }
                    .help(anchor.rule ?? "")
                }
            }
        }
        .researchCard()
    }

    private func levelColor(_ level: String) -> Color {
        if level.contains("加仓") || level.contains("定投") { return Display.down }
        if level.contains("减仓") { return Display.up }
        return .secondary
    }

    private func relativeColor(_ value: Decimal?) -> Color {
        guard let value else { return .secondary }
        return value > 10 ? Display.up : (value < -1 ? Display.down : Display.warning)
    }

    private func anchorColor(_ score: Int) -> Color {
        switch score {
        case 2: return Display.down
        case 1: return Color(red: 0.30, green: 0.64, blue: 0.38)
        case 0: return .secondary
        default: return Display.up
        }
    }

    private func anchorProgress(_ score: Int) -> CGFloat {
        CGFloat(score + 1) / 3
    }
}

struct BandHistoryDashboard: View {
    let fund: Fund
    let research: ResearchServices
    let showsMACD: Bool

    @ViewState private var range = BandRange.year

    private enum BandRange: String, CaseIterable {
        case month = "近1月"
        case quarter = "近3月"
        case halfYear = "近6月"
        case year = "近1年"
        case threeYears = "近3年"

        var limit: Int {
            switch self {
            case .month: return 22
            case .quarter: return 66
            case .halfYear: return 125
            case .year: return 250
            case .threeYears: return 750
            }
        }
    }

    var body: some View {
        FeedPane(
            archive: research.archive,
            key: "observation-band-" + fund.code,
            maxAge: 3_600,
            title: "净值走势与分位历史",
            query: { try await research.providers.fundHistory(fund) }
        ) { history in
            let series = bandSeries(history)
            let bands = ObservationAnalysis.bands(series, displayLimit: range.limit)
            if showsMACD {
                onlineMACD(history.accumulated)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(fund.code + "  " + fund.name)
                                .font(.headline)
                                .lineLimit(1)
                            if let point = bands?.points.last {
                                Text(positionLabel(point.percentile))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(positionColor(point.percentile))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(positionColor(point.percentile).opacity(0.10), in: Capsule())
                            }
                        }
                        Text(
                            "累计净值口径（含分红再投）  ·  当前 "
                            + (bands?.points.last.map { String(format: "%.4f", $0.nav) } ?? "—")
                            + "  ·  近 250 交易日分位 "
                            + (bands?.points.last.map { String(format: "%.1f%%", $0.percentile) } ?? "—")
                            + "  ·  数据截至 " + (bands?.points.last?.day ?? "—")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("布林带 / MA60")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Display.primaryStrong, in: Capsule())
                }
                ThemedSegmentedControl(
                    options: BandRange.allCases, selection: $range, title: "时间区间"
                ) { $0.rawValue }
                BandObservationChart(history: bands)
                if let point = bands?.points.last {
                    HStack(spacing: 12) {
                        Label("当前分位 " + String(format: "%.1f%%", point.percentile),
                              systemImage: "percent")
                        Label("箱顶 " + String(format: "%.4f", bands?.boxHigh ?? point.nav),
                              systemImage: "arrow.up.to.line")
                        Label("箱底 " + String(format: "%.4f", bands?.boxLow ?? point.nav),
                              systemImage: "arrow.down.to.line")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .researchCard()
    }

    @ViewBuilder private func onlineMACD(_ accumulated: [PlotPoint]) -> some View {
        let series = accumulated.suffix(600).map {
            ObservationPoint(day: MarketClock.day($0.time), value: $0.value)
        }
        if let analysis = ObservationAnalysis.macd(series), let day = analysis.points.last?.day {
            Text("天天基金 · 累计净值更新至 " + day + " · " + analysis.currentSignal)
                .font(.caption).foregroundStyle(.secondary)
            MACDChartCard(analysis: analysis)
        } else {
            Label("缺少足够的累计净值序列，暂时无法绘制 MACD。", systemImage: "chart.xyaxis.line")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func bandSeries(_ history: FundHistory) -> [ObservationPoint] {
        if !history.accumulated.isEmpty {
            return history.accumulated.map {
                ObservationPoint(day: MarketClock.day($0.time), value: $0.value)
            }
        }
        return history.navs.map { ObservationPoint(day: $0.day, value: $0.value) }
    }

    private func positionLabel(_ value: Double) -> String {
        switch value {
        case ..<20: return "深度低位"
        case ..<35: return "低位"
        case ..<65: return "中枢"
        case ..<80: return "偏高"
        default: return "高位"
        }
    }

    private func positionColor(_ value: Double) -> Color {
        switch value {
        case ..<20: return Display.down
        case ..<35: return Display.down
        case ..<65: return .secondary
        case ..<80: return Display.warning
        default: return Display.up
        }
    }
}

private struct ValuationGauge: View {
    let total: Int
    let maximum: Int

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let minimum = -4
                let ratio = min(1, max(0, Double(total - minimum) / Double(maximum - minimum)))
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Color(red: 0.81, green: 0.25, blue: 0.25).frame(width: geometry.size.width * 4 / 12)
                        Color(red: 0.85, green: 0.51, blue: 0.14).frame(width: geometry.size.width * 2 / 12)
                        Color(red: 0.54, green: 0.58, blue: 0.65).frame(width: geometry.size.width * 2 / 12)
                        Color(red: 0.29, green: 0.62, blue: 0.42).frame(width: geometry.size.width * 2 / 12)
                        Color(red: 0.07, green: 0.50, blue: 0.36).frame(width: geometry.size.width * 2 / 12)
                    }
                    .clipShape(Capsule())
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 3, height: 17)
                        .offset(x: max(0, min(geometry.size.width - 3, geometry.size.width * ratio - 1.5)))
                }
            }
            .frame(height: 12)
            HStack {
                Text("减仓")
                Spacer()
                Text("观察")
                Spacer()
                Text("持有")
                Spacer()
                Text("定投")
                Spacer()
                Text("加仓")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct PercentileGauge: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Color(red: 0.30, green: 0.67, blue: 0.47).frame(width: geometry.size.width * 0.20)
                    Color(red: 0.83, green: 0.65, blue: 0.30).frame(width: geometry.size.width * 0.15)
                    Color(red: 0.72, green: 0.73, blue: 0.75).frame(width: geometry.size.width * 0.30)
                    Color(red: 0.91, green: 0.57, blue: 0.29).frame(width: geometry.size.width * 0.15)
                    Color(red: 0.81, green: 0.25, blue: 0.25).frame(width: geometry.size.width * 0.20)
                }
                .clipShape(Capsule())
                Circle()
                    .fill(Color.primary)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, min(geometry.size.width - 10, geometry.size.width * value / 100 - 5)))
            }
        }
        .frame(height: 10)
    }
}

private struct RelativeStrengthGauge: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            let ratio = min(1, max(0, (value + 10) / 40))
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Color(red: 0.17, green: 0.58, blue: 0.41).frame(width: geometry.size.width / 3)
                    Color(red: 0.87, green: 0.63, blue: 0.22).frame(width: geometry.size.width / 3)
                    Color(red: 0.81, green: 0.25, blue: 0.25).frame(width: geometry.size.width / 3)
                }
                .clipShape(Capsule())
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 3, height: 16)
                    .offset(x: max(0, min(geometry.size.width - 3, geometry.size.width * ratio - 1.5)))
            }
        }
        .frame(height: 10)
    }
}

private struct BandObservationChart: View {
    let history: BandHistory?

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let nav: Double
        let percentile: Double
        let movingAverage: Double?
        let bollingerUpper: Double?
        let bollingerLower: Double?
    }

    private var points: [Point] {
        history?.points.compactMap { point in
            guard let date = MarketClock.timestamp(day: point.day) else { return nil }
            return Point(
                id: point.day,
                date: date,
                nav: point.nav,
                percentile: point.percentile,
                movingAverage: point.movingAverage,
                bollingerUpper: point.bollingerUpper,
                bollingerLower: point.bollingerLower
            )
        } ?? []
    }

    var body: some View {
        if let history, points.count > 1 {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("累计净值").font(.caption.weight(.semibold))
                    Spacer()
                    Text("箱顶 " + String(format: "%.4f", history.boxHigh))
                    Text("箱底 " + String(format: "%.4f", history.boxLow))
                    Text("分位 " + String(format: "%.1f%%", points.last?.percentile ?? 0))
                }
                .font(.caption).foregroundStyle(.secondary)
                Chart {
                    ForEach(points) { point in
                        if let low = point.bollingerLower, let high = point.bollingerUpper {
                            AreaMark(
                                x: .value("日期", point.date),
                                yStart: .value("布林下轨", low),
                                yEnd: .value("布林上轨", high)
                            )
                            .foregroundStyle(Display.primary.opacity(0.09))
                        }
                    }
                    RuleMark(y: .value("箱顶", history.boxHigh))
                        .foregroundStyle(Display.up.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                    RuleMark(y: .value("箱底", history.boxLow))
                        .foregroundStyle(Display.down.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                    ForEach(points) { point in
                        LineMark(x: .value("日期", point.date), y: .value("累计净值", point.nav))
                            .foregroundStyle(Color(red: 0.10, green: 0.35, blue: 0.49))
                        if let moving = point.movingAverage {
                            LineMark(x: .value("日期", point.date), y: .value("MA60", moving))
                                .foregroundStyle(Display.warning)
                                .lineStyle(StrokeStyle(lineWidth: 1.2))
                        }
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 205)

                Chart {
                    RectangleMark(
                        xStart: .value("开始", points.first!.date),
                        xEnd: .value("结束", points.last!.date),
                        yStart: .value("低", 0),
                        yEnd: .value("高", 20)
                    ).foregroundStyle(Display.down.opacity(0.10))
                    RectangleMark(
                        xStart: .value("开始", points.first!.date),
                        xEnd: .value("结束", points.last!.date),
                        yStart: .value("低", 20),
                        yEnd: .value("高", 35)
                    ).foregroundStyle(Color.green.opacity(0.07))
                    RectangleMark(
                        xStart: .value("开始", points.first!.date),
                        xEnd: .value("结束", points.last!.date),
                        yStart: .value("低", 35),
                        yEnd: .value("高", 65)
                    ).foregroundStyle(Color.secondary.opacity(0.06))
                    RectangleMark(
                        xStart: .value("开始", points.first!.date),
                        xEnd: .value("结束", points.last!.date),
                        yStart: .value("低", 65),
                        yEnd: .value("高", 80)
                    ).foregroundStyle(Display.warning.opacity(0.09))
                    RectangleMark(
                        xStart: .value("开始", points.first!.date),
                        xEnd: .value("结束", points.last!.date),
                        yStart: .value("低", 80),
                        yEnd: .value("高", 100)
                    ).foregroundStyle(Display.up.opacity(0.09))
                    ForEach(points) { point in
                        LineMark(x: .value("日期", point.date), y: .value("一年分位", point.percentile))
                            .foregroundStyle(Color(red: 0.10, green: 0.35, blue: 0.49))
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 20, 35, 65, 80, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Int.self) {
                                Text("\(number)%")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(String(MarketClock.day(date).suffix(5)))
                            }
                        }
                    }
                }
                .frame(height: 118)
            }
        } else {
            Text("累计净值样本不足，暂时无法绘制布林带和一年分位历史。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
