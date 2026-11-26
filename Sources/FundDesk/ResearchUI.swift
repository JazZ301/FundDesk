import Charts
import Foundation
import FundCore
import SwiftUI

struct FeedSnapshot<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value
    let fetched: Date
}

actor ResearchArchive {
    let directory: URL

    init(directory: URL) { self.directory = directory.appendingPathComponent("research-v1", isDirectory: true) }

    func load<Value: Codable & Sendable>(_ type: Value.Type, key: String) -> FeedSnapshot<Value>? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? JSONDecoder().decode(FeedSnapshot<Value>.self, from: data)
    }

    func save<Value: Codable & Sendable>(_ value: FeedSnapshot<Value>, key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: file(key), options: .atomic)
        } catch {
            // The latest network data remains available in the view.
        }
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(key + ".json")
    }
}

struct ResearchServices: Sendable {
    let providers = MarketProviders()
    let archive: ResearchArchive
}

struct FeedLoadingPreference: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue() || value
    }
}

struct FeedPane<Value: Codable & Sendable, Content: View>: View {
    let archive: ResearchArchive
    let key: String
    let maxAge: TimeInterval
    var autoRefresh: Bool = false
    var title = ""
    var refreshRequest = 0
    var refreshDisabled = false
    var onManualRefresh: (() -> Void)? = nil
    var mergeCached: ((Value, Value) -> Value)? = nil
    var keepCached: ((Value, Value) -> Bool)? = nil
    var shouldRefresh: ((Value) -> Bool)? = nil
    let query: @Sendable () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @ViewState private var snapshot: FeedSnapshot<Value>?
    private enum Status { case ready, failed, retainedCache }

    @ViewState private var status = Status.ready
    @ViewState private var loading = false
    @ViewState private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !title.isEmpty { Text(title).font(.headline) }
                Spacer()
                if let snapshot {
                    Text(statusText + Display.chinaDateTime(snapshot.fetched))
                        .font(.caption)
                        .foregroundStyle(status == .ready ? Color.secondary : Display.warning)
                }
                if loading {
                    ProgressView().controlSize(.mini)
                }
                Button(status == .ready ? "刷新" : "重试", systemImage: "arrow.clockwise") {
                    requestRefresh()
                    onManualRefresh?()
                }
                .controlSize(.small)
                .disabled(loading || refreshDisabled)
                .accessibilityLabel(title.isEmpty ? "刷新此页数据" : "刷新" + title)
            }
            if let snapshot {
                content(snapshot.value)
            } else if status == .failed {
                Text("刷新失败，暂无可显示数据。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 13)
            } else {
                Text("正在取得数据…").font(.callout).foregroundStyle(.secondary).padding(.vertical, 13)
            }
        }
        .preference(key: FeedLoadingPreference.self, value: loading)
        .onChange(of: refreshRequest) { _ in requestRefresh() }
        .task(id: retry) {
            if snapshot == nil {
                let cached = await archive.load(Value.self, key: key)
                guard !Task.isCancelled else { return }
                snapshot = cached
            }
            let needsRefresh = snapshot.map {
                Date.now.timeIntervalSince($0.fetched) >= maxAge || shouldRefresh?($0.value) == true
            } ?? true
            if retry != 0 || needsRefresh { await update() }
            while autoRefresh && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(maxAge))
                if !Task.isCancelled { await update() }
            }
        }
    }

    private var statusText: String {
        switch status {
        case .ready: return "获取于 "
        case .failed: return "刷新失败 · 缓存于 "
        case .retainedCache: return "新数据不完整 · 缓存于 "
        }
    }

    private func requestRefresh() {
        guard !loading else { return }
        retry += 1
    }

    @MainActor private func update() async {
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await query()
            try Task.checkCancellation()
            if let snapshot, keepCached?(snapshot.value, value) == true {
                status = .retainedCache
                return
            }
            let merged = snapshot.flatMap { mergeCached?($0.value, value) } ?? value
            let fresh = FeedSnapshot(value: merged, fetched: .now)
            snapshot = fresh
            status = .ready
            await archive.save(fresh, key: key)
        } catch {
            if !Task.isCancelled { status = .failed }
        }
    }

}

extension View {
    func researchCard() -> some View {
        padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Display.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Display.stroke).allowsHitTesting(false) }
    }
}

extension Display {
    static func chinaDateTime(_ date: Date) -> String {
        MarketClock.day(date) + " " + dayTime(date)
    }

    static func billions(_ value: Decimal, signed: Bool = false) -> String {
        let billions = value / 100_000_000
        return (signed ? signedNumber(billions) : number(billions, digits: 2)) + " 亿"
    }

    static func unsigPercent(_ value: Decimal) -> String {
        number(value, digits: 2) + "%"
    }
}

struct ResearchChart: View {
    struct SessionAxis {
        let session: IndexTradingSession
        let open: Date

        init?(session: IndexTradingSession, day: String) {
            guard let openingMark = session.axisMarks.first,
                  let open = session.timestamp(day: day, time: openingMark.title) else { return nil }
            self.session = session
            self.open = open
        }

        var ticks: [Date] { session.axisMarks.map { plotTime(minute: $0.position) } }
        var close: Date { plotTime(minute: session.totalMinutes) }

