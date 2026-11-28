use chrono::{DateTime, Duration, NaiveDate, Utc};
use funddesk_core::backup::BoardBackup;
use funddesk_core::clock::{can_poll_estimates, day, is_fresh_estimate};
use funddesk_core::csv;
use funddesk_core::futures_axis::tick_indices;
use funddesk_core::metrics::{EstimateHealth, FundMetrics, Portfolio};
use funddesk_core::model::*;
use funddesk_core::observation;
use funddesk_core::search;
use funddesk_core::swift::SwiftDate;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::str::FromStr;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn golden() -> Value {
    serde_json::from_slice(&std::fs::read(fixture("golden.json")).unwrap()).unwrap()
}

fn parse_instant(text: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(text)
        .unwrap()
        .with_timezone(&Utc)
}

fn assert_number(actual: Option<Decimal>, expected: &Value, context: &str) {
    match expected {
        Value::Null => assert!(actual.is_none(), "{context}: 期望空值，实际 {actual:?}"),
        Value::String(text) => {
            let expected = Decimal::from_str(text).unwrap().to_f64().unwrap();
            let actual = actual
                .unwrap_or_else(|| panic!("{context}: 期望 {text}，实际为空"))
                .to_f64()
                .unwrap();
            let tolerance = 1e-9 * expected.abs().max(1.0);
            assert!(
                (actual - expected).abs() <= tolerance,
                "{context}: 期望 {expected}，实际 {actual}"
            );
        }
        other => panic!("{context}: 非法 golden 值 {other:?}"),
    }
}

fn assert_float(actual: f64, expected: &Value, context: &str) {
    let expected = expected
        .as_f64()
        .unwrap_or_else(|| panic!("{context}: 期望数值，实际 {expected:?}"));
    let tolerance = 1e-9 * expected.abs().max(1.0);
    assert!(
        (actual - expected).abs() <= tolerance,
        "{context}: 期望 {expected}，实际 {actual}"
    );
}

#[test]
fn clock_matches_swift() {
    let golden = golden();
    for row in golden["clock"].as_array().unwrap() {
        let instant = parse_instant(row["instant"].as_str().unwrap());
        assert_eq!(day(instant), row["day"].as_str().unwrap());
        assert_eq!(
            can_poll_estimates(instant),
            row["canPoll"].as_bool().unwrap(),
            "{}",
            row["instant"]
        );
    }
    for row in golden["freshness"].as_array().unwrap() {
        let now = parse_instant(row["now"].as_str().unwrap());
        let timestamp = parse_instant(row["timestamp"].as_str().unwrap());
        let quote = Estimate {
            timestamp: SwiftDate::from_utc(timestamp),
            market_day: row["marketDay"].as_str().unwrap().to_string(),
            base_day: None,
            value: Decimal::ONE,
            percent: Decimal::ZERO,
        };
        assert_eq!(
            is_fresh_estimate(&quote, now),
            row["expected"].as_bool().unwrap(),
            "{} / {}",
            row["now"],
            row["timestamp"]
        );
    }
}

#[test]
fn metrics_and_portfolio_match_swift() {
    let golden = golden();
    let board: Board =
        serde_json::from_slice(&std::fs::read(fixture("scenario-metrics.json")).unwrap()).unwrap();
    let now = parse_instant(golden["metrics"]["now"].as_str().unwrap());

    for expected in golden["metrics"]["holdings"].as_array().unwrap() {
        let code = expected["code"].as_str().unwrap();
        let holding = board
            .holdings
            .iter()
            .find(|item| item.id() == code)
            .unwrap();
        let snapshot = board.snapshots.get(code).cloned().unwrap_or_default();
        let metrics = FundMetrics::new(holding, &snapshot, now);
        assert_number(metrics.value, &expected["value"], &format!("{code}.value"));
        assert_number(metrics.rate, &expected["rate"], &format!("{code}.rate"));
        assert_number(
            metrics.profit,
            &expected["profit"],
            &format!("{code}.profit"),
        );
        assert_number(
            metrics.estimated_day_profit,
            &expected["estimated"],
            &format!("{code}.estimated"),
        );
        assert_number(
            metrics.published_day_profit,
            &expected["published"],
            &format!("{code}.published"),
        );
        let exclusion = metrics
            .day_profit_exclusion
            .map(|value| value.title())
            .unwrap_or("");
        let expected_exclusion = expected["exclusion"].as_str().unwrap_or("");
        assert_eq!(exclusion, expected_exclusion, "{code}.exclusion");
    }

    let portfolio = Portfolio::new(&board, now);
    let expected = &golden["metrics"]["portfolio"];
    assert_number(portfolio.value, &expected["value"], "portfolio.value");
    assert_number(
        portfolio.day_profit(),
        &expected["dayProfit"],
        "portfolio.dayProfit",
    );
    assert_number(
        portfolio.estimated_day_profit,
        &expected["estimated"],
        "portfolio.estimated",
    );
    assert_number(
        portfolio.published_day_profit,
        &expected["published"],
        "portfolio.published",
    );
    assert_number(
        portfolio.estimated_coverage,
        &expected["coverage"],
        "portfolio.coverage",
    );
    assert_number(portfolio.profit, &expected["profit"], "portfolio.profit");
    assert_eq!(
        portfolio.estimated_day_count,
        expected["estimatedCount"].as_u64().unwrap() as usize
    );
    assert_eq!(
        portfolio.published_day_count,
        expected["publishedCount"].as_u64().unwrap() as usize
    );
    assert_eq!(
        portfolio.holding_count,
        expected["holdingCount"].as_u64().unwrap() as usize
    );
    assert_eq!(
        portfolio.missing_valuation_count,
        expected["missingValuationCount"].as_u64().unwrap() as usize
    );
    for (key, count) in expected["exclusions"].as_object().unwrap() {
        let expected_count = count.as_u64().unwrap() as usize;
        let actual = portfolio
            .day_profit_exclusions
            .iter()
            .find(|(exclusion, _)| exclusion.title() == key)
            .map(|(_, count)| *count)
            .unwrap_or_default();
        assert_eq!(actual, expected_count, "exclusion {key}");
    }

    let health = EstimateHealth::new(&board, &["050025".to_string()].into_iter().collect(), now);
    let expected = &golden["metrics"]["health"];
    assert_eq!(
        health.fresh_count,
        expected["fresh"].as_u64().unwrap() as usize
    );
    assert_eq!(
        health.stale_count,
        expected["stale"].as_u64().unwrap() as usize
    );
    assert_eq!(
        health.failed_count,
        expected["failed"].as_u64().unwrap() as usize
    );
    assert_eq!(
        health.missing_count,
        expected["missing"].as_u64().unwrap() as usize
    );
}

