import FundCore
import SwiftUI

struct FuturesView: View {
    let research: ResearchServices
    @ViewState private var order = Order.watchlist
    @ViewState private var selection: FuturesInstrument?

    private enum Order: String, CaseIterable {
        case watchlist = "默认顺序"
        case descending = "涨跌幅从高到低"
        case ascending = "涨跌幅从低到高"
    }

    var body: some View {
        let providers = research.providers
        VStack(alignment: .leading, spacing: 9) {
            if selection == nil {
                listHeader
            }
            FeedPane(archive: research.archive, key: "futures-quotes", maxAge: 60,
                     autoRefresh: true, title: selection == nil ? "外盘行情" : "最新报价",
                     shouldRefresh: { quotes in quotes.allSatisfy { $0.open == nil && $0.high == nil && $0.low == nil } }) {
                try await providers.futuresQuotes()
            } content: { quotes in
                if let selection {
                    FuturesDetail(instrument: selection, quote: quotes.first { $0.instrument == selection },
                                  research: research, goBack: { self.selection = nil })
                        .id(selection)
                } else {
                    quoteTable(quotes)
                }
            }
            .researchCard()
        }
    }

    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("期货").font(.system(size: 21, weight: .semibold))
            Text("新浪财经 · 报价可能延迟 · 北京时间")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("排序", selection: $order) {
                ForEach(Order.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .frame(width: 195)
        }
    }

