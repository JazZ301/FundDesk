import Foundation
import Testing
@testable import FundCore

@Suite("外盘期货行情")
struct FuturesMarketTests {
    @Test("报价按品种解析，涨跌按供应商参考价计算")
    func quoteFields() throws {
        let script = """
        var hq_str_hf_CHA50CFD="";
        var hq_str_hf_XAU="3624.70,3534.640,3624.70,3625.05,3636.86,3554.42,21:30:00,3534.64,3559.83,0,0,0,2026-11-23,伦敦金（现货黄金）";
        var hq_str_hf_CL="81.613,,81.610,81.630,83.950,81.550,21:30:51,83.410,83.670,0,7,8,2026-11-23,纽约原油,0";
        """
        let quotes = try MarketProviders.decodeFuturesQuotes(Data(script.utf8))
        #expect(quotes.map(\.instrument) == [.wtiOil, .spotGold])
        let oil = try #require(quotes.first)
        #expect(oil.price == decimal("81.613"))
        #expect(oil.open == decimal("83.670"))
        #expect(oil.high == decimal("83.950"))
        #expect(oil.low == decimal("81.550"))
        #expect(oil.openInterest == nil)
        #expect(oil.change == decimal("-1.797"))
        #expect(oil.rate.map { $0 < -2 && $0 > -3 } == true)
        #expect(oil.time == MarketClock.timestamp(day: "2026-11-23", time: "21:30:51"))
        #expect(quotes.last?.change == decimal("90.06"))
    }

    @Test("夜盘首行含交易日元数据，走势使用实际日期")
    func overnightTrend() throws {
        let response = """
        {"result":{"status":{"code":0},"data":{"minLine_1d":[
          ["2026-11-24","12648.000","sgxq","","17:00","12638.360","1113","1012175","12637.855","2026-11-23 17:00:00"],
          ["00:00","12642.830","146","1012175","12646.173","2026-11-24 00:00:00"],
          ["00:00","12643.000","150","1012175","12646.173","2026-11-24 00:00:00"],
          ["00:01","--","0","0","0","2026-11-24 00:01:00"]
        ]}}}
        """
        let trend = try MarketProviders.decodeFuturesIntraday(Data(response.utf8))
        #expect(trend.reference == 12648)
        #expect(trend.points.count == 2)
        #expect(trend.points.first?.time == MarketClock.timestamp(day: "2026-11-23", time: "17:00"))
        #expect(trend.points.last?.time == MarketClock.timestamp(day: "2026-11-24"))
        #expect(trend.points.last?.value == 12643)
    }

    @Test("日 K 去重并按交易日排序，周 K 与月 K 聚合完整 OHLC")
    func candlePeriods() throws {
        let data = Data("""
        {"result":{"data":[
          {"date":"2026-12-01","open":"6","high":"9","low":"5","close":"8"},
          {"date":"2026-11-27","open":"2","high":"7","low":"1","close":"6"},
          {"date":"2026-11-30","open":"6","high":"10","low":"4","close":"7"}
        ]}}
        """.utf8)
        let daily = try MarketProviders.decodeFuturesDaily(data)
        let week = FuturesCandle.aggregate(daily, period: .weekly)
        let month = FuturesCandle.aggregate(daily, period: .monthly)
        #expect(daily.count == 3)
        #expect(week.count == 2)
        #expect(week.last?.open == 6 && week.last?.high == 10 && week.last?.low == 4 && week.last?.close == 8)
        #expect(month.count == 2)
        #expect(month.first?.open == 2 && month.first?.close == 7)
    }

    @Test("五日分钟兼容两类首行，并拒绝过期的历史存根")
    func fiveMinuteSessions() throws {
        let rows = (19...23).map { day in
            day == 19 ? #"[[ "2026-11-19", "1.5", "07:00", "2", "0"], ["07:01", "3", "0"]]"#
                : "[[\"2026-11-\(day)\",\"07:00\",\"4\",\"0\"],[\"07:01\",\"5\",\"0\"]]"
        }
        let json = "{\"result\":{\"data\":{\"GC\":[" + rows.joined(separator: ",") + "]}}}"
        let data = Data(json.utf8)
        let date = try #require(MarketClock.timestamp(day: "2026-11-23"))
        let series = try MarketProviders.decodeFuturesFiveMinutes(data, instrument: .gold, quoteDay: date)
        #expect(series.sessions.first?.prices == [2, 3])
        #expect(series.sessions.last?.prices == [4, 5])
        #expect(series.reference == 1.5)
        #expect(throws: FeedError.self) {
            try MarketProviders.decodeFuturesFiveMinutes(data, instrument: .gold, quoteDay: date.addingTimeInterval(86_400))
        }
    }

    @Test("分时横轴覆盖完整交易时段，跨夜品种按前一交易日开盘")
    func sessionWindows() throws {
        func stamp(_ day: String, _ time: String) throws -> Date {
            try #require(MarketClock.timestamp(day: day, time: time))
        }
        func window(_ instrument: FuturesInstrument, at date: Date) throws -> DateInterval {
            try #require(instrument.session.window(containing: date))
        }

        // 冬令时：CME 18:00–17:00 ET 对应北京时间 07:00 至次日 06:00。
        let midSession = try stamp("2026-11-25", "13:06")
        let gold = try window(.gold, at: midSession)
        #expect(gold.start == (try stamp("2026-11-25", "07:00")))
        #expect(gold.end == (try stamp("2026-11-26", "06:00")))
        let progress = midSession.timeIntervalSince(gold.start) / gold.duration
        #expect(abs(progress - 0.2652) < 0.001)

        // 夏令时：同一交易所窗口整体提前一小时。
        let summerGold = try window(.gold, at: stamp("2026-07-15", "13:00"))
        #expect(summerGold.start == (try stamp("2026-07-15", "06:00")))
        #expect(summerGold.end == (try stamp("2026-07-16", "05:00")))

        // A50 的交易日从上一日 17:00 开始，次日 16:30 结束。
        let a50 = try window(.chinaA50, at: stamp("2026-11-25", "13:06"))
        #expect(a50.start == (try stamp("2026-11-24", "17:00")))
        #expect(a50.end == (try stamp("2026-11-25", "16:30")))

        // 伦铜 01:00–19:00 伦敦时间，收盘落在北京时间次日凌晨。
        let copper = try window(.londonCopper, at: stamp("2026-11-25", "13:06"))
        #expect(copper.start == (try stamp("2026-11-25", "09:00")))
        #expect(copper.end == (try stamp("2026-11-26", "03:00")))
    }

    @Test("真实新浪报价和分时覆盖首批 11 个品种",
          .enabled(if: ProcessInfo.processInfo.environment["FUND_LIVE_TEST"] == "1"))
    func liveFutures() async throws {
        let provider = MarketProviders()
        let quotes = try await provider.futuresQuotes()
        #expect(quotes.map(\.instrument) == FuturesInstrument.allCases)
        #expect(quotes.allSatisfy { $0.rate != nil })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for quote in quotes {
                group.addTask {
                    let trend = try await provider.futuresIntraday(quote.instrument)
                    #expect(trend.points.count > 1)
                    #expect(trend.reference != nil)
                    let bars = try await provider.futuresDaily(quote.instrument)
                    #expect(bars.count > 90)
                    let fiveDays = try await provider.futuresFiveSessions(quote.instrument, quoteDay: quote.time)
                    #expect(fiveDays.sessions.count == 5)
                }
            }
            try await group.waitForAll()
        }
    }
}
