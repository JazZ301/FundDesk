use funddesk_core::clock::timestamp;
use funddesk_core::market::{
    decode_breadth, decode_catalog, decode_custom_futures_quotes, decode_flows,
    decode_futures_daily, decode_futures_five_minutes, decode_futures_intraday,
    decode_futures_quotes, decode_history, decode_index_daily, decode_indices, decode_search,
    decode_sectors, decode_sina, decode_sina_breadth, decode_stock_quotes, decode_tencent_daily,
    index_session, CandlePeriod, FuturesCandle, FuturesInstrument, MarketIndex, SectorCategory,
    SectorPeriod,
};
use funddesk_core::model::Fund;
use funddesk_core::swift::SwiftDate;
use rust_decimal::Decimal;
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;
use std::str::FromStr;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/http")
        .join(name)
}

fn read(name: &str) -> Vec<u8> {
    std::fs::read(fixture(name)).unwrap()
}

fn json(name: &str) -> Value {
    serde_json::from_slice(&read(name)).unwrap()
}

fn dec(text: &str) -> Decimal {
    Decimal::from_str(text).unwrap()
}

#[test]
fn decodes_fund_catalog_and_search() {
    let funds = decode_catalog(&read("catalog.js")).unwrap();
    assert!(funds.len() >= 23);
    let fund = funds.iter().find(|fund| fund.code == "007339").unwrap();
    assert_eq!(fund.name, "易方达沪深300ETF联接C");
    assert!(fund.kind.contains("指数"));
    assert!(!fund.pinyin.is_empty());

    let results = decode_search(&json("search.json")).unwrap();
    assert_eq!(results[0].code, "007339");
    assert_eq!(results[0].name, "易方达沪深300ETF联接C");
    assert!(!results[0].kind.is_empty());
}

#[test]
fn decodes_eastmoney_history() {
    let navs = decode_history(&json("history.json"), false).unwrap();
    assert_eq!(navs.len(), 20);
    let latest = &navs[0];
    assert_eq!(latest.day, "2026-11-25");
    assert_eq!(latest.value, dec("1.5947"));
    assert_eq!(latest.rate, Some(dec("-1.58")));
    assert_eq!(latest.cumulative_value, Some(dec("1.5947")));
    assert!(latest.annualized_rate.is_none());
    assert_eq!(latest.source, "天天基金");
}

#[test]
fn decodes_index_daily_klines() {
    let value: Value = serde_json::from_str(
        r#"{"data":{"klines":[
            "2026-11-21,4500.00,4520.50,4530.00,4480.00,1000,2000,1.00,0.50,0.10,0.20",
            "2026-11-20,4480.00,4498.20,4505.00,4470.00,900,1800,0.90,0.40,0.08,0.18"
        ]}}"#,
    )
    .unwrap();
    let rows = decode_index_daily(&value).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].day, "2026-11-20");
    assert_eq!(rows[0].value, dec("4498.20"));
    assert_eq!(rows[1].value, dec("4520.50"));
    assert_eq!(rows[1].source, "东方财富指数");
}

#[test]
fn decodes_tencent_index_daily() {
    let value: Value = serde_json::from_str(
        r#"{"data":{"sh000300":{"day":[
            ["2026-11-20","4480.00","4498.20","4505.00","4470.00","900"],
            ["2026-11-21","4500.00","4520.50","4530.00","4480.00","1000"]
        ]}}}"#,
    )
    .unwrap();
    let rows = decode_tencent_daily(&value, "sh000300").unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].value, dec("4498.20"));
    assert_eq!(rows[1].value, dec("4520.50"));
    assert_eq!(rows[1].source, "腾讯指数");
}

#[test]
fn decodes_sina_nav_and_intraday_estimates() {
    let fund = Fund {
        code: "007339".to_string(),
        name: "易方达沪深300ETF联接C".to_string(),
        kind: "指数型".to_string(),
        initials: String::new(),
        pinyin: String::new(),
    };
    let snapshot = decode_sina(&json("sina.json"), &fund).unwrap();
    let nav = snapshot.nav.unwrap();
    assert_eq!(nav.day, "2026-11-25");
    assert_eq!(nav.value, dec("1.5947"));
    let rate = nav.rate.unwrap();
    assert!((rate.to_string().parse::<f64>().unwrap() + 1.5799543294452).abs() < 1e-9);

    assert_eq!(snapshot.series.len(), 12);
    let estimate = snapshot.estimate.unwrap();
    assert_eq!(estimate.market_day, "2026-11-26");
    assert_eq!(estimate.base_day.as_deref(), Some("2026-11-25"));
    assert_eq!(estimate.value, dec("1.5910"));
    assert_eq!(estimate.percent, dec("-0.2347"));
    let instant = estimate.timestamp.to_utc().unwrap();
    assert_eq!(instant, timestamp("2026-11-26", "16:04:00").unwrap());
}

