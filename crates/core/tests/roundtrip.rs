use funddesk_core::{roundtrip_file, Board};
use std::path::PathBuf;

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/board-v4.json")
}

#[test]
fn decodes_every_model_field() {
    let data = std::fs::read(fixture()).unwrap();
    let board: Board = serde_json::from_slice(&data).unwrap();

    assert_eq!(board.holdings.len(), 3);
    assert_eq!(board.snapshots.len(), 3);
    assert_eq!(board.observations.as_ref().unwrap().len(), 2);
    assert_eq!(board.refresh_interval, Some(10));
    assert_eq!(board.holdings[0].shares.unwrap().to_string(), "10000");
    assert_eq!(
        board.snapshots["007339"].history[1].value.to_string(),
        "1.6161"
    );
    assert_eq!(
        board.snapshots["050025"].history[0]
            .rate
            .unwrap()
            .to_string(),
        "-0.3211"
    );

    let observation = &board.observations.as_ref().unwrap()["007339"];
    assert_eq!(
        observation
            .macd
            .as_ref()
            .unwrap()
            .score
            .unwrap()
            .to_string(),
        "82"
    );
    assert_eq!(
        observation.series.as_ref().unwrap()[1].value.to_string(),
        "3.1987"
    );

    let valuation = &board.observations.as_ref().unwrap()["050025"]
        .valuation
        .as_ref()
        .unwrap();
    assert_eq!(valuation.anchors[0].score, 2);
    assert_eq!(valuation.one_year_percentile.unwrap().to_string(), "46.2");
}

#[test]
fn ignores_legacy_journal_payload() {
    let mut value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(fixture()).unwrap()).unwrap();
    value["journals"] = serde_json::json!({
        "007339": [{
            "id": "legacy",
            "action": "申购 / 加仓",
            "day": "2026-11-20",
            "shares": 10000,
            "price": 1.5,
            "fee": 0,
            "cash": 15000
        }]
    });
    let board: Board = serde_json::from_value(value).unwrap();
    let encoded = serde_json::to_value(board).unwrap();
    assert!(encoded.get("journals").is_none());
}

#[test]
fn reencodes_to_equivalent_board() {
    let report = roundtrip_file(&fixture()).unwrap();
    assert!(report.ok, "{:?}", report.notes);
    assert!(report.notes.is_empty(), "{:?}", report.notes);
    assert_eq!(report.holdings, 3);
    assert_eq!(report.observations, 2);
}

#[test]
fn keeps_nil_fields_omitted_like_swift() {
    let data = std::fs::read(fixture()).unwrap();
    let board: Board = serde_json::from_slice(&data).unwrap();
    let encoded = serde_json::to_string(&board).unwrap();
    assert!(!encoded.contains("null"), "可选字段应为缺省而非 null");
    assert!(!encoded.contains("\"realized\":null"));
    assert!(!encoded.contains("\"groups\":[]"));
    assert!(encoded.contains("\"hiddenFundColumnIDs\""));
}

#[test]
fn keeps_integral_dates_unscaled() {
    let data = std::fs::read(fixture()).unwrap();
    let board: Board = serde_json::from_slice(&data).unwrap();
    let encoded = serde_json::to_string(&board).unwrap();
    assert!(encoded.contains("\"timestamp\":817373040"));
    assert!(!encoded.contains("817373040.0"));
}

#[test]
fn detects_unknown_top_level_keys() {
    let mut value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(fixture()).unwrap()).unwrap();
    value["experimentalFlag"] = serde_json::json!(true);
    let directory = std::env::temp_dir().join("funddesk-roundtrip-test");
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join("board.json");
    std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
    let report = roundtrip_file(&path).unwrap();
    assert!(!report.ok);
    assert!(report
        .notes
        .iter()
        .any(|note| note.contains("experimentalFlag") || note.contains("丢失字段")));
}

/// Read the real macOS board without modifying it.
/// Run with: FUND_DESK_REAL_BOARD="$HOME/Library/Application Support/FundDesk/board.json" \
///           cargo test -p funddesk-core -- --ignored real_board_roundtrip
#[test]
#[ignore]
fn real_board_roundtrip() {
    let path = std::env::var("FUND_DESK_REAL_BOARD").expect("FUND_DESK_REAL_BOARD");
    let report = roundtrip_file(PathBuf::from(path).as_path()).unwrap();
    assert!(report.ok, "{:?}", report.notes);
    assert!(report.holdings > 0);
    println!("{report:#?}");
}
