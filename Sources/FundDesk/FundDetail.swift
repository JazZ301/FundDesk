import AppKit
import Charts
import FundCore
import SwiftUI

struct SearchView: View {
    @ObservedObject var model: BoardModel
    let openFund: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @ViewState private var query = ""
    @ViewState private var results: [Fund] = []
    @ViewState private var loading = false
    @ViewState private var failed = false
    @ViewState private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("添加基金").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("搜索基金代码、名称或拼音", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .accessibilityLabel("搜索基金")
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("也可以直接查找这些公开基金").foregroundStyle(.secondary).font(.callout)
                HStack {
                    Button("沪深 300 联接 C") { query = "007339" }
                    Button("南方红利低波联接 A") { query = "008163" }
                }
            } else if loading {
                ProgressView("正在查找…").controlSize(.small)
            } else if failed {
                HStack {
                    Text("暂时无法连接基金目录").foregroundStyle(.secondary)
                    Button("重试") { retry += 1 }
                }
            } else if results.isEmpty {
                Text("没有找到匹配的基金。").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { fund in
                            resultRow(fund)
                            Divider()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 548, height: 392)
        .background(Display.canvasWash)
        .tint(Display.primary)
        .defaultFocus($focused, true)
        .task(id: "\(retry):\(query)") {
            let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
            results = []
            failed = false
            guard !searchTerm.isEmpty else { loading = false; return }
            loading = true
            do {
                try await Task.sleep(for: .milliseconds(240))
                let found = try await model.search(searchTerm)
                try Task.checkCancellation()
                results = found
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                loading = false
            }
        }
    }

