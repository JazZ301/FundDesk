import FundCore
import SwiftUI

@MainActor
final class MarketQuotes: ObservableObject {
    @Published private(set) var snapshot: FeedSnapshot<[IndexQuote]>?
    @Published private(set) var loading = false
    @Published private(set) var failed = false

    private static let cacheKey = "market-index"
    private let research: ResearchServices

    var shanghaiQuote: IndexQuote? {
        snapshot?.value.first { $0.index == .shanghaiComposite }
    }

    init(research: ResearchServices) {
        self.research = research
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }

    func refresh() async {
        guard !loading, !Task.isCancelled else { return }
        loading = true
        defer { loading = false }

        if snapshot == nil {
            snapshot = await research.archive.load([IndexQuote].self, key: Self.cacheKey)
        }
        do {
            try Task.checkCancellation()
            let fresh = FeedSnapshot(value: try await research.providers.indices(), fetched: .now)
            try Task.checkCancellation()
            snapshot = fresh
            failed = false
            await research.archive.save(fresh, key: Self.cacheKey)
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

struct MarketQuoteStrip: View {
    @ObservedObject var quotes: MarketQuotes
    var selectedIndex: MarketIndex?
    let select: (MarketIndex) -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top),
              count: MarketIndex.displayOrder.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Display.primary)
                Text("市场指数").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(status)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(quotes.failed ? Display.warning : Color.secondary)
                ProgressView()
                    .controlSize(.mini)
                    .opacity(quotes.loading ? 1 : 0)
                    .frame(width: 14)
                Button {
                    Task { await quotes.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(quotes.loading)
                .accessibilityLabel("刷新市场指数")
                .help(quotes.failed ? "重试刷新市场指数" : "刷新市场指数")
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(MarketIndex.displayOrder) { index in
                    IndexQuoteCard(
                        index: index,
                        quote: quotes.snapshot?.value.first { $0.index == index },
                        selected: selectedIndex == index,
                        select: select
                    )
                }
            }
        }
        .padding(9)
        .fixedSize(horizontal: false, vertical: true)
        .background(Display.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Display.stroke)
                .allowsHitTesting(false)
        }
    }

    private var status: String {
        if let snapshot = quotes.snapshot {
            let fetched = Display.chinaDateTime(snapshot.fetched)
            if quotes.failed { return "刷新失败 · 缓存于 " + fetched }
            if snapshot.value.count < MarketIndex.displayOrder.count { return "部分报价缺失 · 获取于 " + fetched }
            return "获取于 " + fetched
        }
        return quotes.failed ? "指数刷新失败 · 暂无缓存" : "正在获取行情…"
    }

}

private struct IndexQuoteCard: View {
    let index: MarketIndex
    let quote: IndexQuote?
    let selected: Bool
    let select: (MarketIndex) -> Void

    @ViewState private var hovering = false

    private var timestamp: String { quote?.timestamp ?? "" }
    private var shortTime: String {
        String(timestamp.dropFirst(5).prefix(11)) + (index.isUS ? " 美东" : "")
    }
    private var trendSymbol: String? {
        guard let rate = quote?.rate else { return nil }
        if rate > 0 { return "arrow.up.right" }
        if rate < 0 { return "arrow.down.right" }
        return "minus"
    }

    var body: some View {
        Button {
            select(index)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text(index.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let trendSymbol {
                        Image(systemName: trendSymbol)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Display.changeColor(quote?.rate))
                    }
                }
                Text(Display.number(quote?.value, digits: 2))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Display.changeColor(quote?.rate))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Display.percent(quote?.rate))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Display.changeColor(quote?.rate))
                    Spacer(minLength: 1)
                    Text(Display.signedNumber(quote?.change))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(Display.changeColor(quote?.change))
                }
                Text(timestamp.isEmpty ? "暂无报价时间" : shortTime)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(cardBorder, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(timestamp.isEmpty ? "查看" + index.title + "分时"
              : timestamp + " · " + index.tradingSession.timeZoneLabel)
        .accessibilityHint("查看分时走势")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var cardBackground: Color {
        if selected { return Display.selected }
        return hovering ? Display.selected.opacity(0.55) : Display.panelRaised
    }

    private var cardBorder: Color {
        selected ? Display.primary.opacity(0.7) : Display.stroke.opacity(0.8)
    }
}
