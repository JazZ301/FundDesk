import Charts
import FundCore
import SwiftUI

struct FuturesDetail: View {
    let instrument: FuturesInstrument
    let quote: FuturesQuote?
    let research: ResearchServices
    let goBack: () -> Void
    @ViewState private var period = Period.intraday

    private enum Period: String, CaseIterable {
        case intraday = "分时"
        case fiveSessions = "五日"
        case daily = "日K"
        case weekly = "周K"
        case monthly = "月K"

        var candlePeriod: FuturesCandle.Period {
            switch self {
            case .weekly: return .weekly
            case .monthly: return .monthly
            default: return .daily
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("返回期货列表", systemImage: "chevron.left", action: goBack)
                    .keyboardShortcut(.cancelAction)
                Text(instrument.title).font(.title2.weight(.semibold))
                Text(instrument.rawValue + " · " + instrument.quoteKind)
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text("新浪财经 · 北京时间").font(.caption).foregroundStyle(.secondary)
            }
            quoteSummary
            ThemedSegmentedControl(
                options: Period.allCases, selection: $period, title: "图表周期"
            ) { $0.rawValue }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { chart }
                    .padding(.trailing, 3)
            }
        }
    }

    private var quoteSummary: some View {
        let tint = Display.changeColor(quote?.change)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 13) {
                Text(Display.number(quote?.price, digits: 2)).font(.largeTitle.weight(.semibold))
                Text(Display.signedNumber(quote?.change)).font(.title3.weight(.semibold))
                Text(Display.percent(quote?.rate)).font(.title3.weight(.semibold))
                    .foregroundStyle(Display.changeColor(quote?.rate))
                Spacer()
                Text(quote.map {
                    let seconds = MarketClock.calendar.component(.second, from: $0.time)
                    return "报价 " + Display.chinaDateTime($0.time) + String(format: ":%02d", seconds)
                } ?? "暂无报价")
                    .font(.caption).foregroundStyle(Color.secondary)
            }
            .monospacedDigit()
            .foregroundStyle(tint)
            HStack(spacing: 8) {
                stat("今开", Display.number(quote?.open, digits: 2))
                stat("最高", Display.number(quote?.high, digits: 2))
                stat("最低", Display.number(quote?.low, digits: 2))
                stat("参考价", Display.number(quote?.reference, digits: 2))
                stat("振幅", quote?.amplitude.map { Display.unsigPercent($0) } ?? "—")
                stat("持仓量", Display.number(quote?.openInterest, digits: 0))
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium).monospacedDigit())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Display.panelRaised, in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder private var chart: some View {
        let providers = research.providers
        let code = instrument.rawValue
        let quoteDay = quote?.time
        switch period {
        case .intraday:
            FeedPane(archive: research.archive, key: "futures-intraday-" + code, maxAge: 120,
                     autoRefresh: true, title: "分时走势",
                     shouldRefresh: { $0.averages == nil },
                     query: { try await providers.futuresIntraday(instrument) }) { trend in
                let averages = Dictionary(uniqueKeysWithValues: (trend.averages ?? []).map { ($0.time, $0.value) })
                let samples = trend.points.map { point in
                    FuturesChart.Sample(stamp: Display.chinaDateTime(point.time), axis: Display.dayTime(point.time),
                                        time: point.time, price: point.value, average: averages[point.time])
                }
                FuturesChart(samples: samples, reference: trend.reference)
            }
        case .fiveSessions:
            FeedPane(archive: research.archive, key: "futures-five-" + code, maxAge: 120,
                     autoRefresh: true, title: "五日走势",
                     query: { try await providers.futuresFiveSessions(instrument, quoteDay: quoteDay) }) { series in
                // The daily endpoint does not certify that the latest session has closed.
                let unconfirmedDay = series.isMinuteSeries ? nil : series.sessions.last?.day
                let samples = series.sessions.flatMap { session in
                    let stamp = MarketClock.day(session.day)
                    return session.prices.map {
                        FuturesChart.Sample(stamp: stamp, axis: String(stamp.suffix(5)), price: $0,
                                            unconfirmedClose: session.day == unconfirmedDay)
                    }
                }
                HStack(spacing: 12) {
                    Text(series.isMinuteSeries ? "近五个交易日分钟走势" : "近五个交易日日线 · 分钟数据暂不可用")
                        .foregroundStyle(.secondary)
                    if unconfirmedDay != nil {
                        Label("末点可能为盘中价", systemImage: "clock").foregroundStyle(Display.warning)
                    }
                }
                .font(.caption)
                FuturesChart(samples: samples, reference: series.reference)
            }
        case .daily, .weekly, .monthly:
            FeedPane(archive: research.archive, key: "futures-daily-" + code, maxAge: 120,
                     autoRefresh: true, title: "K 线",
                     query: { try await providers.futuresDaily(instrument) }) { daily in
                let bars = FuturesCandle.aggregate(daily, period: period.candlePeriod)
                let samples = bars.map { bar in
                    let stamp = MarketClock.day(bar.day)
                    return FuturesChart.Sample(stamp: stamp, axis: String(stamp.dropFirst(2)),
                                               price: bar.close, candle: bar)
                }
                FuturesChart(samples: samples, visibleLimit: 90)
                    .id(period)
            }
        }
    }
}

