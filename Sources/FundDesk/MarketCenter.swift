import AppKit
import Charts
import FundCore
import SwiftUI

struct MarketCenter: View {
    let research: ResearchServices
    @ObservedObject var quotes: MarketQuotes
    @Environment(\.dismiss) private var dismiss
    @ViewState private var page = MarketPage.overview
    @ViewState private var period = SectorPeriod.today
    @ViewState private var flow = FlowKind.main
    @ViewState private var selectedIndex: MarketIndex?
    @ViewState private var order = SectorOrder.inflow
    @ViewState private var refreshRequest = 0
    @ViewState private var feedsLoading = false

    init(research: ResearchServices, quotes: MarketQuotes, selectedIndex: MarketIndex?) {
        self.research = research
        self.quotes = quotes
        _selectedIndex = ViewState(initialValue: selectedIndex)
    }

    private enum MarketPage: String, CaseIterable {
        case overview = "大盘资金"
        case industry = "行业板块"
        case style = "风格板块"
        case concept = "概念板块"
        case region = "地域板块"

        var category: SectorCategory? { SectorCategory(rawValue: rawValue) }
    }

    private enum SectorOrder: String, CaseIterable {
        case inflow = "净流入优先"
        case outflow = "净流出优先"
    }

    private var marketSize: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1_440, height: 900)
        return CGSize(
            width: min(1_320, max(1_080, available.width * 0.88)),
            height: min(900, max(700, available.height * 0.86))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("行情中心").font(.title2.weight(.semibold))
                Spacer()
                Button("刷新本页", systemImage: "arrow.clockwise") {
                    refreshRequest += 1
                    Task { await quotes.refresh() }
                }
                .disabled(feedsLoading || quotes.loading)
                Button("返回基金列表") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            MarketQuoteStrip(quotes: quotes, selectedIndex: selectedIndex) { index in
                selectedIndex = selectedIndex == index ? nil : index
            }

            ThemedSegmentedControl(
                options: MarketPage.allCases, selection: $page, title: "行情分类"
            ) { $0.rawValue }

            ScrollView {
                if let index = selectedIndex {
                    indexDetail(index)
                } else if let category = page.category {
                    sectorPage(category)
                } else {
                    overview
                }
            }
            .id(selectedIndex?.rawValue ?? page.rawValue)
        }
        .onPreferenceChange(FeedLoadingPreference.self) { feedsLoading = $0 }
        .onChange(of: page) { _ in selectedIndex = nil }
        .padding(16)
        .frame(width: marketSize.width, height: marketSize.height)
        .background(Display.canvasWash)
        .tint(Display.primary)
    }

    private func indexDetail(_ index: MarketIndex) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("返回行情分类", systemImage: "chevron.left") { selectedIndex = nil }
            IndexTrendPane(research: research, index: index, height: 300,
                           title: index.title + "分时", refreshRequest: refreshRequest)
                .researchCard()
        }
    }

    private var overview: some View {
        let providers = research.providers
        return VStack(spacing: 9) {
            FeedPane(archive: research.archive, key: "market-breadth", maxAge: 60, autoRefresh: true,
                     title: "沪深两市", refreshRequest: refreshRequest,
                     mergeCached: { cached, fresh in fresh.preservingCounts(from: cached) },
                     query: { try await providers.marketBreadth() }) { breadth in
                HStack(spacing: 18) {
                    MarketStat("成交额", Display.billions(breadth.turnover) + "元", .primary)
                    MarketStat("上涨", breadth.advancing?.formatted() ?? "—", Display.changeColor(1))
                    MarketStat("平盘", breadth.flat?.formatted() ?? "—", .secondary)
                    MarketStat("下跌", breadth.declining?.formatted() ?? "—", Display.changeColor(-1))
                }
                HStack(spacing: 14) {
                    let source = breadth.source.replacingOccurrences(of: " · 涨跌家数待恢复", with: "")
                    Text("成交额 · " + (breadth.asOf.map(Display.chinaDateTime) ?? "行情时间未提供") + " · " + source)
                        .foregroundStyle(.secondary)
                    if breadth.hasCounts {
                        Text("涨跌家数 · " + (breadth.countsAsOf.map(Display.chinaDateTime) ?? "行情时间未提供")
                             + (breadth.cachedCountsAsOf == nil ? "" : " · 同交易日缓存"))
                            .foregroundStyle(breadth.cachedCountsAsOf == nil ? Color.secondary : Display.warning)
                    } else {
                        Text("部分缺失 · 涨跌家数暂缺").foregroundStyle(Display.warning)
                    }
                }
                .font(.caption)
            }
            .researchCard()
            FeedPane(archive: research.archive, key: "market-flows", maxAge: 75, autoRefresh: true, title: "两市资金流向",
                     refreshRequest: refreshRequest, keepCached: { cached, fetched in
                         cached.intraday && !fetched.intraday
                             && (cached.points.last?.time ?? .distantPast) > (fetched.points.last?.time ?? .distantPast)
                     },
                     query: { try await providers.marketFlows() }) { series in
                if let latest = series.points.last {
                    HStack(spacing: 8) {
                        ForEach(FlowKind.allCases, id: \.self) { kind in
                            Button {
                                flow = kind
                            } label: {
                                MarketStat(kind.rawValue, Display.billions(latest.amount(kind), signed: true),
                                           Display.changeColor(latest.amount(kind) / 100_000_000))
                                    .padding(6)
                                    .background(flow == kind ? Display.selected : Display.panelRaised,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(kind.rawValue + "净流入")
                        }
                    }
                    let stamp = series.intraday ? Display.chinaDateTime(latest.time) + " · 分时"
                        : MarketClock.day(latest.time) + " · 日线（分时暂不可用）"
                    Text("行情 " + stamp + " · 东方财富 · " + flow.rawValue + "净流入")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ResearchChart(points: series.points.map { PlotPoint(time: $0.time, value: $0.amount(flow)) },
                              unit: .billions, intraday: series.intraday, height: 175)
                    .id(flow.rawValue + String(series.intraday))
            }
            .researchCard()
        }
    }

    private func sectorPage(_ category: SectorCategory) -> some View {
        let providers = research.providers
        let currentPeriod = period
        let key = "market-sector-" + category.rawValue + "-" + currentPeriod.rawValue
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ThemedSegmentedControl(
                    options: SectorPeriod.allCases, selection: $period, title: "排行周期"
                ) { $0.rawValue }
                .frame(width: 250)
                Spacer()
                Picker("排列", selection: $order) {
                    ForEach(SectorOrder.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
                }
                .labelsHidden()
                .frame(width: 115)
            }
            FeedPane(archive: research.archive, key: key, maxAge: 90, autoRefresh: true, title: category.rawValue + "资金排行",
                     refreshRequest: refreshRequest, query: { try await providers.sectorFlows(category, period: currentPeriod) }) { rows in
                sectorRows(rows)
            }
            .id(key)
            .researchCard()
        }
    }

    private func sectorRows(_ rows: [SectorFlow]) -> some View {
        let ordered = order == .inflow ? rows : Array(rows.reversed())
        let maxAmount = max(abs(rows.first?.amount ?? 0), abs(rows.last?.amount ?? 0))
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(rows.count) 个板块 · 东方财富 · 主力净流入（亿元） · 行情时间未提供")
                .font(.caption).foregroundStyle(.secondary)
            LazyVStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { rank, item in
                    HStack(spacing: 8) {
                        Text((rank + 1).formatted()).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                        Text(item.name).lineLimit(1).frame(width: 130, alignment: .leading)
                        GeometryReader { geometry in
                            let ratio = maxAmount == 0 ? 0 : NSDecimalNumber(decimal: abs(item.amount) / maxAmount).doubleValue
                            Capsule().fill(Display.changeColor(item.amount, digits: nil).opacity(0.75))
                                .frame(width: max(0, geometry.size.width * min(1, ratio)), height: 6)
                                .frame(maxHeight: .infinity)
                        }
                        .accessibilityHidden(true)
                        Text(Display.billions(item.amount, signed: true)).foregroundStyle(Display.changeColor(item.amount / 100_000_000))
                            .frame(width: 105, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                    .frame(height: 25)
                    Divider()
                }
            }
        }
    }
}

struct IndexTrendPane: View {
    let research: ResearchServices
    let index: MarketIndex
    let height: CGFloat
    let title: String
    var refreshRequest = 0
    var refreshDisabled = false
    var onManualRefresh: (() -> Void)? = nil

    var body: some View {
        FeedPane(archive: research.archive, key: "market-trend-v3-" + index.rawValue, maxAge: 90, autoRefresh: true,
                 title: title, refreshRequest: refreshRequest, refreshDisabled: refreshDisabled,
                 onManualRefresh: onManualRefresh, query: { try await research.providers.indexTrend(index) }) { trend in
            if let latest = trend.points.last {
                Text(index.tradingSession.dateTimeLabel(for: latest.time)
                     + " · " + index.tradingSession.timeZoneLabel
                     + " · " + trend.source + " · 指数点位")
                    .font(.caption).foregroundStyle(.secondary)
            }
            IndexIntradayChart(index: index, points: trend.points,
                               previousClose: trend.previousClose,
                               volumes: trend.volumes ?? [], height: height)
        }
    }
}

private struct IndexIntradayChart: View {
    let index: MarketIndex
    let points: [PlotPoint]
    let previousClose: Decimal?
    let volumes: [PlotPoint]
    let height: CGFloat
    @ViewState private var selected: IndexChartPoint?

    private struct IndexChartPoint: Identifiable, Equatable {
        var id: Int { position }
        let position: Int
        let time: Date
        let value: Decimal
    }

    private struct PriceScale {
        let baseline: Double
        let padding: Double

        var domain: ClosedRange<Double> { (baseline - padding)...(baseline + padding) }
        var ticks: [Double] {
            (0...6).map { baseline - padding + padding * 2 * Double($0) / 6 }
        }
    }

    private struct VolumeBar: Identifiable, Equatable {
        var id: Int { position }
        let position: Int
        let time: Date
        let value: Decimal
        let direction: Int
    }

    private var session: IndexTradingSession { index.tradingSession }

    private var plotted: [IndexChartPoint] {
        var byPosition: [Int: IndexChartPoint] = [:]
        for point in points {
            guard let position = session.position(for: point.time) else { continue }
            byPosition[position] = IndexChartPoint(position: position, time: point.time, value: point.value)
        }
        return byPosition.values.sorted { $0.position < $1.position }
    }

    private var volumeBars: [VolumeBar] {
        let prices = plotted
        var byPosition: [Int: PlotPoint] = [:]
        for point in volumes {
            guard let position = session.position(for: point.time) else { continue }
            byPosition[position] = point
        }
        return byPosition.map { position, point in
            let current = prices.last { $0.position <= position }?.value
            let previous = prices.last { $0.position < position }?.value
            let direction: Int
            if let current, let previous, current != previous {
                direction = current > previous ? 1 : -1
            } else {
                direction = 0
            }
            return VolumeBar(position: position, time: point.time, value: point.value, direction: direction)
        }
        .sorted { $0.position < $1.position }
    }

    var body: some View {
        let values = plotted
        let xPadding = max(6.0, Double(session.totalMinutes) * 0.04)
        let scale = priceScale(values)
        if values.count > 1 {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(Display.primary).frame(width: 7, height: 7)
                    if let readout = selected ?? values.last {
                        Text(session.timeLabel(for: readout.time)
                             + "  " + Display.number(readout.value, digits: 2))
                            .font(.caption.monospacedDigit())
                        Text(percentText(readout.value, scale: scale))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(priceColor(readout.value, scale: scale))
                    }
                    Spacer()
                    Text((previousClose == nil ? "基准 " : "昨收 ")
                         + Display.number(Decimal(scale.baseline), digits: 2)
                         + " · 指数点位 / 涨跌幅 · " + session.timeZoneLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Chart {
                    RuleMark(y: .value("昨收", scale.baseline))
                        .foregroundStyle(Display.primary.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                    ForEach(values) { point in
                        LineMark(
                            x: .value("交易分钟", Double(point.position)),
                            y: .value("点位", number(point.value))
                        )
                        .foregroundStyle(Display.primary)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    }
                    if let selected {
                        RuleMark(x: .value("交易分钟", Double(selected.position)))
                            .foregroundStyle(Display.primary.opacity(0.30))
                        PointMark(
                            x: .value("交易分钟", Double(selected.position)),
                            y: .value("点位", number(selected.value))
                        )
                        .foregroundStyle(Display.primary)
                        .symbolSize(34)
                    }
                }
                .chartXScale(domain: -xPadding...(Double(session.totalMinutes) + xPadding))
                .chartYScale(domain: scale.domain)
                .chartXAxis { tradingAxis() }
                .chartYAxis {
                    AxisMarks(position: .leading, values: scale.ticks) { tick in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisTick()
                        AxisValueLabel {
                            if let value = tick.as(Double.self) {
                                Text(Display.number(Decimal(value), digits: 2))
                                    .monospacedDigit()
                                    .foregroundStyle(axisColor(value, scale: scale))
                            }
                        }
                    }
                    AxisMarks(position: .trailing, values: scale.ticks) { tick in
                        AxisValueLabel {
                            if let value = tick.as(Double.self) {
                                Text(percentText(Decimal(value), scale: scale))
                                    .monospacedDigit()
                                    .foregroundStyle(priceColor(Decimal(value), scale: scale))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { hover in
                                switch hover {
                                case .active(let location):
                                    let plot = geometry[proxy.plotAreaFrame]
                                    guard plot.contains(location),
                                          let position: Double = proxy.value(atX: location.x - plot.minX) else {
                                        selected = nil
                                        return
                                    }
                                    selected = values.min { abs(Double($0.position) - position)
                                        < abs(Double($1.position) - position) }
                                case .ended:
                                    selected = nil
                                }
                            }
                    }
                }
                .frame(height: height)
                if !volumeBars.isEmpty {
                    HStack {
                        Text("成交量（万）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let selected,
                           let bar = volumeBars.min(by: {
                               abs($0.position - selected.position) < abs($1.position - selected.position)
                           }) {
                            Text(Display.number(volumeValue(bar.value), digits: 2) + " 万")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Chart {
                        ForEach(volumeBars) { bar in
                            BarMark(
                                x: .value("交易分钟", Double(bar.position)),
                                y: .value("成交量", number(volumeValue(bar.value)))
                            )
                            .foregroundStyle(volumeColor(bar.direction))
                            .opacity(0.78)
                        }
                        if let selected {
                            RuleMark(x: .value("交易分钟", Double(selected.position)))
                                .foregroundStyle(Display.primary.opacity(0.24))
                        }
                    }
                    .chartXScale(domain: -xPadding...(Double(session.totalMinutes) + xPadding))
                    .chartYScale(domain: 0...volumeUpperBound)
                    .chartXAxis { tradingAxis() }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { tick in
                            AxisValueLabel {
                                if let value = tick.as(Double.self) {
                                    Text(Display.number(Decimal(value), digits: 0))
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    .frame(height: height * 0.35)
                }
            }
        } else {
            Text("该指数当前没有可显示的有效交易时段数据。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func tradingAxis() -> some AxisContent {
        AxisMarks(values: session.axisMarks.map { Double($0.position) }) { tick in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            AxisTick()
            if let position = tick.as(Double.self),
               let mark = session.axisMarks.first(where: { Double($0.position) == position }) {
                let anchor: UnitPoint = mark.position == 0 ? .topLeading
                    : mark.position == session.totalMinutes ? .topTrailing : .top
                AxisValueLabel(anchor: anchor, collisionResolution: .disabled) {
                    Text(mark.title)
                }
            }
        }
    }

    private func priceScale(_ points: [IndexChartPoint]) -> PriceScale {
        let baseline = previousClose.map(number) ?? points.first.map { number($0.value) } ?? 1
        let safeBaseline = max(baseline, 0.01)
        let values = points.map { number($0.value) }
        let maxDistance = values.map { abs($0 - safeBaseline) }.max() ?? 0
        let padding = max(maxDistance * 1.08, safeBaseline * 0.002)
        return PriceScale(baseline: safeBaseline, padding: padding)
    }

    private func priceColor(_ value: Decimal, scale: PriceScale) -> Color {
        Display.changeColor(relativePercent(value, scale: scale))
    }

    private func axisColor(_ value: Double, scale: PriceScale) -> Color {
        Display.changeColor(Decimal(value - scale.baseline))
    }

    private func relativePercent(_ value: Decimal, scale: PriceScale) -> Decimal {
        Decimal((number(value) - scale.baseline) / scale.baseline * 100)
    }

    private func percentText(_ value: Decimal, scale: PriceScale) -> String {
        Display.percent(relativePercent(value, scale: scale))
    }

    private var volumeUpperBound: Double {
        let maximum = volumeBars.map { number(volumeValue($0.value)) }.max() ?? 1
        return max(maximum * 1.08, 1)
    }

    private func volumeValue(_ value: Decimal) -> Decimal {
        value / 10_000
    }

    private func volumeColor(_ direction: Int) -> Color {
        switch direction {
        case 1: return Display.up
        case -1: return Display.down
        default: return .secondary
        }
    }

    private func number(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}

private struct MarketStat: View {
    let title: String
    let value: String
    let color: Color

    init(_ title: String, _ value: String, _ color: Color) {
        self.title = title
        self.value = value
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
