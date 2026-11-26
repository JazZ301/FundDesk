import Foundation
import Testing
@testable import FundCore

@Suite("本地观察数据导入")
struct ObservationImportTests {
    @Test("旧持仓没有分类字段时仍可读取")
    func legacyHolding() throws {
        let data = Data("""
        {
          "holdings": [{
            "fund": {"code":"007339","name":"易方达沪深300ETF联接C","kind":"指数型-股票","initials":"","pinyin":""},
            "shares": 100
          }],
          "snapshots": {}
        }
        """.utf8)
        let board = try JSONDecoder().decode(Board.self, from: data)
        #expect(board.holdings.first?.groups == nil)

        let grouped = Holding(
            fund: Fund(code: "008163", name: "南方红利低波"),
            groups: [.macd, .red]
        )
        let reopened = try JSONDecoder().decode(Holding.self, from: JSONEncoder().encode(grouped))
        #expect(reopened.groupValues == [.macd, .red])

        let observation = FundObservation(
            updatedDay: "2026-11-20",
            source: "本地",
            metrics: [ObservationMetric(key: "pe", label: "PE", value: "9.50")],
            series: [ObservationPoint(day: "2026-11-20", value: 1.23)],
            valuation: RedValuation(
                total: 2, maximum: 8, level: "持有区", advice: "以持有为主",
                anchors: [ValuationAnchor(key: "pe_pct", name: "PE 分位", value: "80.9%",
                                          score: -1, label: ">80% 减仓区")]
            )
        )
        let backup = try ImportPreview.export(
            [grouped],
            observations: [grouped.id: observation]
        )
        let preview = try ImportPreview(data: backup, existing: [], catalog: [])
        #expect(preview.holdings.first?.groupValues == [.macd, .red])
        #expect(preview.observations[grouped.id] == observation)
    }

    @Test("桌面两个文件夹合并分类并保留重叠基金")
    func folderImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let macdData = root.appendingPathComponent("macd/data")
        let red = root.appendingPathComponent("red")
        try FileManager.default.createDirectory(at: macdData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: red, withIntermediateDirectories: true)

        let macd = """
        [{
          "code":"007339","name":"易方达沪深300ETF联接C","ftype":"指数型-股票",
          "track":"沪深300","pattern":"区间整体上移","ret1y":12.5,"vol":20,"r2":0.42,
          "mdd":-18.25,"pos":0.65,"legs":4,"dur_med":38,"amp_med":9.5,
          "nav_last":["2026-11-20",1.6161],
          "bt_all":{"strat":30,"hold":25,"n":8,"win":62.5,"pf":1.8,"mdd":-12}
        },{
          "code":"008163","name":"南方标普红利低波50ETF联接A","ftype":"指数型-股票",
          "nav_last":["2026-11-20",1.1364]
        }]
        """
        try Data(macd.utf8).write(to: macdData.appendingPathComponent("analysis.json"))

        let redData = """
        {
          "generated_at":"2026-11-22 20:11:15",
          "funds":[{
            "code":"008163","name":"南方标普红利低波50ETF联接A","track":"红利低波",
            "anchor_name":"红利低波","anchor_mode":"proxy","nav":1.1364,"nav_date":"2026-11-20",
            "anchor_valuation":{"pe":9.5,"pe_pct":80.9,"pb":0.95,"pb_pct":71.8,"dividend":4.4},
            "eval":{"spread":2.7,"level":{"label":"持有区","advice":"以持有为主"}},
            "rs":{"diff":1.2,"signal":{"label":"黄灯"}},
            "stats":{"1y":{"ret":5.1},"6m":{"ret":2.2},"3m":{"ret":1.1}}
          },{
            "code":"022951","name":"华泰柏瑞中证红利低波ETF联接Y","track":"红利低波",
            "anchor_name":"红利低波","anchor_mode":"exact","nav":1.7306,"nav_date":"2026-11-20"
          }]
        }
        """
        try Data(redData.utf8).write(to: red.appendingPathComponent(".cache.json"))

        let result = try ObservationImport.load(from: root)
        #expect(result.sourceFolders == ["macd", "red"])
        #expect(result.observations.count == 3)
        let overlap = try #require(result.observations.first { $0.fund.code == "008163" })
        #expect(overlap.groups == [.macd, .red])
        #expect(overlap.history.last?.day == "2026-11-20")
        #expect(overlap.observation.metrics.contains { $0.key == "dividend" && $0.value == "4.40%" })
        let redOnly = try #require(result.observations.first { $0.fund.code == "022951" })
        #expect(redOnly.groups == [.red])
    }

    @Test("MACD 金叉死叉及滚动分位与布林带")
    func analysis() throws {
        let start = try #require(MarketClock.timestamp(day: "2025-01-01"))
        let points = (0..<320).map { index -> ObservationPoint in
            let date = MarketClock.calendar.date(byAdding: .day, value: index, to: start)!
            let wave = sin(Double(index) / 8) * 0.08
            let trend = Double(index) * 0.002
            return ObservationPoint(
                day: MarketClock.day(date),
                value: Decimal(1 + wave + trend)
            )
        }
        let macd = try #require(ObservationAnalysis.macd(points))
        #expect(macd.points.count == points.count)
        #expect(macd.points.contains { $0.crossing != 0 })
        #expect(macd.points.last?.histogram != 0)

        let bands = try #require(ObservationAnalysis.bands(points, displayLimit: 250))
        #expect(bands.points.count == 250)
        #expect(bands.points.last?.movingAverage != nil)
        #expect(bands.points.last?.bollingerUpper != nil)
        #expect((0...100).contains(bands.points.last!.percentile))
        #expect(bands.boxHigh > bands.boxLow)
    }

    @Test("优先读取 MACD HTML 的适配度并导入累计净值图序列")
    func htmlImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let macd = root.appendingPathComponent("macd")
        let fundFolder = macd.appendingPathComponent("data/fund")
        try FileManager.default.createDirectory(at: fundFolder, withIntermediateDirectories: true)

        let html = """
        <script>
        let DATA = [{"code":"007339","name":"易方达沪深300ETF联接C","ftype":"指数型-股票",
          "nav_last":["2026-11-20",1.6161],"vol":16.4,"ret1y":-10.5,"g":{
          "score":72.6,"grade":"A","reasons":[],"pass_gate":true}}];
        let NAV_END = "2026-11-20";
        </script>
        """
        try Data(html.utf8).write(to: macd.appendingPathComponent("基金_MACD战法适配度.html"))
        let script = """
        var Data_netWorthTrend = [{"x":1795104000000,"y":1.6161,"equityReturn":-0.74}];
        var Data_ACWorthTrend = [[1795104000000,1.6161]];
        """
        try Data(script.utf8).write(to: fundFolder.appendingPathComponent("007339.js"))

        let result = try ObservationImport.load(from: root)
        let item = try #require(result.observations.first)
        #expect(item.observation.macd?.grade == "A")
        #expect(item.observation.macd?.score == Decimal(string: "72.6"))
        #expect(item.observation.series?.last?.day == "2026-11-20")
    }
}
