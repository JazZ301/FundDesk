import AppKit
import Foundation
import FundCore
import SwiftUI

@MainActor
final class BoardModel: ObservableObject {
    @Published private(set) var board: Board
    @Published private(set) var now = Date.now
    @Published private(set) var refreshing = false
    @Published private(set) var navFailures: Set<String> = []
    @Published private(set) var estimateFailures: Set<String> = []
    @Published private(set) var storageWarning: String?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var restorePoint: URL?

    private let api: any MarketData
    let research: ResearchServices
    let marketQuotes: MarketQuotes
    private let storage: BoardStorage
    private var catalog: [Fund] = []
    private var catalogDate: Date?
    private var catalogTask: Task<[Fund], Error>?
    private var navAttempts: [String: Date] = [:]
    private var estimateAttempts: [String: Date] = [:]
    private var pendingCodes: Set<String> = []
    private var scheduler: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(api: any MarketData = MarketProviders()) {
        let custom = ProcessInfo.processInfo.environment["FUND_DESK_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let folder = custom.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FundDesk", isDirectory: true)
        storage = BoardStorage(directory: folder)
        research = ResearchServices(archive: ResearchArchive(directory: folder))
        marketQuotes = MarketQuotes(research: research)
        self.api = api
        let opened = storage.open()
        board = opened.board
        restorePoint = storage.latestRestorePoint()
        if opened.recovered { storageWarning = "主数据文件读取失败，已尝试从本机备份恢复。" }
        applyAppearanceTheme(board.appearanceThemeValue)
    }

