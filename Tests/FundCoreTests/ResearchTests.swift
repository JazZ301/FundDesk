import Foundation
import Testing
@testable import FundCore

@Suite("详情、行情与本地记账")
struct ResearchTests {
    private let fund = Fund(code: "007339", name: "易方达沪深300ETF联接C", kind: "指数型-股票")

    @Test("累计收益按涨跌复利而非累计净值比值")
    func performance() throws {
        let rows: [NAV] = [
            NAV(day: "2026-11-19", value: 1, source: "天天基金"),
            NAV(day: "2026-11-20", value: 1.10, rate: 10, source: "天天基金"),
            NAV(day: "2026-11-23", value: 0.97, rate: -10, source: "天天基金")
        ]
        let history = FundHistory(navs: rows)
        #expect(history.returns(in: .month, money: false).map(\.value) == [0, 10, -1])
        let cash = FundHistory(navs: rows.map { NAV(day: $0.day, value: 1, source: "天天基金") })
        #expect(cash.returns(in: .month, money: true).map(\.value) == [0, 0.01, 0.020001])
    }

    @Test("区间基准使用起点当天收盘，不重复计入起点涨跌")
    func returnBoundary() {
        let rows: [NAV] = [
            NAV(day: "2026-10-22", value: 1, source: "天天基金"),
            NAV(day: "2026-10-23", value: 1.10, rate: 10, source: "天天基金"),
            NAV(day: "2026-11-23", value: 1.21, rate: 10, source: "天天基金")
        ]
        #expect(FundHistory(navs: rows).returns(in: .month, money: false).map(\.value) == [0, 10])
    }

    @Test("详情历史合并近期披露，并保留正式来源及累计净值")
    func recentHistory() {
        let base = NAV(day: "2026-11-09", value: 1, source: "天天基金")
        let recent = NAV(day: "2026-11-20", value: 1.6161, cumulativeValue: 1.6161, source: "天天基金")
        let olderSource = NAV(day: "2026-11-20", value: 1.62, source: "新浪财经")
        let result = FundHistory(navs: [base]).mergingRecent([recent, olderSource])
        #expect(result.navs.last?.value == 1.6161)
        #expect(result.accumulated.last?.value == 1.6161)
    }