#[test]
fn decodes_seven_index_quotes() {
    let bytes = read("indices.txt");
    let text = String::from_utf8_lossy(&bytes);
    let quotes = decode_indices(&text).unwrap();
    assert_eq!(quotes.len(), 7);
    let sh = quotes
        .iter()
        .find(|quote| quote.index == MarketIndex::ShanghaiComposite)
        .unwrap();
    assert_eq!(sh.value, dec("3476.88"));
    assert_eq!(sh.change, dec("0.41"));
    assert_eq!(sh.rate, dec("0.01"));
    assert_eq!(sh.timestamp, "2026-11-26 16:14:27");
    assert_eq!(sh.turnover, Some(dec("613332810452")));
    assert!(quotes
        .iter()
        .any(|quote| quote.index == MarketIndex::HangSeng));
}

#[test]
fn decodes_stock_quotes() {
    let symbols = ["sh600519", "sz000001", "hk00700", "usAAPL"]
        .into_iter()
        .map(str::to_string)
        .collect::<HashSet<_>>();
    let quotes = decode_stock_quotes(&String::from_utf8_lossy(&read("stocks.txt")), &symbols);
    assert_eq!(quotes.len(), 4);
    let moutai = &quotes["sh600519"];
    assert_eq!(moutai.rate, dec("-0.40"));
    assert_eq!(
        moutai.time.to_utc().unwrap(),
        timestamp("2026-11-26", "16:15:00").unwrap()
    );
}

#[test]
fn decodes_futures_quotes() {
    let quotes = decode_futures_quotes(&String::from_utf8_lossy(&read("futures.txt"))).unwrap();
    assert!(quotes.len() >= 10);
    let gold = quotes
        .iter()
        .find(|quote| quote.instrument == FuturesInstrument::Gold)
        .unwrap();
    assert_eq!(gold.price, dec("3591.616"));
    assert_eq!(gold.reference, Some(dec("3564.600")));
    assert_eq!(gold.high, Some(dec("3634.700")));
    assert_eq!(gold.low, Some(dec("3578.800")));
    assert_eq!(
        gold.time.to_utc().unwrap(),
        timestamp("2026-11-26", "20:53:16").unwrap()
    );
    assert!(gold.rate().unwrap() > Decimal::ZERO);
}

#[test]
fn decodes_futures_intraday_and_history() {
    let intraday = decode_futures_intraday(&json("futures-intraday.json")).unwrap();
    assert_eq!(intraday.reference, Some(dec("3564.600")));
    assert_eq!(intraday.points.len(), 25);
    assert_eq!(intraday.points[0].value, dec("3614.145"));
    assert_eq!(intraday.averages.as_ref().unwrap().len(), 25);

    let daily = decode_futures_daily(&json("futures-daily.json")).unwrap();
    assert_eq!(daily.len(), 40);
    assert_eq!(daily.last().unwrap().close, dec("3593.500"));

    let five = decode_futures_five_minutes(
        &json("futures-five.json"),
        FuturesInstrument::Gold,
        Some(timestamp("2026-11-21", "12:00").unwrap()),
    )
    .unwrap();
    assert!(five.is_minute_series);
    assert_eq!(five.sessions.len(), 5);
    assert_eq!(five.reference, Some(dec("3501.000")));
    assert_eq!(five.sessions[0].prices.len(), 3);
    assert_eq!(five.sessions[4].prices.len(), 2);
    assert_eq!(five.sessions[4].prices[0], dec("3508.8"));
}

#[test]
fn decodes_breadth_flows_and_sectors() {
    let breadth = decode_breadth(&json("breadth.json"), "东方财富").unwrap();
    assert_eq!(breadth.turnover, dec("1346332810453"));
    assert_eq!(breadth.advancing, Some(2100));
    assert_eq!(breadth.flat, Some(150));
    assert_eq!(breadth.declining, Some(1800));
    assert!(breadth.as_of.is_some());
    assert!(breadth.has_counts());

    let flows = decode_flows(&json("flows.json"), true).unwrap();
    assert_eq!(flows.len(), 3);
    assert_eq!(flows[0].main, dec("-100"));
    assert_eq!(flows[2].huge, dec("-20"));
    assert_eq!(
        flows[0].time.to_utc().unwrap(),
        timestamp("2026-11-26", "09:31").unwrap()
    );

    let sectors = decode_sectors(&json("sectors.json"), SectorPeriod::Today).unwrap();
    assert_eq!(sectors.len(), 128);
    assert_eq!(sectors[0].code, "BK0459");
    assert_eq!(sectors[0].amount, dec("4527079936"));
    assert!(sectors[0].amount >= sectors[1].amount);

    let style = decode_sectors(&json("sectors.json"), SectorPeriod::FiveDays);
    assert!(style.is_err(), "缺少 f164 时应报错");
    assert_eq!(SectorCategory::Industry.provider_code(), "m:90+s:4");
}