    private func quoteTable(_ quotes: [FuturesQuote]) -> some View {
        let byInstrument = Dictionary(grouping: quotes, by: \.instrument)
        return VStack(alignment: .leading, spacing: 0) {
            columns("品种", "分时走势", "最新价", "涨跌额", "涨跌幅", "报价时间")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Display.panelRaised, in: RoundedRectangle(cornerRadius: 5))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ordered(byInstrument)) { instrument in
                        let quote = byInstrument[instrument]?.first
                        Button {
                            selection = instrument
                        } label: {
                            quoteRow(instrument, quote: quote)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看" + instrument.title + "详情")
                        .accessibilityValue(quote.map {
                            Display.number($0.price, digits: 2) + "，" + Display.percent($0.rate)
                        } ?? "暂无报价")
                        Divider()
                    }
                }
            }
            if byInstrument.count < FuturesInstrument.allCases.count {
                Text("部分报价暂不可用").font(.caption).foregroundStyle(Display.warning)
                    .padding(.top, 6)
            }
        }
    }

    private func ordered(_ quotes: [FuturesInstrument: [FuturesQuote]]) -> [FuturesInstrument] {
        let instruments = FuturesInstrument.allCases
        guard order != .watchlist else { return instruments }
        return instruments.enumerated().sorted { lhs, rhs in
            let left = quotes[lhs.element]?.first?.rate
            let right = quotes[rhs.element]?.first?.rate
            switch (left, right) {
            case let (a?, b?) where a != b: return order == .descending ? a > b : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func quoteRow(_ instrument: FuturesInstrument, quote: FuturesQuote?) -> some View {
        return columns(
            VStack(alignment: .leading, spacing: 3) {
                Text(instrument.title).font(.callout.weight(.semibold))
                Text(instrument.rawValue + " · " + instrument.quoteKind)
                    .font(.caption2).foregroundStyle(.secondary)
            },
            FuturesSparkline(instrument: instrument, research: research),
            Text(Display.number(quote?.price, digits: 2)).fontWeight(.semibold),
            Text(Display.signedNumber(quote?.change)).foregroundStyle(Display.changeColor(quote?.change)),
            Text(Display.percent(quote?.rate)).fontWeight(.semibold).foregroundStyle(Display.changeColor(quote?.rate)),
            Text(quote.map { Display.chinaDateTime($0.time) } ?? "—").foregroundStyle(.secondary)
        )
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 9)
        .frame(height: 42)
    }

    private func columns<A: View, B: View, C: View, D: View, E: View, F: View>(
        _ instrument: A, _ trend: B, _ price: C, _ change: D, _ rate: E, _ time: F, showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 13) {
            instrument.frame(width: 166, alignment: .leading)
            trend.frame(maxWidth: .infinity, alignment: .leading)
            price.frame(width: 86, alignment: .trailing)
            change.frame(width: 77, alignment: .trailing)
            rate.frame(width: 76, alignment: .trailing)
            time.frame(width: 118, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .opacity(showsChevron ? 1 : 0)
                .accessibilityHidden(true)
        }
    }

    private func columns(_ instrument: String, _ trend: String, _ price: String,
                         _ change: String, _ rate: String, _ time: String) -> some View {
        columns(Text(instrument), Text(trend), Text(price), Text(change), Text(rate), Text(time), showsChevron: false)
    }
}

private struct FuturesSparkline: View {
    let instrument: FuturesInstrument
    let research: ResearchServices
    @ViewState private var snapshot: FeedSnapshot<FuturesIntraday>?
    @ViewState private var failed = false

    var body: some View {
        Group {
            if let series = snapshot?.value, let latest = series.points.last {
                HStack(spacing: 5) {
                    plot(series, latest: latest)
                    if failed {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption2).foregroundStyle(Display.warning)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary(latest))
                .help(summary(latest))
            } else {
                Text(failed ? "分时暂不可用" : "正在获取分时…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(height: 29)
        .task {
            let key = "futures-intraday-" + instrument.rawValue
            snapshot = await research.archive.load(FuturesIntraday.self, key: key)
            let interval: TimeInterval = 120
            let delay = snapshot.map { max(0, interval - Date.now.timeIntervalSince($0.fetched)) } ?? 0
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            while !Task.isCancelled {
                do {
                    let series = try await research.providers.futuresIntraday(instrument)
                    try Task.checkCancellation()
                    let fresh = FeedSnapshot(value: series, fetched: .now)
                    snapshot = fresh
                    failed = false
                    await research.archive.save(fresh, key: key)
                } catch {
                    if !Task.isCancelled { failed = true }
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func summary(_ latest: PlotPoint) -> String {
        (failed ? "缓存分时" : "分时") + " · " + Display.chinaDateTime(latest.time)
            + " · " + Display.number(latest.value, digits: 2)
    }

    private func plot(_ series: FuturesIntraday, latest: PlotPoint) -> some View {
        let window = instrument.session.window(containing: latest.time)
        let allPoints = series.points
        let points = window.map { window in
            allPoints.filter { $0.time >= window.start && $0.time <= window.end }
        } ?? allPoints
        let reference = series.reference
        let change = reference.map { latest.value - $0 }
        return Canvas { context, size in
            guard let first = points.first else { return }
            let values = points.map { NSDecimalNumber(decimal: $0.value).doubleValue }
            guard let low = values.min(), let high = values.max() else { return }
            let baseline = reference.map { NSDecimalNumber(decimal: $0).doubleValue }
            let floor = min(low, baseline ?? low)
            let ceiling = max(high, baseline ?? high)
            let padding = max((ceiling - floor) * 0.05, 0.0001)
            let spanStart = window?.start ?? first.time
            let spanEnd = window?.end ?? latest.time
            let duration = max(60, spanEnd.timeIntervalSince(spanStart))
            func y(_ value: Double) -> CGFloat {
                size.height * (ceiling + padding - value) / (ceiling - floor + 2 * padding)
            }
            func x(_ time: Date) -> CGFloat {
                let progress = min(max(time.timeIntervalSince(spanStart) / duration, 0), 1)
                return 1 + (size.width - 2) * progress
            }

            if let baseline {
                let line = Path { path in
                    path.move(to: CGPoint(x: 1, y: y(baseline)))
                    path.addLine(to: CGPoint(x: size.width - 1, y: y(baseline)))
                }
                context.stroke(line, with: .color(.secondary.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            let color = change == nil || change == 0 ? Display.primary : Display.changeColor(change, digits: nil)
            if points.count == 1 {
                let marker = CGRect(x: x(points[0].time) - 2, y: y(values[0]) - 2, width: 4, height: 4)
                context.fill(Path(ellipseIn: marker), with: .color(color))
                return
            }
            let line = Path { path in
                for (index, point) in points.enumerated() {
                    let position = CGPoint(x: x(point.time), y: y(values[index]))
                    if index == 0 || point.time.timeIntervalSince(points[index - 1].time) > 600 {
                        path.move(to: position)
                    } else {
                        path.addLine(to: position)
                    }
                }
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}