    func start() {
        guard scheduler == nil else { return }
        Task { [marketQuotes] in await marketQuotes.poll() }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                do {
                    try await Task.sleep(for: .seconds(self.board.refreshIntervalValue.rawValue))
                } catch {
                    return
                }
            }
        }
    }

    private func tick() {
        now = .now
        startRefresh(automatic: true)
    }

    func refresh() {
        guard !refreshing else { return }
        now = .now
        pendingCodes.formUnion(board.holdings.map(\.id))
        startRefresh(automatic: false)
    }

    func snapshot(for code: String) -> Snapshot { board.snapshots[code] ?? Snapshot() }

    func add(_ fund: Fund) {
        guard !board.holdings.contains(where: { $0.id == fund.code }) else { return }
        board.holdings.append(Holding(fund: fund))
        persist()
        pendingCodes.insert(fund.code)
        startRefresh(automatic: false)
    }

    @discardableResult
    func savePosition(code: String, shares: Decimal?, cost: Decimal?) -> Bool {
        guard let index = board.holdings.firstIndex(where: { $0.id == code }) else { return false }
        board.holdings[index].shares = shares
        board.holdings[index].costPerShare = cost
        persist()
        return storageWarning == nil
    }

    func setRefreshInterval(_ interval: RefreshInterval) {
        var updated = board
        updated.refreshInterval = interval.rawValue
        do {
            try storage.save(updated)
            board = updated
            storageWarning = nil
            scheduler?.cancel()
            scheduler = nil
            start()
        } catch {
            storageWarning = "刷新间隔保存失败。\(error.localizedDescription)"
        }
    }

    func setAppearanceTheme(_ theme: AppearanceTheme) {
        guard theme != board.appearanceThemeValue else { return }
        var updated = board
        updated.appearanceTheme = theme.rawValue
        do {
            try storage.save(updated)
            board = updated
            storageWarning = nil
            applyAppearanceTheme(theme)
        } catch {
            storageWarning = "主题设置保存失败。\(error.localizedDescription)"
        }
    }

    func reorderVisibleFundColumns(_ columns: [FundTableColumn]) {
        var updated = board
        guard updated.reorderVisibleFundColumns(columns) else { return }
        saveFundColumnSettings(updated)
    }

    func setVisibleFundColumns(_ columns: Set<FundTableColumn>) {
        var updated = board
        updated.setVisibleFundColumns(columns)
        guard updated.hiddenFundColumnIDs != board.hiddenFundColumnIDs else { return }
        saveFundColumnSettings(updated)
    }

    private func saveFundColumnSettings(_ updated: Board) {
        do {
            try storage.save(updated)
            board = updated
            storageWarning = nil
        } catch {
            storageWarning = "列设置保存失败。\(error.localizedDescription)"
        }
    }

    func moveFundDetailTab(_ source: FundDetailTab, to target: FundDetailTab, showsObservation: Bool) {
        var updated = board
        guard updated.moveFundDetailTab(source, to: target, showsObservation: showsObservation) else { return }
        do {
            try storage.save(updated)
            board = updated
            storageWarning = nil
        } catch {
            storageWarning = "基金详情标签顺序保存失败。\(error.localizedDescription)"
        }
    }

    func moveHolding(_ code: String, relativeTo target: String, placement: HoldingPlacement, visibleCodes: Set<String>) {
        var updated = board
        guard updated.moveHolding(code, relativeTo: target, placement: placement, visibleCodes: visibleCodes) else { return }
        do {
            try storage.save(updated)
            board = updated
            storageWarning = nil
        } catch {
            storageWarning = "基金顺序保存失败。\(error.localizedDescription)"
        }
    }

    private func applyAppearanceTheme(_ theme: AppearanceTheme) {
        switch theme {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func record(code: String, change: PositionChange) throws {
        guard let index = board.holdings.firstIndex(where: { $0.id == code }) else { throw PositionError.positionMissing }
        let (holding, record) = try change.applying(to: board.holdings[index])
        var updated = board
        updated.holdings[index] = holding
        var journals = updated.journals ?? [:]
        journals[code, default: []].append(record)
        updated.journals = journals
        try storage.save(updated)
        board = updated
        storageWarning = nil
    }

    func deleteRecord(code: String, recordID: UUID) throws {
        var updated = board
        try updated.deleteJournalRecord(code: code, recordID: recordID)
        try storage.save(updated)
        board = updated
        storageWarning = nil
    }

    func replaceRecord(code: String, recordID: UUID, change: PositionChange) throws {
        var updated = board
        try updated.replaceJournalRecord(code: code, recordID: recordID, with: change)
        try storage.save(updated)
        board = updated
        storageWarning = nil
    }

    func removeFromGroup(_ code: String, group: FundGroup) {
        guard let index = board.holdings.firstIndex(where: { $0.id == code }) else { return }
        let groups = board.holdings[index].groupValues
        guard groups.contains(group) else { return }

        var updated = board
        let remaining = groups.filter { $0 != group }
        updated.holdings[index].groups = remaining.isEmpty ? nil : remaining
        do {
            try storage.save(updated)
            board = updated
            storageWarning = nil
        } catch {
            storageWarning = "移出分组失败。\(error.localizedDescription)"
        }
    }

    func remove(_ code: String) {
        board.holdings.removeAll { $0.id == code }
        board.snapshots.removeValue(forKey: code)
        board.observations?.removeValue(forKey: code)
        board.journals?.removeValue(forKey: code)
        navFailures.remove(code)
        estimateFailures.remove(code)
        navAttempts.removeValue(forKey: code)
        estimateAttempts.removeValue(forKey: code)
        pendingCodes.remove(code)
        persist()
    }

    func prepareImport(_ data: Data) throws -> ImportPreview {
        try ImportPreview(data: data, existing: board.holdings, catalog: catalog)
    }

    func importHoldings(_ preview: ImportPreview) {
        let existing = Set(board.holdings.map(\.id))
        let newHoldings = preview.holdings.filter { !existing.contains($0.id) }
        board.holdings.append(contentsOf: newHoldings)
        for holding in newHoldings {
            if let records = preview.journals[holding.id] {
                var journals = board.journals ?? [:]
                journals[holding.id] = records
                board.journals = journals
            }
            if let observation = preview.observations[holding.id] {
                var observations = board.observations ?? [:]
                observations[holding.id] = observation
                board.observations = observations
            }
        }
        persist()
        pendingCodes.formUnion(newHoldings.map(\.id))
        startRefresh(automatic: false)
        let needsMetadata = newHoldings.contains { $0.fund.kind.isEmpty }
        if needsMetadata { Task { try? await loadCatalog() } }
    }

    struct ObservationImportSummary {
        let added: Int
        let updated: Int
        let groups: [FundGroup]
        let sources: [String]
        let warnings: [String]
    }

    func importObservations(from folder: URL) throws -> ObservationImportSummary {
        let result = try ObservationImport.load(from: folder)
        var added = 0
        var updated = 0
        var importedGroups = Set<FundGroup>()
        for item in result.observations {
            importedGroups.formUnion(item.groups)
            if let index = board.holdings.firstIndex(where: { $0.id == item.fund.code }) {
                board.holdings[index].fund = item.fund
                for group in item.groups {
                    board.holdings[index].add(group)
                }
                updated += 1
            } else {
                board.holdings.append(Holding(fund: item.fund, groups: item.groups))
                added += 1
            }

            var snapshot = snapshot(for: item.fund.code)
            snapshot.mergeHistory(item.history)
            board.snapshots[item.fund.code] = snapshot

            var observations = board.observations ?? [:]
            if let prior = observations[item.fund.code] {
                var metrics = prior.metrics
                for metric in item.observation.metrics {
                    if let index = metrics.firstIndex(where: { $0.key == metric.key }) {
                        metrics[index] = metric
                    } else {
                        metrics.append(metric)
                    }
                }
                observations[item.fund.code] = FundObservation(
                    updatedDay: max(prior.updatedDay, item.observation.updatedDay),
                    source: prior.source == item.observation.source
                        ? prior.source : prior.source + " + " + item.observation.source,
                    metrics: metrics,
                    series: item.observation.series ?? prior.series,
                    macd: item.observation.macd ?? prior.macd,
                    valuation: item.observation.valuation ?? prior.valuation
                )
            } else {
                observations[item.fund.code] = item.observation
            }
            board.observations = observations
            pendingCodes.insert(item.fund.code)
        }
        persist()
        startRefresh(automatic: false)
        let needsMetadata = result.observations.contains { $0.fund.kind.isEmpty }
        if needsMetadata { Task { try? await loadCatalog() } }
        return ObservationImportSummary(
            added: added,
            updated: updated,
            groups: importedGroups.sorted { $0.rawValue < $1.rawValue },
            sources: result.sourceFolders,
            warnings: result.warnings
        )
    }

    func export(full: Bool = true) throws -> Data {
        if full {
            try BoardBackup.export(board)
        } else {
            try BoardBackup.exportPortable(board)
        }
    }

    func restore(_ backup: BoardBackup) throws {
        let restored = backup.restoredBoard(over: board)
        let point = try storage.restore(restored, replacing: board)

        refreshTask?.cancel()
        refreshTask = nil
        scheduler?.cancel()
        scheduler = nil
        refreshing = false
        navFailures.removeAll()
        estimateFailures.removeAll()
        navAttempts.removeAll()
        estimateAttempts.removeAll()
        pendingCodes.removeAll()
        lastCheck = nil
        now = .now
        board = restored
        restorePoint = point
        storageWarning = nil
        applyAppearanceTheme(restored.appearanceThemeValue)
        start()
    }

    private func persist() {
        do {
            try storage.save(board)
            storageWarning = nil
        } catch {
            storageWarning = "写入本机失败，当前修改仍在窗口中。\(error.localizedDescription)"
        }
    }

    func search(_ query: String) async throws -> [Fund] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let watched = board.holdings.map(\.fund).filter { $0.matchesSearch(keyword) }
        if Fund.validCode(keyword), let exact = watched.first(where: { $0.code == keyword }) {
            return [exact]
        }
        if catalog.isEmpty {
            let cached = await Task.detached { [storage] in storage.loadCatalog() }.value
            if !cached.funds.isEmpty {
                catalog = cached.funds
                catalogDate = cached.updated
            }
        }
        let local = searchCatalog(keyword)
        if let catalogDate, now.timeIntervalSince(catalogDate) > 7 * 86_400 {
            Task { try? await loadCatalog() }
        }
        if !local.isEmpty { return mergeSearchResults(watched, local) }
        if catalog.isEmpty {
            // Start the durable offline index when a network search is first used.
            Task { try? await loadCatalog() }
        }
        do {
            let remote = try await api.search(keyword)
            let normalized = remote.filter { !Fund.validCode(keyword) || $0.code == keyword }
            if !normalized.isEmpty || !catalog.isEmpty || !watched.isEmpty {
                return mergeSearchResults(watched, normalized)
            }
        } catch {
            try Task.checkCancellation()
            if !watched.isEmpty { return Array(watched.prefix(35)) }
            if !catalog.isEmpty { throw error }
        }
        try await loadCatalog()
        return searchCatalog(keyword)
    }

    private func searchCatalog(_ keyword: String) -> [Fund] {
        FundSearch.catalogResults(catalog, keyword: keyword)
    }

    private func mergeSearchResults(_ watched: [Fund], _ other: [Fund]) -> [Fund] {
        FundSearch.merge(watched, other)
    }

    private func loadCatalog() async throws {
        if let catalogTask {
            let funds = try await catalogTask.value
            if catalog.isEmpty { applyCatalog(funds) }
            return
        }
        let load = Task.detached { [api, storage] in
            let funds = try await api.catalog()
            try? storage.saveCatalog(funds)
            return funds
        }
        catalogTask = load
        defer { catalogTask = nil }
        applyCatalog(try await load.value)
    }

    private func applyCatalog(_ funds: [Fund]) {
        catalog = funds
        catalogDate = .now
        let byCode = Dictionary(grouping: funds, by: \.code).compactMapValues(\.first)
        var changed = false
        for index in board.holdings.indices where board.holdings[index].fund.kind.isEmpty
            || board.holdings[index].fund.name == board.holdings[index].id {
            if let fund = byCode[board.holdings[index].id] {
                board.holdings[index].fund = fund
                changed = true
            }
        }
        if changed { persist() }
    }

    private struct Job: Sendable {
        let fund: Fund
        let nav: Bool
        let estimate: Bool
    }

    private struct Result: Sendable {
        let code: String
        let requestedNAV: Bool
        let requestedEstimate: Bool
        let history: [NAV]
        let sina: SinaSnapshot?
    }

    private func startRefresh(automatic: Bool) {
        guard !refreshing else { return }
        let date = now
        let canEstimate = MarketClock.canPollEstimates(date)
        let estimateInterval = TimeInterval(board.refreshIntervalValue.rawValue)
        let estimateRetryInterval = max(30, estimateInterval * 4)
        let jobs: [Job] = board.holdings.compactMap { holding in
            let code = holding.id
            let forced = pendingCodes.contains(code)
            guard automatic || forced else { return nil }
            let recent = snapshot(for: code).navCheckedAt ?? .distantPast
            let lastNAV = navAttempts[code] ?? recent
            let nav = forced || date.timeIntervalSince(lastNAV) >= (navFailures.contains(code) ? 240 : 1_200)
            let estimate = !holding.fund.isMoney && (forced || (
                canEstimate && date.timeIntervalSince(estimateAttempts[code] ?? .distantPast) >=
                (estimateFailures.contains(code) ? estimateRetryInterval : estimateInterval - 0.25)
            ))
            guard nav || estimate else { return nil }
            if nav { navAttempts[code] = date }
            if estimate { estimateAttempts[code] = date }
            pendingCodes.remove(code)
            return Job(fund: holding.fund, nav: nav, estimate: estimate)
        }
        guard !jobs.isEmpty else { return }
        refreshing = true
        refreshTask = Task {
            await withTaskGroup(of: Result.self) { group in
                var iterator = jobs.makeIterator()
                for _ in 0..<4 {
                    if let job = iterator.next() { group.addTask { [api] in await Self.fetch(job, using: api) } }
                }
                for await result in group {
                    guard !Task.isCancelled else { return }
                    apply(result)
                    if let job = iterator.next() { group.addTask { [api] in await Self.fetch(job, using: api) } }
                }
            }
            guard !Task.isCancelled else { return }
            refreshTask = nil
            refreshing = false
            lastCheck = .now
            now = .now
            persist()
            if !pendingCodes.isEmpty { startRefresh(automatic: false) }
        }
    }

    private nonisolated static func fetch(_ job: Job, using api: any MarketData) async -> Result {
        async let history = job.nav ? (try? await api.history(for: job.fund, limit: 3)) ?? [] : []
        if job.estimate {
            async let report = try? api.sina(for: job.fund)
            return await Result(code: job.fund.code, requestedNAV: job.nav, requestedEstimate: true,
                                history: history, sina: report)
        }
        let rows = await history
        let backup = job.nav && rows.isEmpty && !job.fund.isMoney ? try? await api.sina(for: job.fund) : nil
        return Result(code: job.fund.code, requestedNAV: job.nav, requestedEstimate: false, history: rows, sina: backup)
    }

    private func apply(_ result: Result) {
        guard board.holdings.contains(where: { $0.id == result.code }) else { return }
        var data = snapshot(for: result.code)
        if result.history.contains(where: { $0.annualizedRate != nil }),
           let index = board.holdings.firstIndex(where: { $0.id == result.code && $0.fund.kind.isEmpty }) {
            board.holdings[index].fund.kind = "货币型"
        }
        let rows = result.history.filter { $0.day <= MarketClock.day() }
        let fallback = result.sina?.nav.flatMap { $0.day <= MarketClock.day() ? $0 : nil }
        data.mergeHistory(rows + (fallback.map { [$0] } ?? []))
        if result.requestedNAV {
            if rows.isEmpty && fallback == nil {
                navFailures.insert(result.code)
            } else {
                data.navCheckedAt = .now
                navFailures.remove(result.code)
            }
        }
        if result.requestedEstimate {
            if let sina = result.sina {
                data.estimateCheckedAt = .now
                data.estimateAvailable = sina.estimate != nil
                if let quote = sina.estimate, quote.timestamp <= Date.now.addingTimeInterval(120) {
                    data.mergeEstimate(quote)
                }
                estimateFailures.remove(result.code)
            } else {
                estimateFailures.insert(result.code)
            }
        }
        board.snapshots[result.code] = data
    }
}