    private func resultRow(_ fund: Fund) -> some View {
        let added = model.board.holdings.contains(where: { $0.id == fund.code })
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(fund.name).font(.callout.weight(.medium))
                Text(fund.code + (fund.kind.isEmpty ? "" : "  ·  " + fund.kind))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if added {
                Button("打开详情") { openFund(fund.code) }
                    .accessibilityLabel("打开基金详情 " + fund.code)
            } else {
                Button("添加") { model.add(fund) }
                    .accessibilityLabel("添加 " + fund.code)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct HoldingStockSymbols: PreferenceKey {
    static let defaultValue: Set<String> = []

    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

struct FundDetail: View {
    @ObservedObject var model: BoardModel
    let code: String
    @Environment(\.dismiss) private var dismiss
    @ViewState private var shares = ""
    @ViewState private var cost = ""
    @ViewState private var isEditing = false
    @ViewState private var saved = false
    @ViewState private var tab: FundDetailTab
    @ViewState private var historyRange = HistoryPeriod.year
    @ViewState private var returnsRange = HistoryPeriod.year
    @ViewState private var showTarget = false
    @ViewState private var stockSymbols: Set<String> = []
    @ViewState private var stockQuotes: [String: StockQuote] = [:]
    @ViewState private var stockQuoteFailed = false
    @ViewState private var historyStyle = HistoryStyle.unit
    @ViewState private var showJournal = false
    @FocusState private var focusedPositionField: PositionField?

    init(model: BoardModel, code: String) {
        self.model = model
        self.code = code
        let board = model.board
        let holding = board.holdings.first { $0.id == code }
        let showsObservation = holding?.groupValues.isEmpty == false
        _tab = ViewState(initialValue: board.visibleFundDetailTabs(showsObservation: showsObservation).first ?? .estimate)
    }

    private enum HistoryStyle: String, CaseIterable {
        case unit = "单位净值"
        case accumulated = "累计净值"
    }

    private enum PositionField: Hashable {
        case shares
        case cost
    }

    private var holding: Holding? { model.board.holdings.first { $0.id == code } }
    private var snapshot: Snapshot { model.snapshot(for: code) }
    private var observationGroups: [FundGroup] { holding?.groupValues ?? [] }
    private var showsObservation: Bool { !observationGroups.isEmpty }
    private var visibleTabs: [FundDetailTab] {
        model.board.visibleFundDetailTabs(showsObservation: showsObservation)
    }
    private var detailSize: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1_440, height: 900)
        return CGSize(
            width: min(1_320, max(980, available.width * 0.84)),
            height: min(900, max(700, available.height * 0.86))
        )
    }

    var body: some View {
        if let holding {
            VStack(alignment: .leading, spacing: 10) {
                header(holding.fund)
                HStack(alignment: .top, spacing: 9) {
                    confirmed(holding.fund)
                    estimated(holding.fund)
                }
                .fixedSize(horizontal: false, vertical: true)
                FundDetailTabs(tabs: visibleTabs, selection: $tab) { source, target in
                    model.moveFundDetailTab(source, to: target, showsObservation: showsObservation)
                }
                ScrollView {
                    detailContent(holding.fund)
                        .padding(1)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(tab)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                position(holding)
            }
            .padding(17)
            .frame(width: detailSize.width, height: detailSize.height)
            .background(Display.canvasWash)
            .tint(Display.primary)
            .sheet(isPresented: $showJournal) { PositionJournalView(model: model, code: code) }
            .onChange(of: visibleTabs) { tabs in
                if !tabs.contains(tab), let first = tabs.first { tab = first }
            }
            .task(id: holding.fund.kind) {
                if !isEditing { reset(holding) }
            }
        }
    }

    @ViewBuilder private func detailContent(_ fund: Fund) -> some View {
        let research = model.research
        let provider = research.providers
        switch tab {
        case .estimate:
            if fund.isMoney {
                Text("货币基金按披露的万份收益和七日年化查看。")
                    .font(.callout).foregroundStyle(.secondary).researchCard()
            } else {
                FeedPane(archive: research.archive, key: "estimate-" + code, maxAge: 90, autoRefresh: true,
                         title: "估算分时", query: { try await provider.sina(for: fund).series }) { quotes in
                    let all = quotes + (snapshot.estimate.map { [$0] } ?? [])
                    if let day = all.max(by: { $0.timestamp < $1.timestamp })?.marketDay {
                        let byTime = Dictionary(grouping: all.filter { $0.marketDay == day }, by: \.timestamp)
                        let points = byTime.compactMap { stamp, quotes in quotes.last.map { PlotPoint(time: stamp, value: $0.value) } }
                            .sorted { $0.time < $1.time }
                        Text(day + " · 新浪财经 · 估算净值")
                            .font(.caption).foregroundStyle(.secondary)
                        let sessionAxis = fund.isCrossBorder ? nil
                            : ResearchChart.SessionAxis(session: .mainlandChina, day: day)
                        ResearchChart(points: points, unit: .number, intraday: true, sessionAxis: sessionAxis, height: 211)
                            .id(day)
                    } else {
                        Text("数据源未提供该基金的估算分时。").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .researchCard()
            }
        case .history, .returns:
            FeedPane(archive: research.archive, key: "history-" + code, maxAge: 1_800,
                     title: tab == .history ? "净值走势" : "区间累计收益",
                     query: { try await provider.fundHistory(fund) }) { history in
                historyContent(history.mergingRecent(snapshot.history), fund: fund)
            }
            .id(tab)
            .researchCard()
        case .holdings:
            FeedPane(archive: research.archive, key: "disclosure-" + code, maxAge: 43_200,
                     title: "公开披露的持仓", shouldRefresh: { $0.needsStockMarketRefresh },
                     query: { try await provider.fundDisclosure(code: fund.code) }) { report in
                disclosureContent(report)
                if let target = report.targetCode, target != fund.code {
                    Button(showTarget ? "收起目标 ETF 持仓" : "查看目标 ETF 持仓") { showTarget.toggle() }
                    if showTarget {
                        FeedPane(archive: research.archive, key: "disclosure-" + target, maxAge: 43_200,
                                 title: report.targetName ?? target, shouldRefresh: { $0.needsStockMarketRefresh },
                                 query: { try await provider.fundDisclosure(code: target) }) { targetReport in
                            disclosureContent(targetReport)
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .researchCard()
            .onPreferenceChange(HoldingStockSymbols.self) { stockSymbols = $0 }
            .task(id: stockSymbols) { await pollStockQuotes(symbols: stockSymbols, provider: provider) }
        case .profile:
            VStack(spacing: 9) {
                FeedPane(archive: research.archive, key: "profile-" + code, maxAge: 3_600,
                         title: "基金档案", query: { try await provider.fundProfile(code: fund.code) }) { profile in
                    profileContent(profile)
                }
                .researchCard()
                FeedPane(archive: research.archive, key: "managers-" + code, maxAge: 43_200,
                         title: "基金经理", query: { try await provider.fundManagers(code: fund.code) }) { history in
                    managersContent(history)
                }
                .researchCard()
            }
        case .observation:
            observationContent(model.board.observations?[code], fund: fund)
        }
    }

    private func header(_ fund: Fund) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(fund.name).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(fund.code + (fund.kind.isEmpty ? "" : "  ·  " + fund.kind))
                    .font(.callout).foregroundStyle(.secondary)
                if let groups = holding?.groupValues, !groups.isEmpty {
                    Text(groups.map(\.title).joined(separator: "  ·  "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Display.primaryStrong)
                }
            }
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    private func confirmed(_ fund: Fund) -> some View {
        detailCard {
            Text(fund.isMoney ? "每万份收益" : "正式净值").font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(Display.number(snapshot.nav?.value, digits: 4))
                    .font(.title2.monospacedDigit().weight(.semibold))
                Spacer()
                let rate = fund.isMoney ? snapshot.nav?.annualizedRate : snapshot.nav?.rate
                Text(Display.percent(rate)).font(.callout.monospacedDigit())
                    .foregroundStyle(fund.isMoney ? Color.secondary : Display.changeColor(rate))
            }
            if let nav = snapshot.nav {
                Text(nav.day + "  ·  " + nav.source + (fund.isMoney ? "  ·  七日年化" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if model.navFailures.contains(code) {
                    Text("本次刷新失败，正在显示上次记录。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("等待可用正式净值").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func estimated(_ fund: Fund) -> some View {
        let current = snapshot.effectiveEstimate(now: model.now)
        let prior = snapshot.estimate
        let visible = fund.isMoney ? nil : (current ?? prior)
        return detailCard {
            Text(current == nil && visible != nil ? "上次盘中估算" : "盘中估算")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(Display.number(visible?.value, digits: 4))
                    .font(.title2.monospacedDigit().weight(.semibold))
                Spacer()
                Text(Display.percent(visible?.percent)).font(.callout.monospacedDigit())
                    .foregroundStyle(Display.changeColor(visible?.percent))
                    .help(Display.precisePercent(visible?.percent) ?? "")
            }
            if let visible {
                Text(MarketClock.day(visible.timestamp) + " " + Display.dayTime(visible.timestamp) + "  ·  新浪财经")
                    .font(.caption).foregroundStyle(.secondary)
                if model.estimateFailures.contains(code) {
                    Text("本次刷新失败，正在显示上次记录。").font(.caption).foregroundStyle(.secondary)
                }
                if current == nil {
                    Text("此估算未计入当日汇总。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(fund.isMoney ? "此类基金按万份收益展示" :
                     (model.estimateFailures.contains(code) ? "暂时无法连接估算数据源" : "数据源暂未提供估算"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7, content: content)
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Display.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Display.stroke) }
    }

    private func observationContent(_ observation: FundObservation?, fund: Fund) -> some View {
        let showsMACD = observationGroups.contains(.macd)
        let showsRed = observationGroups.contains(.red)
        let localMACD = showsMACD ? observation?.series.flatMap(ObservationAnalysis.macd) : nil
        let metrics = (observation?.metrics ?? []).filter { metric in
            if metric.key == "track" { return true }
            return Self.redMetricKeys.contains(metric.key) ? showsRed : showsMACD
        }
        return VStack(alignment: .leading, spacing: 10) {
            if showsMACD, let observation, observation.macd != nil || localMACD != nil {
                MACDObservationDashboard(observation: observation, analysis: localMACD)
            }
            if showsRed, let observation, observation.valuation != nil {
                RedObservationDashboard(observation: observation, fund: fund, research: model.research)
            }
            BandHistoryDashboard(fund: fund, research: model.research, showsMACD: showsMACD && localMACD == nil)
            if !metrics.isEmpty {
                ObservationMetricGrid(metrics: metrics)
            }
            Text("再次导入可更新本地观察数据")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static let redMetricKeys: Set<String> = [
        "anchor", "anchor_mode", "dividend", "pe", "pb", "level", "advice", "spread",
        "relative", "relative_diff", "stats_1y", "stats_6m", "stats_3m"
    ]

    @ViewBuilder private func historyContent(_ history: FundHistory, fund: Fund) -> some View {
        let selection = tab == .returns ? $returnsRange : $historyRange
        let range = selection.wrappedValue
        if history.isDegraded {
            Label(
                "历史净值接口暂时不可用，当前显示最近披露数据。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(Display.warning)
            .researchCard()
        }
        HStack(spacing: 8) {
            ThemedSegmentedControl(
                options: HistoryPeriod.allCases, selection: selection, title: "时间区间"
            ) { $0.rawValue }
            .frame(maxWidth: .infinity)
            if tab == .history, !fund.isMoney, !history.accumulated.isEmpty {
                Picker("净值类型", selection: $historyStyle) {
                    ForEach(HistoryStyle.allCases, id: \.self) { style in Text(style.rawValue).tag(style) }
                }
                .labelsHidden()
                .frame(width: 94)
            }
        }
        let rows = history.rows(in: range)
        if tab == .returns {
            let points = history.returns(in: range, money: fund.isMoney)
            Text(fund.isMoney ? "按披露的万份收益复利计算 · 天天基金" : "按披露的日涨跌复利计算 · 天天基金")
                .font(.caption).foregroundStyle(.secondary)
            ResearchChart(points: points, unit: .percent, height: 195).id(range)
        } else {
            let style = fund.isMoney || history.accumulated.isEmpty ? HistoryStyle.unit : historyStyle
            let points = style == .accumulated
                ? history.accumulated.filter { $0.time >= (rows.first.flatMap { MarketClock.timestamp(day: $0.day) } ?? .distantPast) }
                : rows.compactMap { row in
                    MarketClock.timestamp(day: row.day).map { PlotPoint(time: $0, value: row.value) }
                }
            Text((fund.isMoney ? "万份收益" : style.rawValue) + " · \(points.count) 个披露日 · 天天基金")
                .font(.caption).foregroundStyle(.secondary)
            ResearchChart(points: points, unit: .number, height: 175).id(range.rawValue + style.rawValue)
            Text("最近披露").font(.callout.weight(.semibold)).padding(.top, 4)
            Grid(horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    Text("净值日期").gridCellAnchor(.leading)
                    Text(fund.isMoney ? "万份收益" : "单位净值").gridCellAnchor(.trailing)
                    Text(fund.isMoney ? "七日年化" : "日涨跌").gridCellAnchor(.trailing)
                }
                .foregroundStyle(.secondary)
                ForEach(Array(rows.suffix(8).reversed())) { row in
                    GridRow {
                        Text(row.day).gridCellAnchor(.leading)
                        Text(Display.number(row.value, digits: 4)).gridCellAnchor(.trailing)
                        Text(Display.percent(fund.isMoney ? row.annualizedRate : row.rate)).gridCellAnchor(.trailing)
                    }
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    @MainActor private func pollStockQuotes(symbols: Set<String>, provider: MarketProviders) async {
        guard !symbols.isEmpty else { return }
        while !Task.isCancelled {
            do {
                let fresh = try await provider.stockQuotes(symbols: symbols)
                try Task.checkCancellation()
                stockQuotes = fresh
                stockQuoteFailed = false
            } catch {
                if Task.isCancelled { return }
                stockQuoteFailed = true
            }
            do {
                try await Task.sleep(for: .seconds(model.board.refreshIntervalValue.rawValue))
            } catch {
                return
            }
        }
    }

    @ViewBuilder private func disclosureContent(_ report: FundDisclosure) -> some View {
        let showsStockQuotes = report.holdings.contains { $0.type == "股票" }
        let symbols = Set(report.holdings.compactMap(\.stockQuoteSymbol))
        HStack {
            Text("披露期 " + (report.reportDay ?? "未提供") + " · 天天基金").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let target = report.targetCode {
                Text("目标 ETF  " + (report.targetName ?? "") + " " + target).font(.caption).foregroundStyle(.secondary)
            }
        }
        if report.holdings.isEmpty {
            Text("该报告暂未提供重仓明细。").font(.callout).foregroundStyle(.secondary)
        } else {
            if showsStockQuotes {
                Text(stockQuoteStatus(symbols: symbols))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(stockQuoteFailed ? Display.warning : Color.secondary)
            }
            VStack(spacing: 0) {
                disclosureRow("名称", "代码", "类别", "占净值", "较上期", showsStockQuotes: showsStockQuotes,
                              quoteText: "当日涨跌幅")
                    .foregroundStyle(.secondary)
                ForEach(report.holdings) { row in
                    let quote = row.stockQuoteSymbol.flatMap { stockQuotes[$0] }
                    Divider()
                    disclosureRow(row.name, row.code, row.type, Display.unsigPercent(row.weight), row.change ?? "—",
                                  showsStockQuotes: showsStockQuotes, quoteText: Display.percent(quote?.rate), quote: quote)
                }
            }
            .preference(key: HoldingStockSymbols.self, value: symbols)
        }
    }

    private func stockQuoteStatus(symbols: Set<String>) -> String {
        if symbols.isEmpty { return "个股行情暂不可用" }
        let quotes = symbols.compactMap { stockQuotes[$0] }
        if stockQuoteFailed {
            return quotes.isEmpty ? "腾讯行情 · 刷新失败" : "腾讯行情 · 刷新失败，显示上次报价"
        }
        guard let timestamp = quotes.map(\.timestamp).max() else {
            return stockQuotes.isEmpty ? "正在获取个股行情…" : "腾讯行情 · 暂无报价"
        }
        let coverage = quotes.count < symbols.count ? " · 部分报价缺失" : ""
        return "腾讯行情 · 最新 " + Display.chinaDateTime(timestamp) + coverage
    }

    private func disclosureRow(_ name: String, _ code: String, _ type: String, _ weight: String, _ change: String,
                               showsStockQuotes: Bool, quoteText: String, quote: StockQuote? = nil) -> some View {
        HStack(spacing: 12) {
            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(code).frame(width: 65, alignment: .trailing)
            Text(type).frame(width: 46, alignment: .trailing)
            if showsStockQuotes {
                Text(quoteText)
                    .foregroundStyle(Display.changeColor(quote?.rate))
                    .frame(width: 76, alignment: .trailing)
                    .help(quote.map { "腾讯行情 · " + Display.chinaDateTime($0.timestamp) + " 北京时间" } ?? "当日涨跌幅")
            }
            Text(weight).frame(width: 70, alignment: .trailing)
            Text(change).frame(width: 130, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.vertical, 5)
    }

    private func profileContent(_ profile: FundProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    profileField("基金类型", profile.category)
                    profileField("基金公司", profile.company)
                }
                GridRow {
                    profileField("基金经理", profile.managerNames)
                    profileField("基金规模", profile.size.map { Display.billions($0) + "元" })
                }
                GridRow {
                    profileField("申购状态", profile.subscription)
                    profileField("赎回状态", profile.redemption)
                }
                GridRow {
                    profileField("累计净值", profile.cumulativeNAV.map { Display.number($0, digits: 4) })
                    profileField("公布费率", profile.originalFee ?? profile.purchaseFee)
                }
            }
            if !profile.recent.isEmpty {
                Divider()
                HStack(spacing: 9) {
                    ForEach(profile.recent) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.period).foregroundStyle(.secondary)
                            Text(Display.percent(item.rate)).foregroundStyle(Display.changeColor(item.rate))
                            if let rank = item.rank { Text("排名 \(rank)" + (item.sample.map { "/\($0)" } ?? "")) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    private func profileField(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value ?? "—").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .gridCellAnchor(.leading)
    }

    @ViewBuilder private func managersContent(_ group: FundManagerHistory) -> some View {
        if group.current.isEmpty && group.tenures.isEmpty {
            Text("数据源暂未提供经理档案。").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(group.current) { manager in
            DisclosureGroup(manager.name + (manager.since.map { " · \($0) 起" } ?? "")) {
                if let education = manager.education { Text(education).font(.caption).foregroundStyle(.secondary) }
                Text(manager.resume ?? "简介暂未披露。").font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
        if !group.tenures.isEmpty {
            Text("历任区间").font(.callout.weight(.semibold)).padding(.top, 3)
            ForEach(group.tenures) { tenure in
                HStack {
                    Text(tenure.name).lineLimit(1)
                    Spacer()
                    Text((tenure.since ?? "—") + " 至 " + (tenure.end ?? "现在")).foregroundStyle(.secondary)
                    Text(Display.percent(tenure.rate)).frame(width: 65, alignment: .trailing)
                        .foregroundStyle(Display.changeColor(tenure.rate))
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    private func position(_ holding: Holding) -> some View {
        let metrics = FundMetrics(holding: holding, snapshot: snapshot, now: model.now)
        let quantity = positionDecimal(shares)
        let costPerShare = positionDecimal(cost)
        let sharesEmpty = shares.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let costEmpty = cost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let valid = (sharesEmpty || (quantity.map { $0 >= 0 } ?? false))
            && (holding.fund.isMoney || costEmpty || (costPerShare.map { $0 > 0 } ?? false))
        let draft = Holding(
            fund: holding.fund,
            shares: sharesEmpty ? nil : quantity,
            costPerShare: holding.fund.isMoney || costEmpty ? nil : costPerShare
        )
        let preview = FundMetrics(holding: draft, snapshot: snapshot, now: model.now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地持仓").font(.headline)
                    Text("只保存在这台 Mac，可随时用持仓流水校正")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !isEditing {
                    Button("持仓流水", systemImage: "list.bullet.rectangle") { showJournal = true }
                        .buttonStyle(.bordered)
                    Button("编辑持仓", systemImage: "square.and.pencil") {
                        reset(holding)
                        isEditing = true
                        saved = false
                        focusedPositionField = .shares
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Display.primary)
                }
            }
            if isEditing {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("持有份额").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            TextField("例如 10,000.00", text: $shares)
                                .textFieldStyle(.plain)
                                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                                .focused($focusedPositionField, equals: .shares)
                                .accessibilityLabel("持有份额")
                                .onSubmit {
                                    if holding.fund.isMoney {
                                        savePosition(holding, quantity: quantity, costPerShare: costPerShare)
                                    } else {
                                        focusedPositionField = .cost
                                    }
                                }
                            Text("份").font(.callout).foregroundStyle(.secondary)
                        }
                        Text(sharesEmpty ? "留空保存会清除持仓" : "当前份额")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Display.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(focusedPositionField == .shares ? Display.primary : Display.stroke,
                                          lineWidth: focusedPositionField == .shares ? 1.5 : 1)
                    }

                    if !holding.fund.isMoney {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("单位成本").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                TextField("例如 1.0144", text: $cost)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                                    .focused($focusedPositionField, equals: .cost)
                                    .accessibilityLabel("单位成本")
                                    .onSubmit {
                                        if valid { savePosition(holding, quantity: quantity, costPerShare: costPerShare) }
                                    }
                                Text("元").font(.callout).foregroundStyle(.secondary)
                            }
                            Text(costEmpty ? "用于计算持有收益" : "当前单位成本")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(Display.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(focusedPositionField == .cost ? Display.primary : Display.stroke,
                                              lineWidth: focusedPositionField == .cost ? 1.5 : 1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("当前正式净值").font(.caption).foregroundStyle(.secondary)
                        Text(Display.number(snapshot.nav?.value, digits: 4))
                            .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        Text(snapshot.nav?.day ?? "等待净值")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 108, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Display.primarySoft.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Group {
                        if let validation = positionValidation(holding, quantity: quantity, costPerShare: costPerShare) {
                            Label(validation, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Display.danger)
                        } else if let amount = preview.value {
                            Label("持仓金额约 " + Display.money(amount), systemImage: "equal.circle")
                                .foregroundStyle(.secondary)
                            if !holding.fund.isMoney, let gain = preview.profit {
                                Text("持有收益约 " + Display.money(gain, signed: true))
                                    .foregroundStyle(Display.changeColor(gain))
                            }
                        } else {
                            Label(holding.fund.isMoney ? "按持有份额计算金额" : "填写份额后可预览持仓金额和收益",
                                  systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    Spacer()
                    Button("取消") {
                        reset(holding)
                        focusedPositionField = nil
                        isEditing = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("保存持仓") {
                        savePosition(holding, quantity: quantity, costPerShare: costPerShare)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Display.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
                }
            } else {
                if holding.shares == nil || (holding.shares ?? 0) <= 0 {
                    HStack(spacing: 9) {
                        Image(systemName: "tray.and.arrow.down")
                            .foregroundStyle(Display.primary)
                            .frame(width: 28, height: 28)
                            .background(Display.primarySoft, in: RoundedRectangle(cornerRadius: 7))
                        Text("尚未填写持有份额").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    HStack(spacing: 0) {
                        positionStat("持有份额", Display.number(holding.shares, digits: 2), suffix: "份")
                        Divider().frame(height: 30)
                        if !holding.fund.isMoney {
                            positionStat("单位成本", Display.number(holding.costPerShare, digits: 4), suffix: "元")
                            Divider().frame(height: 30)
                        }
                        positionStat("持有金额", Display.money(metrics.value))
                        Divider().frame(height: 30)
                        positionStat(
                            "持有收益",
                            Display.money(metrics.profit, signed: true),
                            color: Display.changeColor(metrics.profit)
                        )
                        if let gain = metrics.estimatedDayProfit {
                            Divider().frame(height: 30)
                            positionStat(
                                "盘中估算日收益",
                                Display.money(gain, signed: true),
                                color: Display.changeColor(gain)
                            )
                        }
                    }
                }
                HStack(spacing: 10) {
                    if saved { Label("已保存", systemImage: "checkmark.circle.fill").foregroundStyle(Display.primary) }
                    if model.storageWarning != nil {
                        Label("本地保存待恢复", systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(Display.warning)
                    }
                    Spacer()
                    Text("最近净值 " + (snapshot.nav?.day ?? "—"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(13)
        .background(Display.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Display.stroke) }
    }

    private func positionStat(_ title: String, _ value: String, suffix: String? = nil,
                              color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let suffix {
                    Text(suffix).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
    }

    private func positionDecimal(_ input: String) -> Decimal? {
        let normalized = input
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decimal(normalized)
    }

    private func positionValidation(
        _ holding: Holding, quantity: Decimal?, costPerShare: Decimal?
    ) -> String? {
        let sharesEmpty = shares.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let costEmpty = cost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !sharesEmpty, quantity == nil { return "持有份额请输入数字" }
        if let quantity, quantity < 0 { return "持有份额不能小于 0" }
        if !holding.fund.isMoney, !costEmpty, costPerShare == nil { return "单位成本请输入数字" }
        if !holding.fund.isMoney, let costPerShare, costPerShare <= 0 { return "单位成本必须大于 0" }
        return nil
    }

    private func savePosition(_ holding: Holding, quantity: Decimal?, costPerShare: Decimal?) {
        let shares = shares.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : quantity
        saved = model.savePosition(
            code: code,
            shares: shares,
            cost: holding.fund.isMoney ? nil : costPerShare
        )
        focusedPositionField = nil
        isEditing = false
    }

    private func reset(_ holding: Holding) {
        shares = holding.shares.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        cost = holding.costPerShare.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }
}