private struct FuturesChart: View {
    struct Sample {
        let stamp: String
        let axis: String
        var time: Date? = nil
        let price: Decimal
        var average: Decimal?
        var candle: FuturesCandle?
        var unconfirmedClose = false
    }

    let samples: [Sample]
    var reference: Decimal?
    var visibleLimit: Int = .max
    @ViewState private var selection: Int?

    var body: some View {
        if !samples.isEmpty {
            let first = max(0, samples.count - visibleLimit)
            let last = samples.count - 1
            let visible = first...last
            let step = max(1, (visible.count + 799) / 800)
            let drawn = Array(stride(from: first, to: last, by: step)) + [last]
            let selected = selection.flatMap { visible.contains($0) ? $0 : nil }
            let current = selected ?? last
            let indicators = ObservationAnalysis.macdIndicators(samples.map { number($0.price) })
            let xDomain = (Double(first) - 0.5)...(Double(last) + 0.5)
            VStack(alignment: .leading, spacing: 7) {
                readout(samples[current])
                Chart {
                    ForEach(drawn, id: \.self) { index in
                        priceMarks(index: index)
                    }
                    if let reference {
                        RuleMark(y: .value("参考价", number(reference)))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                    if samples[last].unconfirmedClose {
                        PointMark(x: .value("位置", Double(last)), y: .value("价格", number(samples[last].price)))
                            .foregroundStyle(Display.warning)
                    }
                    if let selected {
                        RuleMark(x: .value("位置", Double(selected)))
                            .foregroundStyle(Color.secondary.opacity(0.45))
                        PointMark(x: .value("位置", Double(selected)),
                                  y: .value("价格", number(samples[selected].price)))
                            .foregroundStyle(samples[selected].unconfirmedClose ? Display.warning : Display.primary)
                    }
                }
                .chartYScale(domain: priceBounds(visible))
                .chartXScale(domain: xDomain)
                .chartXAxis { priceAxis(visible) }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let point):
                                    let plot = geometry[proxy.plotAreaFrame]
                                    guard plot.contains(point),
                                          let position: Double = proxy.value(atX: point.x - plot.minX) else {
                                        selection = nil
                                        return
                                    }
                                    selection = min(last, max(first, Int(position.rounded())))
                                case .ended:
                                    selection = nil
                                }
                            }
                    }
                }
                .frame(height: 220)
                .accessibilityLabel(samples[last].candle == nil ? "价格走势" : "蜡烛图")
                if samples.count >= 35 {
                    macdChart(indicators, drawn: drawn, current: current, domain: xDomain)
                }
            }
        }
    }

    private func readout(_ point: Sample) -> some View {
        HStack(spacing: 12) {
            Text(point.stamp)
            if point.unconfirmedClose {
                Text("收盘未确认").foregroundStyle(Display.warning)
            }
            if let candle = point.candle {
                Text("开 " + Display.number(candle.open, digits: 2))
                Text("高 " + Display.number(candle.high, digits: 2))
                Text("低 " + Display.number(candle.low, digits: 2))
                Text("收 " + Display.number(candle.close, digits: 2))
            } else {
                Text("价格 " + Display.number(point.price, digits: 2)).foregroundStyle(Display.primaryStrong)
                if let average = point.average {
                    Text("均价 " + Display.number(average, digits: 2)).foregroundStyle(Display.warning)
                }
                if let reference, reference != 0 {
                    let rate = (point.price - reference) / abs(reference) * 100
                    Text(Display.percent(rate)).foregroundStyle(Display.changeColor(rate))
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    @ChartContentBuilder private func priceMarks(index: Int) -> some ChartContent {
        let point = samples[index]
        let x = PlottableValue.value("位置", Double(index))
        if let bar = point.candle {
            let color = bar.close == bar.open ? Color.secondary : Display.changeColor(bar.close - bar.open, digits: nil)
            RuleMark(x: x, yStart: .value("最低", number(bar.low)), yEnd: .value("最高", number(bar.high)))
                .foregroundStyle(color)
            let bottom = number(min(bar.open, bar.close))
            let top = number(max(bar.open, bar.close))
            if bottom == top {
                PointMark(x: x, y: .value("收盘", bottom)).symbolSize(9).foregroundStyle(color)
            } else {
                RectangleMark(xStart: .value("左边缘", Double(index) - 0.31),
                              xEnd: .value("右边缘", Double(index) + 0.31),
                              yStart: .value("开收较低", bottom), yEnd: .value("开收较高", top))
                    .foregroundStyle(color)
            }
        } else {
            if samples.count == 1 {
                PointMark(x: x, y: .value("价格", number(point.price))).foregroundStyle(Display.primary)
            } else {
                LineMark(x: x, y: .value("价格", number(point.price)), series: .value("线", "价格"))
                    .foregroundStyle(Display.primary)
            }
            if let average = point.average {
                LineMark(x: x, y: .value("均价", number(average)), series: .value("线", "均价"))
                    .foregroundStyle(Display.warning)
            }
        }
    }

    private func priceAxis(_ visible: ClosedRange<Int>) -> some AxisContent {
        let times = samples.compactMap(\.time)
        let marks: [Int]
        if times.count == samples.count, let first = times.first,
           let last = times.last, last > first {
            marks = FuturesAxis.tickIndices(times: times, visible: visible)
        } else {
            let groupStarts = visible.filter { index in
                index == visible.lowerBound || samples[index - 1].axis != samples[index].axis
            }
            marks = groupStarts.count <= 6 ? groupStarts : (0...4).map {
                visible.lowerBound + $0 * (visible.count - 1) / 4
            }
        }
        return AxisMarks(values: marks.map(Double.init)) { value in
            AxisGridLine()
            if let index = value.as(Double.self).map(Int.init) {
                let anchor: UnitPoint? = index == visible.lowerBound ? .topLeading
                    : index == visible.upperBound ? .topTrailing : nil
                AxisValueLabel(anchor: anchor) {
                    Text(samples[index].axis)
                }
            }
        }
    }

    private func priceBounds(_ visible: ClosedRange<Int>) -> ClosedRange<Double> {
        var low = reference.map(number) ?? number(samples[visible.lowerBound].price)
        var high = low
        for point in samples[visible] {
            let value = number(point.price)
            low = min(low, value, point.candle.map { min(number($0.open), number($0.low)) } ?? value,
                      point.average.map(number) ?? value)
            high = max(high, value, point.candle.map { max(number($0.open), number($0.high)) } ?? value,
                       point.average.map(number) ?? value)
        }
        let margin = max(0.0001, (high - low) * 0.07)
        return (low - margin)...(high + margin)
    }

    private func macdChart(_ values: [(dif: Double, dea: Double, histogram: Double)], drawn: [Int],
                           current: Int, domain: ClosedRange<Double>) -> some View {
        let latest = values[current]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 13) {
                Text("MACD (12, 26, 9)").foregroundStyle(.secondary)
                Text("DIF " + latest.dif.formatted(.number.precision(.fractionLength(3)))).foregroundStyle(Display.warning)
                Text("DEA " + latest.dea.formatted(.number.precision(.fractionLength(3)))).foregroundStyle(Display.primary)
                Text("柱 " + latest.histogram.formatted(.number.precision(.fractionLength(3))))
                    .foregroundStyle(latest.histogram < 0 ? Display.down : Display.up)
            }
            .font(.caption.monospacedDigit())
            Chart {
                ForEach(drawn, id: \.self) { index in
                    let point = values[index]
                    let x = PlottableValue.value("位置", Double(index))
                    RectangleMark(xStart: .value("左边缘", Double(index) - 0.4),
                                  xEnd: .value("右边缘", Double(index) + 0.4),
                                  yStart: .value("零线", min(0, point.histogram)),
                                  yEnd: .value("MACD", max(0, point.histogram)))
                        .foregroundStyle((point.histogram < 0 ? Display.down : Display.up).opacity(0.65))
                    LineMark(x: x, y: .value("DIF", point.dif), series: .value("线", "DIF"))
                        .foregroundStyle(Display.warning)
                    LineMark(x: x, y: .value("DEA", point.dea), series: .value("线", "DEA"))
                        .foregroundStyle(Display.primary)
                }
                RuleMark(y: .value("零线", 0)).foregroundStyle(Color.secondary.opacity(0.45))
            }
            .chartXScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .frame(height: 80)
            .accessibilityLabel("MACD 指标")
        }
    }

    private func number(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
