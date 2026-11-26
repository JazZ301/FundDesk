import AppKit
import FundCore
import SwiftUI
import UniformTypeIdentifiers

// The property-wrapper spelling also builds with Command Line Tools without SwiftUI's macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

private struct SearchFocusDismissMonitor: NSViewRepresentable {
    let isFocused: Bool
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isFocused = isFocused
        context.coordinator.dismiss = dismiss
        guard context.coordinator.monitor == nil else { return }
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak view, weak coordinator = context.coordinator] event in
            guard let view, let coordinator, coordinator.isFocused,
                  event.window === view.window else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            if !view.bounds.contains(point) {
                DispatchQueue.main.async { coordinator.dismiss?() }
            }
            return event
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var isFocused = false
        var dismiss: (() -> Void)?
        var monitor: Any?
    }
}

enum Display {
    static let primary = Color(light: 0x3d63d6, dark: 0x5fd1c6)
    static let primaryStrong = Color(light: 0x243f98, dark: 0xa8eee7)
    static let primarySoft = Color(light: 0xe3e9fb, dark: 0x173b49)
    static let up = Color(light: 0xd64c61, dark: 0xff756f)
    static let down = Color(light: 0x168b77, dark: 0x41d6a1)
    static let warning = Color(light: 0xb97818, dark: 0xf0ba63)
    static let danger = Color(light: 0xc74458, dark: 0xff756f)
    static let canvasTop = Color(light: 0xf7f8fd, dark: 0x081b2b)
    static let canvasBottom = Color(light: 0xeff3fa, dark: 0x061521)
    static let sidebar = Color(light: 0xe9eef9, dark: 0x0a2032)
    static let panel = Color(light: 0xffffff, dark: 0x0e273a)
    static let panelRaised = Color(light: 0xf7f9fe, dark: 0x0b2234)
    static let alternateRow = Color(light: 0xf1f5fc, dark: 0x132e43)
    static let stroke = Color(light: 0xdde4f2, dark: 0x1b3a4d)
    static let selected = Color(light: 0xe3e9fb, dark: 0x173b49)
    static let heroStart = Color(light: 0x3459c9, dark: 0x0f3b4d)
    static let heroEnd = Color(light: 0x7368d6, dark: 0x12506a)
    static let canvasWash = LinearGradient(
        colors: [canvasTop, canvasBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let heroGradient = LinearGradient(
        colors: [heroStart, heroEnd],
        startPoint: .leading,
        endPoint: .trailing
    )

    private static func rounded(_ value: Decimal, digits: Int) -> Decimal {
        var original = value
        var result = Decimal.zero
        NSDecimalRound(&result, &original, digits, .bankers)
        return result == 0 ? .zero : result
    }

    static func number(_ value: Decimal?, digits: Int) -> String {
        guard let value else { return "—" }
        return rounded(value, digits: digits).formatted(.number.precision(.fractionLength(digits)))
    }

    static func signedNumber(_ value: Decimal?, digits: Int = 2) -> String {
        guard let value else { return "—" }
        let displayed = rounded(value, digits: digits)
        return (displayed > 0 ? "+" : "") + number(displayed, digits: digits)
    }

    static func money(_ value: Decimal?, signed: Bool = false) -> String {
        guard let value else { return "—" }
        let displayed = rounded(value, digits: 2)
        return (signed && displayed > 0 ? "+" : "") + (displayed < 0 ? "−" : "")
            + "¥" + number(abs(displayed), digits: 2)
    }

    static func percent(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return signedNumber(value) + "%"
    }

    static func precisePercent(_ value: Decimal?) -> String? {
        value.map { NSDecimalNumber(decimal: $0).stringValue + "%" }
    }

    static func changeColor(_ value: Decimal?, digits: Int? = 2) -> Color {
        guard let value else { return .secondary }
        let displayed = digits.map { rounded(value, digits: $0) } ?? value
        guard displayed != 0 else { return .secondary }
        return displayed > 0 ? up : down
    }

    static func primary(for theme: AppearanceTheme, systemColorScheme: ColorScheme) -> Color {
        let colorScheme: ColorScheme
        switch theme {
        case .system: colorScheme = systemColorScheme
        case .light: colorScheme = .light
        case .dark: colorScheme = .dark
        }
        return colorScheme == .dark ? Color(rgb: 0x5fd1c6) : Color(rgb: 0x3d63d6)
    }

    static func dayTime(_ date: Date) -> String {
        let parts = MarketClock.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour!, parts.minute!)
    }
}

extension AppearanceTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private extension Color {
    init(rgb: UInt32) {
        let red = Double((rgb >> 16) & 255) / 255
        let green = Double((rgb >> 8) & 255) / 255
        let blue = Double(rgb & 255) / 255
        self.init(nsColor: NSColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let color = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((color >> 16) & 255) / 255, green: Double((color >> 8) & 255) / 255,
                           blue: Double(color & 255) / 255, alpha: 1)
        })
    }
}