    @Test("行情资金字段与插件口径一致，周期取对应字段")
    func marketContract() throws {
        let flows = Data(#"{"data":{"klines":["2025-11-24 10:00,1,2,3,4,5","无效"]}}"#.utf8)
        let result = try #require(MarketProviders.decodeFlows(flows).first)
        #expect(result.amount(.main) == 1)
        #expect(result.amount(.huge) == 5)
        #expect(result.amount(.large) == 4)
        let sectors = Data(#"{"data":{"diff":[{"f12":"BK1","f14":"甲","f62":11,"f164":-7},{"f12":"BK2","f14":"乙","f62":2,"f164":10}]}}"#.utf8)
        #expect(try MarketProviders.decodeSectors(sectors, period: .today).first?.code == "BK1")
        #expect(try MarketProviders.decodeSectors(sectors, period: .fiveDays).first?.code == "BK2")
    }

    @Test("披露持仓按市场映射行情代码，旧报告缓存可重读")
    func disclosedStockSymbols() throws {
        let disclosure = Data("""
        {"Datas":{"fundStocks":[
            {"GPDM":"600030","GPJC":"沪股","JZBL":"1.0","NEWTEXCH":"1"},
            {"GPDM":"000776","GPJC":"深股","JZBL":"1.0","NEWTEXCH":"0"},
            {"GPDM":"920045","GPJC":"北证","JZBL":"1.0","NEWTEXCH":"0","TEXCH":"4"},
            {"GPDM":"00700","GPJC":"港股","JZBL":"1.0","NEWTEXCH":"116"},
            {"GPDM":"BRK-B","GPJC":"美股","JZBL":"1.0","NEWTEXCH":"106"},
            {"GPDM":"600030","GPJC":"未识别市场","JZBL":"1.0","NEWTEXCH":"999"}
        ],"fundboods":[{"ZQDM":"600030","ZQMC":"债券","ZJZBL":"1.0"}]}}
        """.utf8)
        let report = try MarketProviders.decodeDisclosure(disclosure)
        #expect(report.holdings.map(\.stockQuoteSymbol) == ["sh600030", "sz000776", "bj920045", "hk00700", "usBRK.B", nil, nil])
        #expect(!report.needsStockMarketRefresh)

        let old = Data(#"{"holdings":[{"code":"600030","name":"沪股","type":"股票","weight":1}]}"#.utf8)
        let cached = try JSONDecoder().decode(FundDisclosure.self, from: old)
        #expect(cached.needsStockMarketRefresh)
        #expect(cached.holdings.first?.stockQuoteSymbol == nil)
    }

    @Test("个股报价按请求代码匹配并保留各市场实际时间")
    func holdingStockQuotes() throws {
        func row(_ symbol: String, price: String, time: String, rate: String) -> String {
            var fields = Array(repeating: "", count: 34)
            fields[3] = price
            fields[30] = time
            fields[32] = rate
            return "v_\(symbol)=\"\(fields.joined(separator: "~"))\";"
        }
        let payload = [
            row("sh600030", price: "25.12", time: "20261124101101", rate: "-0.55"),
            row("hk00700", price: "347.40", time: "2026/11/24 09:56:03", rate: "0.99"),
            row("usAAPL", price: "349.08", time: "2026-11-23 16:00:01", rate: "1.90"),
            row("sz000776", price: "0", time: "20261124101101", rate: "0.00"),
            row("sh601688", price: "23", time: "20261124101101", rate: "2.00")
        ].joined(separator: "\n")
        let quotes = MarketProviders.decodeStockQuotes(Data(payload.utf8), symbols: ["sh600030", "hk00700", "usAAPL", "sz000776"])
        #expect(quotes.count == 3)
        #expect(quotes["sh600030"]?.rate == Decimal(string: "-0.55"))
        #expect(quotes["sh600030"]?.timestamp == MarketClock.timestamp(day: "2026-11-24", time: "10:11:01"))
        #expect(quotes["hk00700"]?.timestamp == MarketClock.timestamp(day: "2026-11-24", time: "09:56:03"))
        #expect(quotes["usAAPL"]?.timestamp == MarketClock.timestamp(day: "2026-11-24", time: "05:00:01"))
    }

    @Test("指数分时按交易所时段压缩午休并保留本地时间")
    func indexTradingSessions() throws {
        let china = MarketIndex.shanghaiComposite.tradingSession
        let open = try #require(china.timestamp(day: "2026-11-23", time: "09:30"))
        let morning = try #require(china.timestamp(day: "2026-11-23", time: "11:30"))
        let noon = try #require(china.timestamp(day: "2026-11-23", time: "12:00"))
        let afternoon = try #require(china.timestamp(day: "2026-11-23", time: "13:00"))
        let close = try #require(china.timestamp(day: "2026-11-23", time: "15:00"))
        #expect(china.position(for: open) == 0)
        #expect(china.position(for: morning) == 120)
        #expect(china.position(for: noon) == nil)
        #expect(china.position(for: afternoon) == 120)
        #expect(china.position(for: close) == 240)
        #expect(china.totalMinutes == 240)
        #expect(china.axisMarks[2].title == "11:30/13:00")

        let hongKong = MarketIndex.hangSeng.tradingSession
        #expect(hongKong.timeZoneIdentifier == "Asia/Hong_Kong")
        #expect(hongKong.totalMinutes == 330)
        #expect(hongKong.axisMarks.contains { $0.title == "12:00/13:00" })

        let us = MarketIndex.nasdaq.tradingSession
        let usOpen = try #require(us.timestamp(day: "2026-11-20", time: "09:30"))
        let usClose = try #require(us.timestamp(day: "2026-11-20", time: "16:00"))
        #expect(us.timeZoneIdentifier == "America/New_York")
        #expect(us.position(for: usOpen) == 0)
        #expect(us.position(for: usClose) == 390)
    }

    @Test("指数分时保留昨收基准并兼容旧缓存")
    func indexTrendBaseline() throws {
        let legacy = Data(#"{"source":"旧缓存","points":[]}"#.utf8)
        let oldTrend = try JSONDecoder().decode(IndexTrend.self, from: legacy)
        #expect(oldTrend.previousClose == nil)
        #expect(oldTrend.volumes == nil)

        let yahoo = Data("""
        {"chart":{"result":[{"meta":{"symbol":"^IXIC","previousClose":100},
          "timestamp":[1795185000],"indicators":{"quote":[{"close":[101],"volume":[1234]}]}}]}}
        """.utf8)
        let trend = try MarketProviders.decodeUSChartTrend(yahoo, symbol: "^IXIC")
        #expect(trend.previousClose == 100)
        #expect(trend.points.first?.value == 101)
        #expect(trend.volumes?.first?.value == 1234)

        let tencent = Data("""
        {"data":{"sh000001":{"data":{"date":"20261123","data":["0930 3503.52 6734931","0931 3504.00 24703575"]},
          "qt":{"sh000001":["1","上证指数","000001","3519.74","3533.79","3503.52"]}}}}
        """.utf8)
        let mainland = try MarketProviders.decodeTencentIndexTrend(tencent, index: .shanghaiComposite)
        #expect(mainland.previousClose == Decimal(string: "3533.79"))
        #expect(mainland.points.first?.value == Decimal(string: "3503.52"))
        #expect(mainland.volumes?.map(\.value) == [6_734_931, 17_968_644])
    }

    @Test("报告期、直持、目标ETF及债券基金字段独立保留")
    func holdingsContract() throws {
        let data = Data("""
        {"Expansion":"2026-09-30","Datas":{"ETFCODE":"510310","ETFSHORTNAME":"沪深300ETF易方达","fundStocks":[
          {"GPDM":"300308","GPJC":"中际旭创","JZBL":"0.02","PCTNVCHGTYPE":"减持","PCTNVCHG":"0.01"}],
          "fundboods":[{"ZQDM":"019835","ZQMC":"26国债09","ZJZBL":"5.33"}],
          "fundfofs":[{"TZJJDM":"377240","TZJJMC":"摩根新兴动力混合A","ZJZBL":"11.56"}]}}
        """.utf8)
        let report = try MarketProviders.decodeDisclosure(data)
        #expect(report.reportDay == "2026-09-30")
        #expect(report.targetCode == "510310")
        #expect(report.holdings.map(\.type) == ["股票", "债券", "基金"])
        #expect(report.holdings.map(\.weight) == [0.02, 5.33, 11.56])
    }

    @Test("流水修改加权成本、赎回收益及本地备份")
    func journal() throws {
        let day = "2026-11-23"
        let now = try #require(MarketClock.timestamp(day: day))
        let original = Holding(fund: fund, shares: 100, costPerShare: 1)
        let (bought, entry) = try PositionChange(action: .buy, day: day, shares: 100, price: 2, fee: 10)
            .applying(to: original, now: now)
        #expect(bought.costPerShare == 1.55)
        let (sold, sale) = try PositionChange(action: .sell, day: day, shares: 50, price: 2, fee: 2)
            .applying(to: bought, now: now)
        #expect(sold.shares == 150)
        #expect(sale.realized == 20.5)
        #expect(throws: PositionError.self) {
            try PositionChange(action: .sell, day: day, shares: 151, price: 2).applying(to: sold, now: now)
        }
        let data = try ImportPreview.export([sold], journals: [fund.code: [entry, sale]])
        let result = try ImportPreview(data: data, existing: [], catalog: [])
        #expect(result.holdings == [sold])
        #expect(result.journals[fund.code]?.count == 2)
        #expect(try ImportPreview(data: data, existing: [sold], catalog: []).journals.isEmpty)
    }

    @Test("修改或删除流水会按剩余流水重新计算持仓")
    func journalReplayAndEdit() throws {
        let day = "2026-11-23"
        let now = try #require(MarketClock.timestamp(day: day))
        let original = Holding(fund: fund, shares: 100, costPerShare: 1)
        let (bought, buy) = try PositionChange(action: .buy, day: day, shares: 100, price: 2, fee: 10)
            .applying(to: original, now: now)
        let (sold, sale) = try PositionChange(action: .sell, day: day, shares: 50, price: 2, fee: 2)
            .applying(to: bought, now: now)
        var board = Board()
        board.holdings = [sold]
        board.journals = [fund.code: [buy, sale]]

        let inferred = try #require(PositionJournalReplay.inferBase(current: sold, records: [buy, sale]))
        #expect(inferred.shares == 100)
        #expect(inferred.costPerShare == 1)

        try board.replaceJournalRecord(
            code: fund.code, recordID: buy.id,
            with: PositionChange(action: .buy, day: day, shares: 50, price: 2, fee: 0)
        )
        #expect(board.holdings.first?.shares == 100)
        let revisedSale = try #require(board.journals?[fund.code]?.last)
        #expect(board.journals?[fund.code]?.first?.id != buy.id)

        try board.deleteJournalRecord(code: fund.code, recordID: revisedSale.id)
        #expect(board.holdings.first?.shares == 150)
        let revisedBuy = try #require(board.journals?[fund.code]?.first)
        try board.deleteJournalRecord(code: fund.code, recordID: revisedBuy.id)
        #expect(board.holdings.first?.shares == 100)
        #expect(board.holdings.first?.costPerShare == 1)
        #expect(board.journals?[fund.code] == nil)
    }

    @Test("期货分时横轴使用整点刻度而不是均匀索引")
    func futuresAxisTicks() throws {
        let start = try #require(MarketClock.timestamp(day: "2026-11-25", time: "07:00"))
        let times = (0...252).map { start.addingTimeInterval(Double($0) * 60) }
        let ticks = FuturesAxis.tickIndices(times: times, visible: 0...252)
        let formatter = DateFormatter()
        formatter.timeZone = MarketClock.calendar.timeZone
        formatter.dateFormat = "HH:mm"
        #expect(ticks == [0, 60, 120, 180, 252])
        #expect(ticks.map { formatter.string(from: times[$0]) } == [
            "07:00", "08:00", "09:00", "10:00", "11:12"
        ])
    }

    @Test("期货分时横轴避免最新时间与整点刻度重叠")
    func futuresAxisAvoidsCrowdedEndLabel() throws {
        let start = try #require(MarketClock.timestamp(day: "2026-11-25", time: "07:00"))
        let times = (0...311).map { start.addingTimeInterval(Double($0) * 60) }
        let ticks = FuturesAxis.tickIndices(times: times, visible: 0...311)
        let formatter = DateFormatter()
        formatter.timeZone = MarketClock.calendar.timeZone
        formatter.dateFormat = "HH:mm"
        #expect(ticks == [0, 60, 120, 180, 240, 311])
        #expect(ticks.map { formatter.string(from: times[$0]) } == [
            "07:00", "08:00", "09:00", "10:00", "11:00", "12:11"
        ])
    }

    @Test("CSV 保留前导零、顺序和重叠分类，兼容无分类旧表")
    func csv() throws {
        let titled = Fund(code: "007339", name: "基金, \"联接\"")
        let positions = [
            Holding(fund: titled, shares: 222.25, costPerShare: 1.25, groups: [.red, .macd]),
            Holding(fund: Fund(code: "000001", name: "观察自选"), groups: [.macd]),
            Holding(fund: Fund(code: "000198", name: "普通自选"), shares: 0)
        ]
        let exported = HoldingCSV.export(positions)
        #expect(String(decoding: exported, as: UTF8.self).contains("全部自选|我的持仓|红利观察|MACD 观察"))
        let preview = try ImportPreview(data: exported, existing: [], catalog: [])
        #expect(preview.holdings == positions)
        #expect(preview.invalid == 0)
        let data = Data("基金代码,持有份额,单位成本\r\n198,23,1\r\n007339,abc,1".utf8)
        let reimport = try ImportPreview(data: data, existing: [], catalog: [])
        #expect(reimport.holdings.first?.id == "000198")
        #expect(reimport.holdings.first?.groupValues.isEmpty == true)
        #expect(reimport.invalid == 1)
    }

    @Test("真实详情数据与正式净值交叉核对", .enabled(if: ProcessInfo.processInfo.environment["FUND_LIVE_TEST"] == "1"))
    func liveResearch() async throws {
        let provider = MarketProviders()
        async let history = provider.fundHistory(fund)
        async let official = provider.history(for: fund, limit: 3)
        async let profile = provider.fundProfile(code: fund.code)
        async let disclosure = provider.fundDisclosure(code: fund.code)
        async let people = provider.fundManagers(code: fund.code)
        async let sina = provider.sina(for: fund)
        let (full, close, stats, report, managers, intra) = try await (history, official, profile, disclosure, people, sina)
        #expect(full.navs.count > 90)
        let currentClose = try #require(close.max(by: { $0.day < $1.day }))
        #expect(full.navs.first(where: { $0.day == currentClose.day })?.value == currentClose.value)
        #expect(!stats.recent.isEmpty)
        #expect(report.reportDay != nil)
        #expect(report.targetCode == "510310")
        #expect(!report.holdings.isEmpty)
        #expect(!managers.current.isEmpty)
        #expect(intra.estimate == intra.series.last)
    }

    @Test("真实七指数、两市成交额和四类板块", .enabled(if: ProcessInfo.processInfo.environment["FUND_LIVE_TEST"] == "1"))
    func liveMarket() async throws {
        let provider = MarketProviders()
        async let quotes = provider.indices()
        async let trend = provider.indexTrend(.shanghaiComposite)
        async let us = provider.indexTrend(.nasdaq)
        async let breadth = provider.marketBreadth()
        let (all, points, usPoints, two) = try await (quotes, trend, us, breadth)
        #expect(Set(all.map(\.index)) == Set(MarketIndex.displayOrder))
        #expect(all.allSatisfy { !$0.timestamp.isEmpty })
        #expect(points.points.count > 1)
        #expect(points.previousClose != nil)
        #expect(points.volumes?.isEmpty == false)
        #expect(usPoints.points.count > 1)
        #expect(usPoints.previousClose != nil)
        #expect(usPoints.volumes?.isEmpty == false)
        if let quote = all.first(where: { $0.index == .shanghaiComposite }) {
            #expect(points.previousClose == quote.value - quote.change)
        }
        if let quote = all.first(where: { $0.index == .nasdaq }) {
            #expect(usPoints.previousClose == quote.value - quote.change)
        }
        #expect(two.turnover > 0)
        for (index, category) in SectorCategory.allCases.enumerated() {
            let periods = SectorPeriod.allCases
            let ordered = try await provider.sectorFlows(category, period: periods[index % periods.count])
            #expect(!ordered.isEmpty)
            if let first = ordered.first, let last = ordered.last { #expect(first.amount >= last.amount) }
        }
    }

    @Test("沪深成交额降级时仅沿用同交易日涨跌家数和原时间")
    func preserveMarketCounts() throws {
        let morning = try #require(MarketClock.timestamp(day: "2026-11-23", time: "10:00"))
        let later = try #require(MarketClock.timestamp(day: "2026-11-23", time: "10:15"))
        let followingDay = try #require(MarketClock.timestamp(day: "2026-11-24", time: "10:00"))
        let full = MarketBreadth(turnover: 200, advancing: 100, flat: 20, declining: 150, asOf: morning, source: "东方财富")
        let partial = MarketBreadth(turnover: 300, advancing: nil, flat: nil, declining: nil, asOf: later, source: "腾讯行情")
        let merged = partial.preservingCounts(from: full)
        #expect(merged.turnover == 300)
        #expect(merged.asOf == later)
        #expect(merged.source == "腾讯行情")
        #expect(merged.advancing == 100)
        #expect(merged.flat == 20)
        #expect(merged.declining == 150)
        #expect(merged.cachedCountsAsOf == morning)
        #expect(partial.preservingCounts(from: merged).countsAsOf == morning)

        let fresh = MarketBreadth(turnover: 310, advancing: 200, flat: 10, declining: 70, asOf: later, source: "东方财富")
        #expect(fresh.preservingCounts(from: merged).advancing == 200)
        #expect(fresh.preservingCounts(from: merged).cachedCountsAsOf == nil)

        let next = MarketBreadth(turnover: 210, advancing: nil, flat: nil, declining: nil, asOf: followingDay, source: "腾讯行情")
        #expect(!next.preservingCounts(from: merged).hasCounts)
        let undated = MarketBreadth(turnover: 400, advancing: nil, flat: nil, declining: nil, asOf: nil, source: "腾讯行情")
        #expect(!undated.preservingCounts(from: merged).hasCounts)

        let historical = Data(#"{"turnover":200,"advancing":100,"flat":20,"declining":150,"source":"东方财富"}"#.utf8)
        let oldArchive = try JSONDecoder().decode(MarketBreadth.self, from: historical)
        #expect(oldArchive.hasCounts)
        #expect(!partial.preservingCounts(from: oldArchive).hasCounts)
    }

    @Test("分时接口故障后按真实日线格式降级")
    func fallbackFlow() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlowFallbackFixture.self]
        let provider = MarketProviders(session: URLSession(configuration: config))
        let series = try await provider.marketFlows()
        #expect(!series.intraday)
        #expect(series.points.last?.main == -52_087_752_448)
    }

    @Test("真实沪深资金流向分时或日线", .enabled(if: ProcessInfo.processInfo.environment["FUND_LIVE_TEST"] == "1"))
    func liveFlow() async throws {
        let series = try await MarketProviders().marketFlows()
        #expect(!series.points.isEmpty)
    }

}


private final class FlowFallbackFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let fallback = url.path.contains("daykline")
        let response = HTTPURLResponse(url: url, statusCode: fallback ? 200 : 503,
                                       httpVersion: nil, headerFields: nil)!
        let body = #"{"data":{"klines":["2025-11-20,-52087752448.0,48811556864.0,3276197888.0,-34806542336.0,-17281210112.0"]}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