        // Chart positions follow trading minutes. Readouts retain the original quote time.
        func position(for time: Date) -> Date? {
            session.position(for: time).map { plotTime(minute: $0) }
        }

        func label(at position: Date) -> String? {
            session.axisMarks.first { plotTime(minute: $0.position) == position }?.title
        }

        private func plotTime(minute: Int) -> Date {
            open.addingTimeInterval(Double(minute) * 60)
        }
    }

    enum Unit { case number, percent, billions }
    let points: [PlotPoint]
    let unit: Unit
    var intraday = false
    var sessionAxis: SessionAxis?
    var height: CGFloat = 175
    @ViewState private var selected: PlotPoint?

    var body: some View {
        let visible = sessionAxis.map { axis in points.filter { axis.position(for: $0.time) != nil } } ?? points
        if !visible.isEmpty && (visible.count > 1 || sessionAxis != nil) {
            let step = max(1, (visible.count + 799) / 800)
            let drawn = Array(stride(from: 0, to: visible.count - 1, by: step).map { visible[$0] }) + visible.suffix(1)
            VStack(alignment: .leading, spacing: 2) {
                if let readout = selected ?? visible.last {
                    let formatted = label(scaled(readout.value))
                    Text((intraday ? Display.dayTime(readout.time) : MarketClock.day(readout.time))
                         + "   " + formatted)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("走势读数 " + Display.chinaDateTime(readout.time) + " " + formatted)
                }
                Chart {
                    if let point = drawn.first, drawn.count == 1 {
                        PointMark(x: .value("时间", position(of: point)), y: .value("数值", number(point.value)))
                            .foregroundStyle(Display.primary)
                    } else {
                        ForEach(drawn) { point in
                            LineMark(x: .value("时间", position(of: point)), y: .value("数值", number(point.value)))
                                .foregroundStyle(Display.primary)
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("时间", position(of: selected))).foregroundStyle(.secondary.opacity(0.35))
                        PointMark(x: .value("时间", position(of: selected)), y: .value("数值", number(selected.value)))
                            .foregroundStyle(Display.primary)
                    }
                }
                .chartXScale(domain: .automatic(dataType: Date.self) { domain in
                    if let sessionAxis { domain = [sessionAxis.open, sessionAxis.close] }
                })
                .chartYScale(domain: bounds(for: visible))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { tick in
                        AxisGridLine()
                        AxisValueLabel {
                            if let value = tick.as(Double.self) { Text(label(Decimal(value))) }
                        }
                    }
                }
                .chartXAxis {
                    if let sessionAxis {
                        AxisMarks(values: sessionAxis.ticks) { tick in
                            AxisGridLine()
                            if let value = tick.as(Date.self), let label = sessionAxis.label(at: value) {
                                let anchor: UnitPoint = value == sessionAxis.open ? .topLeading
                                    : value == sessionAxis.close ? .topTrailing : .top
                                AxisValueLabel(anchor: anchor, collisionResolution: .disabled) {
                                    Text(label)
                                }
                            }
                        }
                    } else {
                        AxisMarks(values: .automatic(desiredCount: 5)) { tick in
                            AxisGridLine()
                            AxisValueLabel {
                                if let value = tick.as(Date.self) {
                                    Text(intraday ? Display.dayTime(value) : String(MarketClock.day(value).suffix(5)))
                                }
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { hover in
                                switch hover {
                                case .active(let point):
                                    let plot = geometry[proxy.plotAreaFrame]
                                    guard plot.contains(point),
                                          let time: Date = proxy.value(atX: point.x - plot.minX) else {
                                        selected = nil
                                        return
                                    }
                                    if sessionAxis != nil, let first = visible.first, let last = visible.last,
                                       let start = proxy.position(forX: position(of: first)),
                                       let end = proxy.position(forX: position(of: last)) {
                                        let x = point.x - plot.minX
                                        let tolerance: CGFloat = visible.count == 1 ? 4 : 0
                                        guard (start - tolerance...end + tolerance).contains(x) else {
                                            selected = nil
                                            return
                                        }
                                    }
                                    selected = visible.min {
                                        abs(position(of: $0).timeIntervalSince(time))
                                            < abs(position(of: $1).timeIntervalSince(time))
                                    }
                                case .ended: selected = nil
                                }
                            }
                    }
                }
                .frame(height: height)
            }
        } else if let point = visible.first {
            Text(Display.chinaDateTime(point.time) + "  " + label(scaled(point.value)))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text("该区间暂无可绘制的记录。").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func position(of point: PlotPoint) -> Date {
        sessionAxis?.position(for: point.time) ?? point.time
    }

    private func bounds(for points: [PlotPoint]) -> ClosedRange<Double> {
        let values = points.map { number($0.value) }
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let padding = max((high - low) * 0.12, 0.0001)
        return (low - padding)...(high + padding)
    }

    private func number(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: scaled(value)).doubleValue
    }

    private func scaled(_ value: Decimal) -> Decimal {
        unit == .billions ? value / 100_000_000 : value
    }

    private func label(_ value: Decimal) -> String {
        switch unit {
        case .number: return Display.number(value, digits: 4)
        case .percent: return Display.percent(value)
        case .billions: return Display.number(value, digits: 2) + " 亿"
        }
    }
}
