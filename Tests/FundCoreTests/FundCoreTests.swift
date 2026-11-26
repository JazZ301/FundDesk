import Foundation
import Testing
@testable import FundCore

@Suite("基金数据和本地恢复")
struct FundCoreTests {
    private let fund = Fund(code: "007339", name: "沪深300ETF联接C", kind: "指数型")
    private let base = NAV(day: "2026-11-20", value: Decimal(string: "1.6161")!, source: "天天基金")

    @Test("按上次正式净值计算且排除旧估值")
    func valuation() throws {
        let time = try #require(MarketClock.timestamp(day: "2026-11-23", time: "10:00"))
        let recent = Estimate(timestamp: time, marketDay: "2026-11-23", baseDay: base.day,
                              value: Decimal(string: "1.6008")!, percent: -1)
        var snapshot = Snapshot()
        snapshot.mergeHistory([base])
        snapshot.mergeEstimate(recent)
        let holding = Holding(fund: fund, shares: 10_000, costPerShare: Decimal(string: "1.5"))
        var board = Board()
        board.holdings = [holding]
        board.snapshots[fund.code] = snapshot
        let metrics = FundMetrics(holding: holding, snapshot: snapshot, now: time)
        #expect(metrics.value == 16_161)
        #expect(metrics.profit == 1_161)
        #expect(metrics.estimatedDayProfit == -153)
        #expect(Portfolio(board: board, now: time).estimatedCoverage == 100)
        #expect(FundMetrics(holding: holding, snapshot: snapshot, now: time.addingTimeInterval(2_000)).estimatedDayProfit == nil)

        snapshot.mergeHistory([NAV(day: "2026-11-23", value: 1.61, rate: -0.5, source: "天天基金")])
        #expect(snapshot.effectiveEstimate(now: time) == nil)
        let published = FundMetrics(holding: holding, snapshot: snapshot, now: time).publishedDayProfit
        #expect(published == Decimal(string: "-80.805"))
        snapshot.mergeHistory([base, NAV(day: "2026-11-23", value: 1.60, source: "新浪财经")])
        #expect(snapshot.nav?.value == Decimal(string: "1.61"))
    }