#[test]
fn csv_matches_swift() {
    let golden = golden();
    let holdings = vec![
        Holding {
            fund: Fund {
                code: "007339".to_string(),
                name: "易方达, \"沪深300\"".to_string(),
                kind: "指数型".to_string(),
                initials: String::new(),
                pinyin: String::new(),
            },
            shares: Some(Decimal::from_str("10000").unwrap()),
            cost_per_share: Some(Decimal::from_str("1.5").unwrap()),
            groups: Some(vec![FundGroup::Macd]),
        },
        Holding {
            fund: Fund {
                code: "050025".to_string(),
                name: "=博时标普".to_string(),
                kind: "QDII".to_string(),
                initials: String::new(),
                pinyin: String::new(),
            },
            shares: Some(Decimal::ZERO),
            cost_per_share: None,
            groups: Some(vec![FundGroup::Red]),
        },
    ];
    let exported = csv::export(&holdings);
    assert_eq!(
        exported
            .as_bytes()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>(),
        golden["csv"]["exportedHex"].as_str().unwrap()
    );

    let catalog = HashMap::from([(
        "007339".to_string(),
        Fund {
            code: "007339".to_string(),
            name: "目录名称".to_string(),
            kind: "目录类型".to_string(),
            initials: String::new(),
            pinyin: String::new(),
        },
    )]);
    let (parsed, invalid) = csv::parse(exported.as_bytes(), &catalog).unwrap();
    assert_eq!(invalid, golden["csv"]["invalid"].as_u64().unwrap() as usize);
    let expected = golden["csv"]["parsed"].as_array().unwrap();
    assert_eq!(parsed.len(), expected.len());
    for (holding, expected) in parsed.iter().zip(expected) {
        assert_eq!(holding.id(), expected["code"].as_str().unwrap());
        assert_eq!(holding.fund.name, expected["name"].as_str().unwrap());
        assert_eq!(holding.fund.kind, expected["kind"].as_str().unwrap());
        assert_number(holding.shares, &expected["shares"], "csv.shares");
        assert_number(holding.cost_per_share, &expected["cost"], "csv.cost");
        let groups = holding
            .group_values()
            .iter()
            .map(|group| match group {
                FundGroup::Macd => "macd",
                FundGroup::Red => "red",
            })
            .collect::<Vec<_>>();
        let expected_groups = expected["groups"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(groups, expected_groups);
    }
}

#[test]
fn search_matches_swift() {
    let golden = golden();
    let catalog = vec![
        Fund {
            code: "007339".to_string(),
            name: "易方达沪深300ETF联接C".to_string(),
            kind: "指数型".to_string(),
            initials: "YFD".to_string(),
            pinyin: "yifangda".to_string(),
        },
        Fund {
            code: "050025".to_string(),
            name: "博时标普500ETF联接A".to_string(),
            kind: "QDII".to_string(),
            initials: "BS".to_string(),
            pinyin: "boshi".to_string(),
        },
        Fund {
            code: "161725".to_string(),
            name: "招商中证白酒指数".to_string(),
            kind: "指数型".to_string(),
            initials: "ZS".to_string(),
            pinyin: "zhaoshang".to_string(),
        },
    ];
    for row in golden["search"].as_array().unwrap() {
        let keyword = row["keyword"].as_str().unwrap();
        let codes = search::catalog_results(&catalog, keyword, search::RESULT_LIMIT)
            .iter()
            .map(|fund| fund.code.clone())
            .collect::<Vec<_>>();
        let expected = row["codes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_string())
            .collect::<Vec<_>>();
        assert_eq!(codes, expected, "keyword {keyword}");
    }
}

fn series(values: &[f64]) -> Vec<ObservationPoint> {
    let start = NaiveDate::from_ymd_opt(2026, 9, 1).unwrap();
    values
        .iter()
        .enumerate()
        .map(|(index, value)| ObservationPoint {
            day: (start + Duration::days(index as i64))
                .format("%Y-%m-%d")
                .to_string(),
            value: Decimal::from_str(&format!("{value:.6}")).unwrap(),
        })
        .collect()
}

#[test]
fn observation_matches_swift() {
    let golden = golden();
    let smooth = series(
        &(0..80)
            .map(|index| 1.0 + (index as f64 / 7.0).sin() * 0.1 + index as f64 * 0.001)
            .collect::<Vec<_>>(),
    );
    let rebound_values = (0..80)
        .map(|index| {
            if index < 74 {
                1.5 - index as f64 * 0.004
            } else {
                1.5 - 74.0 * 0.004 + (index - 74) as f64 * 0.02
            }
        })
        .collect::<Vec<_>>();
    let rebound = series(&rebound_values);

    for (name, points) in [("smooth", &smooth), ("rebound", &rebound)] {
        let expected = &golden["observation"][name];
        let macd = observation::macd(points).unwrap();
        assert_eq!(
            macd.current_signal,
            expected["macd"]["signal"].as_str().unwrap(),
            "{name}.signal"
        );
        assert_eq!(
            macd.is_bullish,
            expected["macd"]["bullish"].as_bool().unwrap(),
            "{name}.bullish"
        );
        assert_eq!(
            macd.points.len(),
            expected["macd"]["count"].as_u64().unwrap() as usize
        );
        let expected_points = expected["macd"]["last"].as_array().unwrap();
        for (point, expected) in macd.points.iter().rev().take(3).rev().zip(expected_points) {
            assert_eq!(point.day, expected["day"].as_str().unwrap());
            assert_float(point.nav, &expected["nav"], "macd.nav");
            assert_float(point.dif, &expected["dif"], "macd.dif");
            assert_float(point.dea, &expected["dea"], "macd.dea");
            assert_float(point.histogram, &expected["histogram"], "macd.histogram");
            assert_eq!(
                point.crossing,
                expected["crossing"].as_i64().unwrap() as i32,
                "macd.crossing"
            );
        }

        let bands = observation::bands(points, 365).unwrap();
        assert_float(
            bands.box_high,
            &expected["bands"]["boxHigh"],
            "bands.boxHigh",
        );
        assert_float(bands.box_low, &expected["bands"]["boxLow"], "bands.boxLow");
        let last = bands.points.last().unwrap();
        let expected_last = &expected["bands"]["last"];
        assert_eq!(last.day, expected_last["day"].as_str().unwrap());
        assert_float(last.nav, &expected_last["nav"], "bands.nav");
        assert_float(
            last.percentile,
            &expected_last["percentile"],
            "bands.percentile",
        );
        if !expected_last["movingAverage"].is_null() {
            assert_float(
                last.moving_average.unwrap(),
                &expected_last["movingAverage"],
                "bands.ma",
            );
        }
        if !expected_last["upper"].is_null() {
            assert_float(
                last.bollinger_upper.unwrap(),
                &expected_last["upper"],
                "bands.upper",
            );
            assert_float(
                last.bollinger_lower.unwrap(),
                &expected_last["lower"],
                "bands.lower",
            );
        }
    }
}

#[test]
fn futures_axis_matches_swift() {
    let golden = golden();
    let day_start = parse_instant("2026-11-26T01:00:00Z");
    let day_times = (0..=36)
        .map(|index| day_start + Duration::seconds(index * 600))
        .collect::<Vec<_>>();
    let night_start = parse_instant("2026-11-26T10:00:00Z");
    let night_times = (0..=276)
        .map(|index| night_start + Duration::seconds(index * 300))
        .collect::<Vec<_>>();
    let expected = golden["futures"].as_array().unwrap();
    assert_eq!(
        tick_indices(&day_times, 0..=36),
        expected[0]["indices"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_u64().unwrap() as usize)
            .collect::<Vec<_>>()
    );
    assert_eq!(
        tick_indices(&night_times, 0..=276),
        expected[1]["indices"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_u64().unwrap() as usize)
            .collect::<Vec<_>>()
    );
}

#[test]
fn swift_backup_v2_decodes_in_rust() {
    let board: Board =
        serde_json::from_slice(&std::fs::read(fixture("scenario-metrics.json")).unwrap()).unwrap();
    let encoded = BoardBackup::export_restore_point(&board).unwrap();
    let backup = BoardBackup::decode(&encoded).unwrap();
    assert_eq!(backup.version, 2);
    assert!(backup.includes_settings());
    assert!(backup.includes_snapshots());
    assert_eq!(backup.board.holdings.len(), board.holdings.len());
    let reencoded = BoardBackup::export_restore_point(&backup.board).unwrap();
    let again = BoardBackup::decode(&reencoded).unwrap();
    assert_eq!(again.board, backup.board);
}
