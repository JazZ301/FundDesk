use funddesk_core::model::Nav;
use funddesk_core::research::{
    decode_accumulated, decode_disclosure, decode_managers, decode_profile, FundHistory,
    HistoryPeriod, StockMarket,
};
use rust_decimal::Decimal;
use serde_json::Value;
use std::path::PathBuf;
use std::str::FromStr;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/http")
        .join(name)
}

fn json(name: &str) -> Value {
    serde_json::from_slice(&std::fs::read(fixture(name)).unwrap()).unwrap()
}

fn dec(text: &str) -> Decimal {
    Decimal::from_str(text).unwrap()
}

fn nav(day: &str, value: &str, rate: Option<&str>, source: &str) -> Nav {
    Nav {
        day: day.to_string(),
        value: dec(value),
        rate: rate.map(dec),
        annualized_rate: None,
        cumulative_value: None,
        source: source.to_string(),
    }
}

#[test]
fn decodes_fund_profile() {
    let profile = decode_profile(&json("profile.json")).unwrap();
    assert_eq!(profile.category.as_deref(), Some("指数型-股票"));
    assert_eq!(profile.company.as_deref(), Some("易方达基金"));
    assert_eq!(profile.manager_names.as_deref(), Some("余海燕,庞亚平"));
    assert_eq!(profile.size, Some(dec("9065849665.31")));
    assert_eq!(profile.cumulative_nav, Some(dec("1.5955")));
    assert_eq!(profile.subscription.as_deref(), Some("开放申购"));
    assert_eq!(profile.redemption.as_deref(), Some("开放赎回"));
    assert_eq!(profile.recent.len(), 4);
    assert_eq!(profile.recent[0].period, "近1月");
    assert_eq!(profile.recent[0].rate, dec("-4.63"));
    assert_eq!(profile.recent[0].rank.as_deref(), Some("1279"));
    assert_eq!(profile.recent[0].sample.as_deref(), Some("5636"));
}

#[test]
fn decodes_disclosure_and_maps_stock_symbols() {
    let disclosure = decode_disclosure(&json("disclosure.json")).unwrap();
    assert_eq!(disclosure.report_day.as_deref(), Some("2026-09-30"));
    assert_eq!(disclosure.target_code.as_deref(), Some("510310"));
    assert_eq!(disclosure.target_name.as_deref(), Some("沪深300ETF易方达"));
    assert!(!disclosure.holdings.is_empty());
    let stock = &disclosure.holdings[0];
    assert_eq!(stock.code, "688825");
    assert_eq!(stock.name, "长鑫科技");
    assert_eq!(stock.kind, "股票");
    assert_eq!(stock.weight, dec("0.05"));
    assert_eq!(stock.stock_market, Some(StockMarket::Shanghai));
    assert_eq!(stock.stock_quote_symbol().as_deref(), Some("sh688825"));
    assert!(stock.change.as_deref().unwrap().contains("个百分点"));
    assert!(!disclosure.needs_stock_market_refresh());
}

#[test]
fn decodes_manager_history() {
    let history =
        decode_managers(Some(&json("managers.json")), Some(&json("tenures.json"))).unwrap();
    assert_eq!(history.current.len(), 2);
    assert_eq!(history.current[0].id, "30066753");
    assert_eq!(history.current[0].name, "余海燕");
    assert_eq!(history.current[0].since.as_deref(), Some("2019-04-25"));
    assert_eq!(history.current[0].education.as_deref(), Some("硕士"));
    assert_eq!(history.tenures.len(), 3);
    assert_eq!(history.tenures[0].rate, Some(dec("7.8739")));
}

#[test]
fn history_returns_compound_and_restart_after_gaps() {
    let history = FundHistory::new(
        vec![
            nav("2026-11-24", "1", None, "天天基金"),
            nav("2026-11-25", "1.02", Some("2"), "天天基金"),
            nav("2026-11-26", "1.0404", Some("2"), "天天基金"),
        ],
        Vec::new(),
    );
    let points = history.returns(HistoryPeriod::SinceStart, false);
    assert_eq!(points.len(), 3);
    assert_eq!(points[0].value, Decimal::ZERO);
    assert!((points[1].value.to_string().parse::<f64>().unwrap() - 2.0).abs() < 1e-9);
    assert!((points[2].value.to_string().parse::<f64>().unwrap() - 4.04).abs() < 1e-9);

    let money = FundHistory::new(
        vec![
            nav("2026-11-24", "0.4", None, "天天基金"),
            nav("2026-11-25", "0.5", None, "天天基金"),
        ],
        Vec::new(),
    );
    let points = money.returns(HistoryPeriod::SinceStart, true);
    assert!((points[1].value.to_string().parse::<f64>().unwrap() - 0.005).abs() < 1e-9);
}

#[test]
fn history_rows_filter_by_calendar_months() {
    let history = FundHistory::new(
        vec![
            nav("2025-10-01", "1", None, "天天基金"),
            nav("2025-11-25", "1.1", None, "天天基金"),
            nav("2026-11-25", "1.2", None, "天天基金"),
        ],
        Vec::new(),
    );
    let rows = history.rows(HistoryPeriod::Year);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].day, "2025-11-25");
}

#[test]
fn merging_recent_prefers_daily_fund_source() {
    let history = FundHistory::new(
        vec![
            nav("2026-11-24", "1", None, "新浪财经"),
            nav("2026-11-25", "1.1", None, "天天基金"),
        ],
        Vec::new(),
    );
    let merged = history.merging_recent(&[
        nav("2026-11-24", "1.05", None, "天天基金"),
        nav("2026-11-25", "1.09", None, "新浪财经"),
    ]);
    let by_day = merged
        .navs
        .iter()
        .map(|nav| (nav.day.as_str(), nav.value))
        .collect::<std::collections::HashMap<_, _>>();
    assert_eq!(by_day["2026-11-24"], dec("1.05"));
    assert_eq!(by_day["2026-11-25"], dec("1.1"));
}

#[test]
fn decodes_accumulated_series_from_script() {
    let script = String::from_utf8(std::fs::read(fixture("pingzhong-small.js")).unwrap()).unwrap();
    let points = decode_accumulated(&script).unwrap();
    assert_eq!(points.len(), 30);
    assert!(points
        .windows(2)
        .all(|pair| pair[0].time.0 <= pair[1].time.0));
    assert!(points.last().unwrap().value > Decimal::ZERO);
}