    @Test("同日正式收益逐只接替估算并解释未覆盖持仓")
    func dayProfitTransition() throws {
        let time = try #require(MarketClock.timestamp(day: "2026-11-23", time: "15:00"))
        let now = time.addingTimeInterval(3 * 3_600)
        let day = MarketClock.day(now)
        let holdings = (1...5).map { index in
            Holding(fund: Fund(code: String(format: "%06d", index), name: "验收基金"), shares: 100)
        }
        var board = Board()
        board.holdings = holdings
        let previous = NAV(day: base.day, value: 1, source: "天天基金")
        for holding in holdings {
            board.snapshots[holding.id, default: Snapshot()].mergeHistory([previous])
        }
        let estimates = [
            Estimate(timestamp: time, marketDay: day, baseDay: base.day, value: 1.05, percent: 5),
            Estimate(timestamp: time, marketDay: day, baseDay: base.day, value: 1.02, percent: 2),
            Estimate(timestamp: time, marketDay: base.day, baseDay: base.day, value: 1.08, percent: 8),
            Estimate(timestamp: time, marketDay: day, baseDay: "2026-11-19", value: 1.04, percent: 4)
        ]
        for (holding, estimate) in zip(holdings, estimates) {
            board.snapshots[holding.id, default: Snapshot()].mergeEstimate(estimate)
        }
        board.snapshots[holdings[4].id, default: Snapshot()].mergeHistory([
            NAV(day: day, value: 1.01, source: "新浪财经")
        ])

        let estimated = Portfolio(board: board, now: now)
        #expect(estimated.dayProfit == 7)
        #expect(estimated.coveredDayCount == 2)

        board.snapshots[holdings[0].id, default: Snapshot()].mergeHistory([
            NAV(day: day, value: 1.06, rate: 6, source: "天天基金")
        ])
        let mixed = Portfolio(board: board, now: now)
        #expect(mixed.day == day)
        #expect(mixed.dayProfit == 8)
        #expect(mixed.publishedDayProfit == 6)
        #expect(mixed.estimatedDayProfit == 2)
        #expect(mixed.coveredDayCount == 2)
        #expect(mixed.holdingCount == 5)
        #expect(mixed.dayProfitExclusions == [
            .differentMarketDay: 1, .mismatchedBase: 1, .incompletePublishedNAV: 1
        ])

        board.snapshots[holdings[1].id, default: Snapshot()].mergeHistory([
            NAV(day: day, value: 0.99, rate: -1, source: "天天基金")
        ])
        let published = Portfolio(board: board, now: now)
        #expect(published.dayProfit == 5)
        #expect(published.publishedDayCount == 2)
        #expect(published.estimatedDayCount == 0)
        #expect(Portfolio(board: board, now: now.addingTimeInterval(7 * 3_600)).dayProfit == nil)
    }

    @Test("迁移备份保留分类、流水和配置，跳过行情历史，完整恢复点可回退")
    func portableBackupRestore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = BoardStorage(directory: dir)
        var backupBoard = Board()
        let initial = Holding(fund: fund, shares: 100, costPerShare: 1, groups: [.macd, .red])
        let (holding, record) = try PositionChange(action: .buy, day: base.day, shares: 20, price: 2)
            .applying(to: initial)
        backupBoard.holdings = [holding]
        backupBoard.journals = [fund.code: [record]]
        backupBoard.observations = [fund.code: FundObservation(
            updatedDay: base.day, source: "验收",
            metrics: [ObservationMetric(key: "pe", label: "PE 分位", value: "32%")],
            series: [ObservationPoint(day: base.day, value: 2.7123)],
            macd: MACDRating(score: 84, grade: "A", recommendation: "验收"),
            valuation: RedValuation(total: 1, maximum: 4, level: "验收", advice: "", anchors: [])
        )]
        backupBoard.snapshots[fund.code, default: Snapshot()].mergeHistory([base])
        backupBoard.appearanceTheme = AppearanceTheme.dark.rawValue
        backupBoard.refreshInterval = RefreshInterval.sixtySeconds.rawValue
        backupBoard.fundColumnOrder = ["code", "name"]
        backupBoard.hiddenFundColumnIDs = ["nav"]
        backupBoard.fundDetailTabOrder = ["observation", "history"]

        let data = try BoardBackup.exportPortable(backupBoard)
        let backup = try BoardBackup(data: data)
        #expect(backup.includesSettings)
        #expect(!backup.includesSnapshots)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"series\""))
        #expect(!String(decoding: data, as: UTF8.self).contains("\"history\":"))
        var expected = backupBoard
        expected.snapshots = [:]
        expected.observations?[fund.code]?.series = nil
        let emptyStorage = BoardStorage(directory: dir.appendingPathComponent("empty"))
        try emptyStorage.restore(backup.restoredBoard(over: Board()), replacing: Board())
        #expect(emptyStorage.open().board == expected)

        var current = backupBoard
        current.holdings = [initial, Holding(fund: Fund(code: "000198", name: "验收自选"))]
        try storage.save(current)
        let merge = try ImportPreview(data: data, existing: current.holdings, catalog: [])
        #expect(merge.duplicates == 1)
        #expect(merge.holdings.isEmpty)
        let point = try storage.restore(backup.restoredBoard(over: current), replacing: current)
        #expect(storage.open().board == expected)
        #expect(storage.latestRestorePoint()?.resolvingSymlinksInPath() == point.resolvingSymlinksInPath())
        let local = try BoardBackup(data: Data(contentsOf: point))
        #expect(local.includesSnapshots)
        let rollback = local.restoredBoard(over: expected)
        #expect(rollback == current)
        try storage.restore(rollback, replacing: expected)
        #expect(storage.open().board == current)
    }

    @Test("旧版看板和备份中的提醒字段可安全忽略")
    func retiredFundAlerts() throws {
        let legacyBoard = """
        {"holdings":[],"snapshots":{},"refreshInterval":30,"appearanceTheme":"dark",
         "alerts":{"navEnabled":true,"movementThreshold":2,"desktopEnabled":true}}
        """
        let board = try JSONDecoder().decode(Board.self, from: Data(legacyBoard.utf8))
        #expect(board.refreshIntervalValue == .thirtySeconds)
        #expect(board.appearanceThemeValue == .dark)
        for version in 2...4 {
            let backup = try BoardBackup(data: Data("""
            {"version":\(version),"board":\(legacyBoard)}
            """.utf8))
            #expect(backup.restoredBoard(over: Board()) == board)
        }
        let reexported = try BoardBackup.export(board)
        #expect(!String(decoding: reexported, as: UTF8.self).contains("\"alerts\""))
    }

    @Test("旧备份还原持仓并沿用本机配置，重复代码不可恢复")
    func legacyBackupRestore() throws {
        let restoredHolding = Holding(fund: fund, shares: 200, costPerShare: 2)
        var current = Board()
        current.appearanceTheme = AppearanceTheme.light.rawValue
        current.refreshInterval = RefreshInterval.thirtySeconds.rawValue
        current.snapshots[fund.code, default: Snapshot()].mergeHistory([base])
        let backup = try BoardBackup(data: ImportPreview.export([restoredHolding]))
        let restored = backup.restoredBoard(over: current)
        #expect(!backup.includesSettings)
        #expect(restored.holdings == [restoredHolding])
        #expect(restored.snapshots == current.snapshots)
        #expect(restored.appearanceTheme == current.appearanceTheme)
        #expect(restored.refreshInterval == current.refreshInterval)
        #expect(throws: BoardBackup.RestoreError.invalidHoldings) {
            try BoardBackup(data: ImportPreview.export([restoredHolding, restoredHolding]))
        }
    }

    @Test("货币基金按万份收益解析且可走备用历史")
    func moneyHistory() throws {
        let data = Data("""
        var Data_millionCopiesIncome = [[1795276800000,0.2159]];
        var Data_sevenDaysYearIncome = [[1795276800000,0.791]];
        """.utf8)
        let rows = try MarketProviders.decodeHistoryScript(data, money: true, limit: 3)
        #expect(rows.first?.day == "2026-11-22")
        #expect(rows.first?.annualizedRate == Decimal(string: "0.791"))
        var snapshot = Snapshot()
        snapshot.mergeHistory(rows)
        let money = Holding(fund: Fund(code: "000198", name: "余额宝", kind: "货币型"), shares: 100)
        #expect(FundMetrics(holding: money, snapshot: snapshot).value == 100)
    }

    @Test("跨境凌晨回报标为上一标的市场交易日")
    func crossBorder() throws {
        let data = Data("""
        {"result":{"status":{"code":0},"data":{"worth":"5.2047","worth_date":"20261119","worth_rate":-0.0189,"networth":[{"symbol":"050025","min_time":"05:04:00","pre_date":"2026-11-21","pre_nav2":"5.0103","growthrate2":"-0.037354"}]}}}
        """.utf8)
        let result = try MarketProviders.decodeSina(data, fund: Fund(code: "050025", name: "标普500", kind: "指数型-海外股票"))
        #expect(result.estimate?.marketDay == "2026-11-20")
        #expect(result.nav?.day == "2026-11-19")
    }

    @Test("插件持仓导入保留前导零并去重")
    func importPositions() throws {
        let data = Data("""
        {"fundListGroup":[{"name":"默认","funds":[{"code":"007339","num":"100.25","cost":"1.23"}]}],
        "fundListM":[{"code":"007339"},{"code":198}],"ext_token":"unused"}
        """.utf8)
        let preview = try ImportPreview(data: data, existing: [], catalog: [fund])
        #expect(preview.holdings.map(\.id) == ["007339", "000198"])
        #expect(preview.duplicates == 1)
        #expect(preview.holdings[0].shares == Decimal(string: "100.25"))
        let roundtrip = try ImportPreview(data: ImportPreview.export(preview.holdings), existing: [], catalog: [])
        #expect(roundtrip.holdings == preview.holdings)
    }

    @Test("文件损坏后可恢复上一个有效版本")
    func diskFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = BoardStorage(directory: dir)
        var board = Board()
        board.holdings = [Holding(fund: fund)]
        try storage.save(board)
        try storage.save(Board())
        try Data("damaged".utf8).write(to: dir.appendingPathComponent("board.json"))
        let opened = storage.open()
        #expect(opened.recovered)
        #expect(opened.board == board)
    }

    @Test("旧数据默认十秒自动刷新且设置可持久化")
    func refreshIntervalMigration() throws {
        let legacy = Data(#"{"holdings":[],"snapshots":{}}"#.utf8)
        var board = try JSONDecoder().decode(Board.self, from: legacy)
        #expect(board.refreshIntervalValue == .tenSeconds)

        board.refreshInterval = RefreshInterval.thirtySeconds.rawValue
        let reopened = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
        #expect(reopened.refreshIntervalValue == .thirtySeconds)

        board.refreshInterval = 17
        #expect(board.refreshIntervalValue == .tenSeconds)
    }

    @Test("旧看板采用新默认列序，自定义列序可重新读取")
    func fundColumnOrderMigration() throws {
        let legacy = Data(#"{"holdings":[],"snapshots":{}}"#.utf8)
        var board = try JSONDecoder().decode(Board.self, from: legacy)
        let defaultOrder: [FundTableColumn] = [
            .name, .estimateRate, .dayProfit, .value, .profit, .profitRate, .estimateTime,
            .code, .nav, .navDate, .navRate, .estimate
        ]
        #expect(board.fundColumns == defaultOrder)
        #expect(board.visibleFundColumns == defaultOrder)

        board.fundColumnOrder = ["value", "unknownColumn", "code", "value"]
        let reopened = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
        #expect(reopened.fundColumns == [.value, .code] + defaultOrder.filter { $0 != .value && $0 != .code })
    }

    @Test("完整备份包含行情和观察序列并可离线恢复")
    func fullBackupRestore() throws {
        var board = Board()
        board.holdings = [Holding(fund: fund, shares: 100, costPerShare: 1, groups: [.macd])]
        board.snapshots[fund.code, default: Snapshot()].mergeHistory([base])
        board.observations = [fund.code: FundObservation(
            updatedDay: base.day, source: "验收",
            metrics: [ObservationMetric(key: "pe", label: "PE 分位", value: "32%")],
            series: [ObservationPoint(day: base.day, value: 2.7123)],
            macd: MACDRating(score: 84, grade: "A", recommendation: "验收")
        )]
        board.appearanceTheme = AppearanceTheme.dark.rawValue
        board.refreshInterval = RefreshInterval.thirtySeconds.rawValue

        let data = try BoardBackup.export(board)
        let backup = try BoardBackup(data: data)
        #expect(backup.includesSettings)
        #expect(backup.includesSnapshots)
        #expect(String(decoding: data, as: UTF8.self).contains("\"series\""))
        #expect(String(decoding: data, as: UTF8.self).contains("\"history\":"))
        #expect(backup.restoredBoard(over: Board()) == board)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = BoardStorage(directory: dir)
        try storage.restore(backup.restoredBoard(over: Board()), replacing: Board())
        #expect(storage.open().board == board)
    }

    @Test("基金详情标签顺序可保存，并保留隐藏观察标签的位置")
    func fundDetailTabOrder() throws {
        var board = try JSONDecoder().decode(Board.self, from: Data(#"{"holdings":[],"snapshots":{}}"#.utf8))
        #expect(board.fundDetailTabs == [.estimate, .history, .returns, .holdings, .profile, .observation])
        let movedObservation = board.moveFundDetailTab(.observation, to: .history, showsObservation: true)
        let movedProfile = board.moveFundDetailTab(.profile, to: .estimate, showsObservation: false)
        let targetedHiddenTab = board.moveFundDetailTab(.profile, to: .observation, showsObservation: false)
        #expect(movedObservation)
        #expect(movedProfile)
        #expect(!targetedHiddenTab)

        let reopened = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
        #expect(reopened.fundDetailTabs == [.profile, .observation, .estimate, .history, .returns, .holdings])

        let madeObservationFirst = board.moveFundDetailTab(.observation, to: .profile, showsObservation: true)
        #expect(madeObservationFirst)
        #expect(board.visibleFundDetailTabs(showsObservation: true).first == .observation)
        #expect(board.visibleFundDetailTabs(showsObservation: false).first == .profile)
    }

    @Test("隐藏列可保存，并保留其在列顺序中的位置")
    func fundColumnVisibility() throws {
        var board = Board()
        board.hiddenFundColumnIDs = ["name", "dayProfit", "unknownColumn", "dayProfit"]
        let original = board.fundColumns
        let visible = original.filter { $0 != .dayProfit }
        #expect(board.visibleFundColumns == visible)

        board.setVisibleFundColumns(Set(visible))
        let reordered = Array(visible.reversed())
        let didReorder = board.reorderVisibleFundColumns(reordered)
        let acceptedPartialOrder = board.reorderVisibleFundColumns([.name])
        #expect(didReorder)
        #expect(!acceptedPartialOrder)
        let reopened = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
        #expect(reopened.visibleFundColumns == reordered)
        #expect(reopened.fundColumns.firstIndex(of: .dayProfit) == original.firstIndex(of: .dayProfit))

        board.setVisibleFundColumns([])
        #expect(board.visibleFundColumns == [.name])
        board.setVisibleFundColumns(Set(original))
        #expect(board.visibleFundColumns == reopened.fundColumns)
        #expect(board.hiddenFundColumnIDs == nil)
    }

    @Test("上下移动基金保留隐藏行的位置和持仓数据")
    func holdingOrder() throws {
        let codes = ["000001", "000002", "000003", "000004", "000005"]
        let original = codes.map { Holding(fund: Fund(code: $0, name: $0), shares: 100, costPerShare: 1) }
        let visible: Set<String> = ["000001", "000003", "000005"]
        var board = Board()
        board.holdings = original

        _ = board.moveHolding("000005", relativeTo: "000001", placement: .before, visibleCodes: visible)
        #expect(board.holdings == [original[4], original[1], original[0], original[3], original[2]])
        _ = board.moveHolding("000005", relativeTo: "000003", placement: .after, visibleCodes: visible)
        #expect(board.holdings == [original[0], original[1], original[2], original[3], original[4]])

        let unchanged = board.moveHolding("000003", relativeTo: "000005", placement: .before, visibleCodes: visible)
        let hiddenTarget = board.moveHolding("000003", relativeTo: "000004", placement: .after, visibleCodes: visible)
        #expect(!unchanged)
        #expect(!hiddenTarget)
        _ = board.moveHolding("000001", relativeTo: "000005", placement: .after, visibleCodes: Set(codes))
        let reopened = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
        #expect(reopened.holdings == Array(original.dropFirst()) + [original[0]])
    }

    @Test("旧数据默认跟随系统且黑白主题可持久化")
    func appearanceThemeMigration() throws {
        let legacy = Data(#"{"holdings":[],"snapshots":{}}"#.utf8)
        var board = try JSONDecoder().decode(Board.self, from: legacy)
        #expect(board.appearanceThemeValue == .system)

        board.appearanceTheme = AppearanceTheme.dark.rawValue
        let reopened = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
        #expect(reopened.appearanceThemeValue == .dark)

        board.appearanceTheme = "sepia"
        #expect(board.appearanceThemeValue == .system)
    }

    @Test("主接口失败后解析备用净值数据")
    func historyFallsBack() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let provider = MarketProviders(session: URLSession(configuration: config))
        let history = try await provider.history(for: fund, limit: 3)
        #expect(history.first?.day == base.day)
        #expect(history.first?.value == base.value)
    }

    @Test("搜索合并保留命中结果，并对代码去重和限流")
    func fundSearchMerge() {
        let fund = Fund(code: "110022", name: "易方达消费行业股票", kind: "股票型")
        let catalog = [
            fund,
            Fund(code: "110023", name: "易方达消费行业股票 C", kind: "股票型"),
            Fund(code: "007339", name: "易方达沪深300ETF联接C", kind: "指数型")
        ]

        let local = FundSearch.catalogResults(catalog, keyword: "110022")
        #expect(local.map(\.code) == ["110022"])
        #expect(FundSearch.merge([], local).map(\.code) == ["110022"])
        #expect(FundSearch.merge([], catalog).count == 3)
        #expect(FundSearch.merge([fund], catalog).map(\.code) == ["110022", "110023", "007339"])

        let named = FundSearch.catalogResults(catalog, keyword: "易方达消费")
        #expect(named.map(\.code) == ["110022", "110023"])
        #expect(FundSearch.merge([], named).count == 2)

        let many = (1...40).map { Fund(code: String(format: "%06d", $0), name: "验收基金 \($0)") }
        let limited = FundSearch.merge([many[0]], many)
        #expect(limited.count == FundSearch.resultLimit)
        #expect(Set(limited.map(\.code)).count == FundSearch.resultLimit)
    }

    @Test("估值健康汇总区分正常、超时、刷新失败和暂无")
    func estimateHealthSummary() throws {
        let now = try #require(MarketClock.timestamp(day: "2026-11-25", time: "10:00"))
        let fresh = try #require(MarketClock.timestamp(day: "2026-11-25", time: "09:55"))
        let stale = try #require(MarketClock.timestamp(day: "2026-11-25", time: "09:20"))
        let funds = (1...5).map { Fund(code: String(format: "%06d", $0), name: "估值基金\($0)") }
        var board = Board()
        board.holdings = funds.map { Holding(fund: $0, shares: 100, costPerShare: 1) }
        board.holdings[4].fund.kind = "货币型"

        board.snapshots[funds[0].id] = Snapshot()
        board.snapshots[funds[0].id]?.mergeEstimate(Estimate(
            timestamp: fresh, marketDay: MarketClock.day(now), baseDay: nil, value: 1.01, percent: 1
        ))
        board.snapshots[funds[1].id] = Snapshot()
        board.snapshots[funds[1].id]?.mergeEstimate(Estimate(
            timestamp: stale, marketDay: MarketClock.day(now), baseDay: nil, value: 1.01, percent: 1
        ))

        let health = EstimateHealth(board: board, failures: [funds[2].id], now: now)
        #expect(health.freshCount == 1)
        #expect(health.staleCount == 1)
        #expect(health.failedCount == 1)
        #expect(health.missingCount == 1)
        #expect(health.issueCount == 2)
        #expect(health.hasIssue)
    }

    @Test("历史净值降级标记可编码，并兼容旧缓存")
    func fundHistoryDegradation() throws {
        let degraded = FundHistory(
            navs: [], degraded: true, degradationNote: "历史净值接口暂时不可用，当前显示最近披露数据。"
        ).mergingRecent([base])
        #expect(degraded.isDegraded)
        #expect(degraded.degradationNote == "历史净值接口暂时不可用，当前显示最近披露数据。")

        let reopened = try JSONDecoder().decode(FundHistory.self, from: JSONEncoder().encode(degraded))
        #expect(reopened.isDegraded)

        let legacy = try JSONDecoder().decode(
            FundHistory.self, from: Data(#"{"navs":[],"accumulated":[]}"#.utf8)
        )
        #expect(!legacy.isDegraded)
    }

    @Test("真实基金目录和净值", .enabled(if: ProcessInfo.processInfo.environment["FUND_LIVE_TEST"] == "1"))
    func liveProvider() async throws {
        let provider = MarketProviders()
        async let catalog = provider.catalog()
        async let search = provider.search(fund.code)
        async let history = provider.history(for: fund, limit: 3)
        async let sina = provider.sina(for: fund)
        let (funds, results, rows, report) = try await (catalog, search, history, sina)
        #expect(funds.count > 1_000)
        #expect(results.first?.code == fund.code)
        #expect(rows.count >= 2)
        #expect(report.nav != nil)
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let fallback = url.host == "fund.eastmoney.com"
        let response = HTTPURLResponse(url: url, statusCode: fallback ? 200 : 503, httpVersion: nil, headerFields: nil)!
        let fixture = #"var Data_netWorthTrend = [{"x":1795104000000,"y":1.6161,"equityReturn":-0.74}];"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