#[test]
fn decodes_sina_market_breadth_backup() {
    let value: Value = serde_json::from_str(
        r#"[
            {"symbol":"sh600000","trade":"8.98","changepercent":"1.23","amount":1200000000,"ticktime":"15:00:03"},
            {"symbol":"sh600001","trade":"5.00","changepercent":"0.000","amount":800000000,"ticktime":"15:00:01"},
            {"symbol":"sz000001","trade":"11.20","changepercent":"-0.88","amount":1500000000,"ticktime":"15:00:02"},
            {"symbol":"sz000002","trade":"0.000","changepercent":"-100.000","amount":0,"ticktime":"15:00:00"},
            {"symbol":"bj920000","trade":"8.98","changepercent":"5.00","amount":900000000,"ticktime":"15:30:01"}
        ]"#,
    )
    .unwrap();
    let breadth = decode_sina_breadth(&value).unwrap();
    assert_eq!(breadth.turnover, dec("3500000000"));
    assert_eq!(breadth.advancing, Some(1));
    assert_eq!(breadth.flat, Some(1));
    assert_eq!(breadth.declining, Some(1));
    assert_eq!(breadth.source, "新浪财经 · 全市场");
    assert!(breadth.as_of.is_some());
}

#[test]
fn decodes_custom_futures_quotes_from_sina() {
    let text = concat!(
        "var hq_str_hf_NG=\"3.617,,3.621,3.622,3.696,3.577,22:59:34,3.658,3.675,0,2,7,2026-11-26,美国天然气,0\";\n",
        "var hq_str_hf_HO=\"3.700,,3.698,3.700,3.709,3.623,22:59:25,3.653,3.653,0,2,1,2026-11-26,美燃油,0\";"
    );
    let quotes = decode_custom_futures_quotes(text, &["NG".to_string()]);
    assert_eq!(quotes.len(), 1);
    let gas = &quotes[0];
    assert_eq!(gas.symbol, "NG");
    assert_eq!(gas.name, "美国天然气");
    assert_eq!(gas.price, dec("3.617"));
    assert_eq!(gas.reference, Some(dec("3.658")));
    assert_eq!(gas.open, Some(dec("3.675")));
    assert_eq!(gas.high, Some(dec("3.696")));
    assert_eq!(gas.low, Some(dec("3.577")));
    assert!(gas.open_interest.is_none());
    assert_eq!(
        gas.time.to_utc().unwrap(),
        timestamp("2026-11-26", "22:59:34").unwrap()
    );
}

#[test]
fn index_sessions_map_lunch_and_axes() {
    let mainland = index_session(MarketIndex::ShanghaiComposite);
    assert_eq!(mainland.total_minutes(), 240);
    assert_eq!(
        mainland.position(timestamp("2026-11-26", "10:00").unwrap()),
        Some(30)
    );
    assert_eq!(
        mainland.position(timestamp("2026-11-26", "13:30").unwrap()),
        Some(150)
    );
    assert_eq!(
        mainland.position(timestamp("2026-11-26", "12:00").unwrap()),
        None
    );
    assert_eq!(mainland.axis_marks[2].title, "11:30/13:00");

    let us = index_session(MarketIndex::Sp500);
    assert_eq!(us.total_minutes(), 390);
    assert_eq!(us.time_zone, "America/New_York");
    assert_eq!(
        us.timestamp("2026-11-26", "09:30").unwrap(),
        timestamp("2026-11-26", "22:30").unwrap()
    );
}

#[test]
fn aggregates_futures_candles_by_week_and_month() {
    let candle = |day_text: &str, open: &str, high: &str, low: &str, close: &str| FuturesCandle {
        day: SwiftDate::from_utc(timestamp(day_text, "00:00").unwrap()),
        open: dec(open),
        high: dec(high),
        low: dec(low),
        close: dec(close),
    };
    let daily = vec![
        candle("2026-11-23", "10", "12", "9", "11"),
        candle("2026-11-24", "11", "15", "10", "14"),
        candle("2026-11-30", "14", "16", "13", "15"),
    ];
    let weekly = FuturesCandle::aggregate(&daily, CandlePeriod::Weekly);
    assert_eq!(weekly.len(), 2);
    assert_eq!(weekly[0].open, dec("10"));
    assert_eq!(weekly[0].high, dec("15"));
    assert_eq!(weekly[0].close, dec("14"));
    let monthly = FuturesCandle::aggregate(&daily, CandlePeriod::Monthly);
    assert_eq!(monthly.len(), 1);
    assert_eq!(monthly[0].high, dec("16"));
    assert_eq!(monthly[0].low, dec("9"));
}