struct BoardView: View {
    @ObservedObject var model: BoardModel
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var filter: Filter = .all
    @ViewState private var showingFutures = false
    @ViewState private var sortColumn: FundTableColumn?
    @ViewState private var ascending = false
    @ViewState private var searchText = ""
    @FocusState private var searchFocused: Bool
    @ViewState private var sheet: Sheet?
    @ViewState private var notice: BoardNotice?
    @ViewState private var importing = false
    @ViewState private var importKind = FileImportKind.holdings
    @ViewState private var exporting = false
    @ViewState private var backup = BackupFile()
    @ViewState private var exportType = UTType.json
    @ViewState private var removal: Holding?
    @ViewState private var showingDayProfitDetails = false

    struct BoardNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum Filter: String, CaseIterable {
        case all = "全部自选"
        case holding = "我的持仓"
        case macd = "MACD 观察"
        case red = "红利观察"

        var observationGroup: FundGroup? {
            switch self {
            case .macd: return .macd
            case .red: return .red
            case .all, .holding: return nil
            }
        }

        func contains(_ holding: Holding) -> Bool {
            if let group = observationGroup { return holding.groupValues.contains(group) }
            return self == .all || (holding.shares ?? 0) > 0
        }

        var icon: String {
            switch self {
            case .all: return "bookmark"
            case .holding: return "wallet.bifold"
            case .macd: return "waveform.path.ecg"
            case .red: return "banknote"
            }
        }
    }

    enum FileImportKind {
        case holdings
        case observations
        case backup

        var contentTypes: [UTType] {
            switch self {
            case .holdings: return [.json, .plainText, .commaSeparatedText]
            case .observations: return [.folder]
            case .backup: return [.json]
            }
        }
    }

    enum Sheet: Identifiable {
        case search
        case detail(String)
        case market(MarketIndex?)
        case settings
        case imported(ImportPreview)
        case restore(BoardBackup)

        var id: String {
            switch self {
            case .search: return "search"
            case .detail(let code): return code
            case .market: return "market"
            case .settings: return "settings"
            case .imported: return "import"
            case .restore: return "restore"
            }
        }
    }

