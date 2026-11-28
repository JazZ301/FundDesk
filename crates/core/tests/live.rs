use funddesk_core::market::{FuturesInstrument, MarketIndex, SectorCategory, SectorPeriod};
use funddesk_core::model::{Fund, FundGroup, ObservationPoint};
use funddesk_core::observation::{self, ObservationInput};
use funddesk_core::sources::Sources;
use funddesk_core::MarketClient;
use std::path::Path;

fn client() -> MarketClient {
    let path = std::env::var("FUND_DESK_SOURCES_FILE")
        .expect("请用 FUND_DESK_SOURCES_FILE 指向数据源配置");
    let sources = Sources::load(Path::new(&path)).expect("读取数据源配置");
    MarketClient::with_sources(sources).expect("创建行情客户端")
}

fn fund() -> Fund {
    Fund {
        code: "007339".to_string(),
        name: "易方达沪深300ETF联接C".to_string(),
        kind: "指数型".to_string(),
        initials: String::new(),
        pinyin: String::new(),
    }
}

/// Network smoke tests; run with `cargo test -p funddesk-core --test live -- --ignored`.
#[tokio::test]
#[ignore]
async fn live_fund_endpoints() {
    let client = client();
    let catalog = client.catalog().await.unwrap();
    assert!(catalog.len() > 1_000);
    let search = client.search("007339").await.unwrap();
    assert!(search.iter().any(|fund| fund.code == "007339"));
    let navs = client.nav_history(&fund(), 20).await.unwrap();
    assert!(!navs.is_empty());
    let sina = client.sina_snapshot(&fund()).await.unwrap();
    assert!(sina.nav.is_some());
    let history = client.fund_history(&fund()).await.unwrap();
    assert!(!history.navs.is_empty());
    let benchmark = client
        .index_daily_history(MarketIndex::Csi300, 300)
        .await
        .unwrap();
    assert!(benchmark.len() >= 200);
    let accumulated = history
        .accumulated
        .iter()
        .filter_map(|point| {
            point.time.to_utc().map(|instant| ObservationPoint {
                day: funddesk_core::clock::day(instant),
                value: point.value,
            })
        })
        .collect::<Vec<_>>();
    let profile = client.fund_profile("007339").await.unwrap();
    assert!(profile.company.is_some());
    let observation = observation::build(&ObservationInput {
        groups: &[FundGroup::Macd, FundGroup::Red],
        history: &history.navs,
        accumulated: &accumulated,
        benchmark: Some(&benchmark),
        fund_size: profile.size,
        purchase_fee: None,
    })
    .expect("历史净值应能生成观察数据");
    assert!(observation.series.is_some_and(|series| series.len() >= 250));
    assert!(observation.macd.is_some());
    assert!(observation.valuation.is_some());
    let disclosure = client.fund_disclosure("007339").await.unwrap();
    assert!(!disclosure.holdings.is_empty());
    let managers = client.fund_managers("007339").await.unwrap();
    assert!(!managers.current.is_empty());
}

#[tokio::test]
#[ignore]
async fn live_market_endpoints() {
    let client = client();
    let indices = client.indices().await.unwrap();
    assert_eq!(indices.len(), 7);
    let trend = client.index_trend(indices[0].index).await.unwrap();
    assert!(!trend.points.is_empty());
    let us = client
        .index_trend(MarketIndex::Sp500)
        .await
        .expect("美股指数分时必须能回退到东方财富");
    assert!(!us.points.is_empty());
    let quotes = client.futures_quotes().await.unwrap();
    assert!(quotes.len() >= 10);
    let gold = client
        .futures_intraday(FuturesInstrument::Gold)
        .await
        .unwrap();
    assert!(!gold.points.is_empty());
    let sectors = client
        .sector_flows(SectorCategory::Industry, SectorPeriod::Today)
        .await
        .unwrap();
    assert!(!sectors.is_empty());
    let breadth = client.market_breadth().await.unwrap();
    assert!(breadth.advancing.is_some());
    assert!(breadth.turnover > rust_decimal::Decimal::ZERO);
    let flows = client.market_flows().await.unwrap();
    assert!(!flows.points.is_empty());
}