    private var holdings: [Holding] {
        let base = model.board.holdings.filter(filter.contains)
        let matched = hasSearch ? base.filter { $0.fund.matchesSearch(searchText) } : base
        guard let sortColumn else { return matched }
        let values = matched.map { holding in
            let snapshot = model.snapshot(for: holding.id)
            let metrics = FundMetrics(holding: holding, snapshot: snapshot, now: model.now)
            let value: Decimal?
            switch sortColumn {
            case .estimateRate: value = holding.fund.isMoney ? nil : snapshot.effectiveEstimate(now: model.now)?.percent
            case .dayProfit: value = metrics.publishedDayProfit ?? metrics.estimatedDayProfit
            case .value: value = metrics.value
            case .profit: value = metrics.profit
            case .profitRate: value = metrics.rate
            case .navRate: value = holding.fund.isMoney || snapshot.nav?.annualizedRate != nil ? nil : snapshot.nav?.rate
            default: value = nil
            }
            return (holding, value)
        }
        return values.sorted {
            switch ($0.1, $1.1) {
            case let (lhs?, rhs?) where lhs != rhs: return ascending ? lhs < rhs : lhs > rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.0.id < $1.0.id
            }
        }.map { $0.0 }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Display.stroke).frame(width: 1)
            mainPanel
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .id(model.board.appearanceThemeValue)
        .frame(minWidth: 1040, minHeight: 600)
        .background(Display.canvasWash)
        .tint(Display.primary(for: model.board.appearanceThemeValue, systemColorScheme: colorScheme))
        .preferredColorScheme(model.board.appearanceThemeValue.colorScheme)
        .sheet(item: $sheet, content: sheetContent)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: importKind.contentTypes
        ) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                switch importKind {
                case .observations:
                    let summary = try model.importObservations(from: url)
                    showingFutures = false
                    if summary.groups == [.macd] {
                        filter = .macd
                    } else if summary.groups == [.red] {
                        filter = .red
                    } else {
                        filter = .all
                    }
                    notice = BoardNotice(
                        title: "观察数据已导入",
                        message: importMessage(summary)
                    )
                case .backup:
                    try previewRestore(from: url)
                case .holdings:
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 10_000_000 else { throw ImportPreview.FormatError.invalid }
                    sheet = .imported(try model.prepareImport(Data(contentsOf: url)))
                }
            } catch {
                notice = BoardNotice(title: "基金看板", message: error.localizedDescription)
            }
        }
        .fileExporter(isPresented: $exporting, document: backup, contentType: exportType,
                      defaultFilename: exportType == .json ? "基金看板备份" : "基金持仓表") { result in
            if case .failure(let failure) = result {
                notice = BoardNotice(title: "基金看板", message: failure.localizedDescription)
            }
        }
        .alert(
            notice?.title ?? "基金看板",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(notice?.message ?? "")
        }
        .alert("移除此基金？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
               presenting: removal) { holding in
            Button("移除", role: .destructive) { model.remove(holding.id) }
            Button("取消", role: .cancel) {}
        } message: { holding in
            Text("将从自选中移除\(holding.fund.name)及本地持仓和流水。")
        }
    }

    @ViewBuilder
    private var mainPanel: some View {
        if showingFutures {
            FuturesView(research: model.research)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                header
                if let warning = model.storageWarning {
                    Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.callout).foregroundStyle(Display.warning)
                }
                summary
                MarketQuoteStrip(quotes: model.marketQuotes) { index in
                    sheet = .market(index)
                }
                table
                footer
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: Sheet) -> some View {
        switch item {
        case .search: SearchView(model: model) { sheet = .detail($0) }
        case .detail(let code): FundDetail(model: model, code: code)
        case .market(let index):
            MarketCenter(research: model.research, quotes: model.marketQuotes, selectedIndex: index)
        case .settings: SettingsView(model: model)
        case .imported(let preview): importSheet(preview)
        case .restore(let backup): restoreSheet(backup)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background(Display.heroGradient, in: RoundedRectangle(cornerRadius: 8))
                Text("基金看板").font(.system(size: 16, weight: .semibold))
            }
            .padding(.bottom, 14)
            ForEach(Filter.allCases, id: \.self) { item in
                sidebarItem(item.rawValue, icon: item.icon, count: sidebarCount(item),
                            selected: !showingFutures && filter == item) {
                    filter = item
                    showingFutures = false
                }
            }
            sidebarItem("行情中心", icon: "chart.bar.xaxis") { sheet = .market(nil) }
            sidebarItem("期货", icon: "waveform.path", selected: showingFutures) {
                showingFutures = true
            }
            sidebarItem("设置", icon: "slider.horizontal.3") { sheet = .settings }
            Spacer()
            Divider()
            Button {
                importKind = .holdings
                importing = true
            } label: {
                Label("合并导入", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button {
                importKind = .observations
                importing = true
            } label: {
                Label("导入观察数据", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Menu("备份与恢复", systemImage: "externaldrive") {
                Button("导出完整备份（JSON）") { exportBackup(full: true) }
                Button("导出轻量迁移备份（JSON）") { exportBackup(full: false) }
                Button("导出自选与持仓（CSV）") { export(as: .commaSeparatedText) }
                    .disabled(model.board.holdings.isEmpty)
                Divider()
                Button("从备份恢复…") {
                    importKind = .backup
                    importing = true
                }
                if let point = model.restorePoint {
                    Button("恢复到上次恢复前…") {
                        do {
                            try previewRestore(from: point)
                        } catch {
                            notice = BoardNotice(title: "无法读取恢复点", message: error.localizedDescription)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(13)
        .frame(width: 152)
        .background(Display.sidebar)
    }

    private func export(as type: UTType) {
        do {
            let data = type == .json ? try model.export() : HoldingCSV.export(model.board.holdings)
            exportType = type
            backup = BackupFile(data: data)
            exporting = true
        } catch {
            notice = BoardNotice(title: "基金看板", message: error.localizedDescription)
        }
    }

    private func exportBackup(full: Bool) {
        do {
            exportType = .json
            backup = BackupFile(data: try model.export(full: full))
            exporting = true
        } catch {
            notice = BoardNotice(title: "基金看板", message: error.localizedDescription)
        }
    }

    private func sidebarItem(_ title: String, icon: String, count: Int? = nil, selected: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 16)
                Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 2)
                if let count {
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 25, alignment: .trailing)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 29)
            .background(selected ? Display.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Display.primary)
                        .frame(width: 3, height: 15)
                        .padding(.leading, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Display.primaryStrong : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sidebarCount(_ item: Filter) -> Int {
        model.board.holdings.filter(item.contains).count
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(filter.rawValue).font(.system(size: 21, weight: .semibold))
            Text(MarketClock.day(model.now) + " · 北京时间")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button {
                model.refresh()
            } label: {
                Label(model.refreshing ? "刷新中…" : "刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.refreshing || model.board.holdings.isEmpty)
            .keyboardShortcut("r", modifiers: .command)
            Button {
                sheet = .search
            } label: {
                Label("添加基金", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Display.primary(for: model.board.appearanceThemeValue, systemColorScheme: colorScheme))
            .keyboardShortcut("n", modifiers: .command)
        }
        .controlSize(.regular)
    }

    private var summary: some View {
        let portfolio = Portfolio(board: model.board, now: model.now)
        return VStack(alignment: .leading, spacing: 4) {
            Text("全部持仓汇总")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                metric("持有金额", value: Display.money(portfolio.value),
                       note: portfolio.missingValuationCount > 0 ? "\(portfolio.missingValuationCount) 只待更新" : "按最近正式净值",
                       color: .white, icon: "yensign.circle", featured: true)
                Button {
                    showingDayProfitDetails.toggle()
                } label: {
                    metric("当日收益", value: Display.money(portfolio.dayProfit, signed: true),
                           note: dayProfitNote(portfolio), color: Display.changeColor(portfolio.dayProfit),
                           icon: "waveform.path.ecg", showsDetails: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看收益口径、已披露、待披露估算和覆盖明细")
                .popover(isPresented: $showingDayProfitDetails, arrowEdge: .bottom) {
                    dayProfitDetails(portfolio)
                }
                metric("持有收益", value: Display.money(portfolio.profit, signed: true),
                       note: "已填写成本的持仓", color: Display.changeColor(portfolio.profit),
                       icon: "chart.line.uptrend.xyaxis")
            }
        }
    }

    private func dayProfitNote(_ portfolio: Portfolio) -> String {
        guard portfolio.holdingCount > 0 else { return "暂无持仓" }
        return "已披露 \(portfolio.publishedDayCount) · 估算 \(portfolio.estimatedDayCount) · 覆盖 \(portfolio.coveredDayCount)/\(portfolio.holdingCount) 只"
    }

    private func dayProfitDetails(_ portfolio: Portfolio) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("全部持仓日收益").font(.headline)
            Text("\(portfolio.day) · 按当前份额计算").font(.caption).foregroundStyle(.secondary)
            LabeledContent("已披露收益 · \(portfolio.publishedDayCount) 只",
                           value: Display.money(portfolio.publishedDayProfit, signed: true))
            LabeledContent("待披露估算 · \(portfolio.estimatedDayCount) 只",
                           value: Display.money(portfolio.estimatedDayProfit, signed: true))
            Divider()
            Text("覆盖 \(portfolio.coveredDayCount) / \(portfolio.holdingCount) 只持仓")
                .font(.subheadline.weight(.medium))
            ForEach(DayProfitExclusion.allCases, id: \.self) { reason in
                if let count = portfolio.dayProfitExclusions[reason] {
                    LabeledContent(reason.rawValue, value: "\(count) 只")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .monospacedDigit()
        .padding(16)
        .frame(width: 320)
    }

    private func metric(
        _ title: String, value: String, note: String, color: Color,
        icon: String, featured: Bool = false, showsDetails: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(featured ? Color.white.opacity(0.82) : Display.primary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(featured ? Color.white.opacity(0.78) : Color.secondary)
                Spacer(minLength: 2)
                Text(value).font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                if showsDetails {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(featured ? Color.white.opacity(0.68) : Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if featured {
                RoundedRectangle(cornerRadius: 8).fill(Display.heroGradient)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Display.panel)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(featured ? Color.white.opacity(0.12) : Display.stroke)
        }
    }

    private var table: some View {
        let columns = model.board.visibleFundColumns
        let visible = holdings
        let canMoveRows = sortColumn == nil && visible.count > 1
        let visibleCodes = Set(visible.map(\.id))
        return VStack(spacing: 0) {
            HStack {
                Text("基金列表").font(.system(size: 12, weight: .semibold))
                Text(visible.count.formatted())
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Display.primaryStrong)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Display.primarySoft, in: Capsule())
                fundListSearch
                Spacer(minLength: 4)
                FundTableColumnPicker(model: model)
                if sortColumn != nil {
                    Button(ascending ? "升序" : "降序", systemImage: ascending ? "arrow.up" : "arrow.down") {
                        ascending.toggle()
                    }
                    .controlSize(.small)
                    .help(ascending ? "切换为降序" : "切换为升序")
                }
                Picker("排序", selection: Binding(
                    get: { sortColumn },
                    set: { if sortColumn != $0 { sortColumn = $0; ascending = false } }
                )) {
                    Text("添加顺序").tag(nil as FundTableColumn?)
                    ForEach(FundTableColumn.sortable, id: \.self) {
                        Text($0.title).tag(Optional($0))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 102)
                .accessibilityLabel("排序方式")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            Divider()
            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, holding in
                                Group {
                                    if canMoveRows {
                                        DraggableFundRow(holding: holding) { code, target, placement in
                                            model.moveHolding(code, relativeTo: target, placement: placement, visibleCodes: visibleCodes)
                                        } content: {
                                            row(holding, columns: columns)
                                        }
                                    } else {
                                        row(holding, columns: columns)
                                    }
                                }
                                .background(index.isMultiple(of: 2) ? Color.clear : Display.alternateRow)
                            }
                        } header: {
                            FundTableHeader(columns: columns, sortColumn: sortColumn, ascending: ascending,
                                            sort: sortByColumn, save: model.reorderVisibleFundColumns)
                                .id(columns)
                                .padding(.leading, canMoveRows ? FundRowLayout.handleWidth : 0)
                                .background(Display.panelRaised)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Display.panel, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Display.stroke).allowsHitTesting(false) }
    }

    private var hasSearch: Bool {
        searchText.contains { !$0.isWhitespace }
    }

    private var fundListSearch: some View {
        HStack(spacing: 5) {
            Button {
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("查找自选基金")
            .help("查找自选基金（⌘F）")
            TextField("查找名称或代码", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($searchFocused)
                .defaultFocus($searchFocused, false)
                .onAppear {
                    DispatchQueue.main.async { searchFocused = false }
                }
                .background {
                    SearchFocusDismissMonitor(isFocused: searchFocused) { searchFocused = false }
                }
                .accessibilityLabel("筛选当前基金列表")
                .onSubmit {
                    if hasSearch, let first = holdings.first {
                        searchFocused = false
                        sheet = .detail(first.id)
                    }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("清空基金筛选")
            }
        }
        .padding(.horizontal, 6)
        .frame(width: 165, height: 21)
        .background(Display.panelRaised, in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(searchFocused ? Display.primary : Display.stroke) }
    }

    private func sortByColumn(_ column: FundTableColumn) {
        ascending = sortColumn == column ? !ascending : false
        sortColumn = column
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasSearch {
            VStack(spacing: 8) {
                Text("当前列表没有匹配的基金").font(.headline)
                if filter != .all {
                    Button("在全部自选中查找") { filter = .all }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unfilteredEmptyState
        }
    }

    private var unfilteredEmptyState: some View {
        let title: String
        let detail: String
        switch filter {
        case .all:
            title = "还没有自选基金"
            detail = "按名称、代码或拼音搜索，也可以导入原插件的配置。"
        case .holding:
            title = "还没有持仓"
            detail = "在自选列表打开基金详情，填写持有份额。"
        case .macd:
            title = "还没有 MACD 观察基金"
            detail = "导入桌面上的 macd 文件夹，原有持仓和流水会保留。"
        case .red:
            title = "还没有红利观察基金"
            detail = "导入桌面上的 red 文件夹，原有持仓和流水会保留。"
        }
        return VStack(spacing: 10) {
            Image(systemName: filter.icon)
                .font(.system(size: 23, weight: .medium)).foregroundStyle(Display.primary)
                .frame(width: 46, height: 46).background(Display.selected, in: RoundedRectangle(cornerRadius: 12))
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout).foregroundStyle(.secondary)
            Button(filter == .all ? "添加第一只基金" : "查看全部自选") {
                if filter == .all {
                    sheet = .search
                } else {
                    filter = .all
                }
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ holding: Holding, columns: [FundTableColumn]) -> some View {
        let snapshot = model.snapshot(for: holding.id)
        let estimate = snapshot.effectiveEstimate(now: model.now)
        let metrics = FundMetrics(holding: holding, snapshot: snapshot, now: model.now)
        return Button { sheet = .detail(holding.id) } label: {
            FundTableLine(columns: columns) { column in
                rowCell(column, holding: holding, snapshot: snapshot, metrics: metrics, estimate: estimate)
            }
            .frame(height: FundRowLayout.height)
            .background(alignment: .bottom) {
                Rectangle().fill(Display.stroke).frame(height: 0.5).padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help(holding.fund.name)
        .contextMenu {
            Button("查看基金详情") { sheet = .detail(holding.id) }
            if let group = filter.observationGroup {
                Button("移出\(group.title)") { model.removeFromGroup(holding.id, group: group) }
            } else {
                Button("移除基金", role: .destructive) { removal = holding }
            }
        }
    }

    @ViewBuilder
    private func rowCell(
        _ column: FundTableColumn, holding: Holding, snapshot: Snapshot, metrics: FundMetrics, estimate: Estimate?
    ) -> some View {
        let nav = snapshot.nav
        let isMoney = holding.fund.isMoney
        switch column {
        case .name:
            Text(holding.fund.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        case .estimateRate:
            cell(Display.percent(estimate?.percent), color: Display.changeColor(estimate?.percent),
                 help: Display.precisePercent(estimate?.percent))
        case .dayProfit:
            let profit = metrics.publishedDayProfit ?? metrics.estimatedDayProfit
            let info = metrics.publishedDayProfit != nil
                ? "已披露日收益 · 按当前份额计算" : "估算日收益 · 按当前份额计算"
            cell(Display.money(profit, signed: true), color: Display.changeColor(profit), help: profit.map { _ in info } ?? metrics.dayProfitExclusion?.rawValue)
        case .value:
            cell(Display.money(metrics.value))
        case .profit:
            cell(Display.money(metrics.profit, signed: true), color: Display.changeColor(metrics.profit))
        case .profitRate:
            cell(Display.percent(metrics.rate), color: Display.changeColor(metrics.rate))
        case .estimateTime:
            cell(estimateNote(holding, snapshot, estimate), color: .secondary,
                 help: snapshot.estimate.map { MarketClock.day($0.timestamp) + " " + Display.dayTime($0.timestamp) + " · 新浪财经" })
        case .code:
            cell(holding.id, color: .secondary)
        case .nav:
            cell(Display.number(nav?.value, digits: 4), help: isMoney ? "每万份收益" : "正式单位净值")
        case .navDate:
            cell(nav.map { String($0.day.suffix(5)) } ?? "—", color: .secondary,
                 help: nav.map { $0.day + " · " + $0.source })
        case .navRate:
            let rate = isMoney ? nav?.annualizedRate : nav?.rate
            cell(Display.percent(rate), color: isMoney ? .primary : Display.changeColor(rate),
                 help: isMoney ? "七日年化收益率" : "正式净值日涨跌")
        case .estimate:
            cell(Display.number(estimate?.value, digits: 4))
        }
    }

    private func estimateNote(_ holding: Holding, _ snapshot: Snapshot, _ estimate: Estimate?) -> String {
        if holding.fund.isMoney { return "—" }
        if let estimate { return Display.dayTime(estimate.timestamp) }
        if model.estimateFailures.contains(holding.id) { return "刷新失败" }
        if snapshot.estimate != nil { return "往期估算" }
        if model.refreshing && snapshot.estimateCheckedAt == nil { return "待更新" }
        return "未提供"
    }

    private func cell(_ text: String, color: Color = .primary, help: String? = nil) -> some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(text == "—" ? Color.secondary : color)
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .help(help ?? "")
    }

    private var footer: some View {
        let failed = model.navFailures.count
        let estimates = EstimateHealth(board: model.board, failures: model.estimateFailures, now: model.now)
        return HStack(spacing: 7) {
            if model.refreshing {
                ProgressView().controlSize(.mini)
                Text("正在检查基金数据")
            } else if failed > 0 || estimates.hasIssue {
                Image(systemName: "wifi.exclamationmark")
                Text(refreshWarning(navFailed: failed, estimates: estimates))
                    .help("估值状态：正常 \(estimates.freshCount) 只，超时 \(estimates.staleCount) 只，刷新失败 \(estimates.failedCount) 只，暂无 \(estimates.missingCount) 只")
            } else {
                Image(systemName: "externaldrive")
                Text(model.lastCheck.map { "最近检查 " + Display.dayTime($0) } ?? "数据保存在本机")
            }
            Spacer()
            Text("每 \(model.board.refreshIntervalValue.rawValue) 秒自动检查 · 估算来自新浪财经")
        }
        .font(.system(size: 10.5)).foregroundStyle(.secondary)
    }

    private func refreshWarning(navFailed: Int, estimates: EstimateHealth) -> String {
        var parts: [String] = []
        if navFailed > 0 { parts.append("\(navFailed) 只净值刷新失败") }
        if estimates.failedCount > 0 { parts.append("\(estimates.failedCount) 只估值刷新失败") }
        if estimates.staleCount > 0 { parts.append("\(estimates.staleCount) 只估值已超时") }
        return parts.joined(separator: " · ") + " · 保留上次数据"
    }

    private func importSheet(_ preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("合并导入").font(.title2.weight(.semibold))
            Text("将添加 \(preview.holdings.count) 只基金，跳过 \(preview.duplicates) 条重复和 \(preview.invalid) 条无效记录。")
                .foregroundStyle(.secondary)
            if !preview.holdings.isEmpty {
                let counts = Filter.allCases.map { item in
                    "\(item.rawValue) \(preview.holdings.filter(item.contains).count)"
                }
                Text(counts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.holdings) { holding in
                            Text(holding.id + "  " + holding.fund.name)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            HStack {
                Spacer()
                Button("取消") { sheet = nil }.keyboardShortcut(.cancelAction)
                Button("导入") {
                    model.importHoldings(preview)
                    showingFutures = false
                    filter = .all
                    sheet = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.holdings.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func previewRestore(from url: URL) throws {
        sheet = .restore(try BoardBackup(data: Data(contentsOf: url)))
    }

    private func restoreSheet(_ backup: BoardBackup) -> some View {
        let current = model.board
        let restored = backup.restoredBoard(over: current)
        let currentCodes = Set(current.holdings.map(\.id))
        let restoredCodes = Set(restored.holdings.map(\.id))

        return VStack(alignment: .leading, spacing: 12) {
            Text("从备份恢复").font(.title2.weight(.semibold))
            Text("自选、持仓、本地观察数据及流水将恢复为备份中的版本。")
            ForEach(Filter.allCases, id: \.self) { item in
                LabeledContent(item.rawValue,
                    value: "\(current.holdings.filter(item.contains).count) → \(restored.holdings.filter(item.contains).count) 只")
            }
            LabeledContent("持仓流水", value: "\(journalCount(current)) → \(journalCount(restored)) 条")
            Text("新增 \(restoredCodes.subtracting(currentCodes).count) 只 · 覆盖同代码 \(restoredCodes.intersection(currentCodes).count) 只 · 移出 \(currentCodes.subtracting(restoredCodes).count) 只")
                .foregroundStyle(.secondary)
            Text(backup.includesSettings
                 ? "同时恢复主题、刷新间隔、列配置和详情标签顺序。"
                 : "沿用本机主题、刷新间隔、列配置和详情标签顺序。")
                .foregroundStyle(.secondary)
            if backup.includesSettings && !backup.includesSnapshots {
                Text("恢复后会联网更新行情，打开详情时补取历史净值。")
                    .foregroundStyle(.secondary)
            }
            Text("恢复前会自动保存本机当前版本，可从「备份与恢复」撤销。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { sheet = nil }.keyboardShortcut(.cancelAction)
                Button("确认恢复", role: .destructive) {
                    do {
                        try model.restore(backup)
                        showingFutures = false
                        filter = .all
                        sheet = nil
                        notice = BoardNotice(title: "恢复完成", message: "已恢复 \(restored.holdings.count) 只基金。恢复前的版本已保存在本机。")
                    } catch {
                        sheet = nil
                        notice = BoardNotice(title: "恢复失败", message: error.localizedDescription)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func journalCount(_ board: Board) -> Int {
        board.journals?.values.reduce(0) { $0 + $1.count } ?? 0
    }

    private func importMessage(_ summary: BoardModel.ObservationImportSummary) -> String {
        var parts = [
            "新增 \(summary.added) 只，更新 \(summary.updated) 只。",
            "分类：" + summary.groups.map(\.title).joined(separator: "、")
        ]
        if !summary.sources.isEmpty {
            parts.append("来源：" + summary.sources.joined(separator: "、"))
        }
        if !summary.warnings.isEmpty {
            parts.append(summary.warnings.joined(separator: " "))
        }
        return parts.joined(separator: "\n")
    }
}

struct HoverRowStyle: ButtonStyle {
    @ViewState private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Display.selected : .clear)
            .onHover { hovering = $0 }
    }
}

struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
