use funddesk_core::board_ops::{FundDetailTab, FundTableColumn, HoldingPlacement};
use funddesk_core::cache::ResearchCache;
use funddesk_core::clock::{can_poll_estimates, day};
use funddesk_core::import::{export_plugin, PluginImport, PluginImportReport};
use funddesk_core::market::{
    CustomFuturesQuote, FuturesCandle, FuturesFiveSessions, FuturesInstrument, FuturesIntraday,
    FuturesQuote, FuturesSessionPrices, IndexQuote, IndexTrendData, MarketBreadth,
    MarketFlowSeries, MarketIndex, SectorCategory, SectorFlow, SectorPeriod, StockQuote,
};
use funddesk_core::metrics::{DayProfitExclusion, EstimateHealth, FundMetrics, Portfolio};
use funddesk_core::model::{
    Board, Estimate, Fund, FundGroup, FundObservation, Holding, MenuBarItem, Nav, ObservationPoint,
    PositionAction, PositionRecord, Snapshot,
};
use funddesk_core::observation::{self, ObservationInput};
use funddesk_core::provider::now_text;
use funddesk_core::research::{
    FundDisclosure, FundHistory, FundManagerHistory, FundProfile, HistoryPeriod,
};
use funddesk_core::sources::Sources;
use funddesk_core::swift::SwiftDate;
use funddesk_core::{BoardStorage, MarketClient};
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

pub struct AppState {
    pub storage: BoardStorage,
    pub market: MarketClient,
    pub cache: ResearchCache,
    pub board: Mutex<Board>,
    pub catalog: Mutex<Option<Vec<Fund>>>,
    pub custom_futures: Mutex<Vec<CustomFutures>>,
    pub shanghai_quote: Mutex<Option<IndexQuote>>,
    pub source_error: Mutex<Option<String>>,
    pub refreshing: AtomicBool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomFutures {
    pub symbol: String,
    pub title: String,
}

impl AppState {
    pub fn new() -> Self {
        let storage = BoardStorage::from_env();
        let board = storage.open().board;
        let custom_futures = load_custom_futures(&storage);
        let cache = ResearchCache::new(storage.directory());
        let sources_path = storage.sources_path();
        let (sources, source_error) = match Sources::load(&sources_path) {
            Ok(sources) => (sources, None),
            Err(error) => (Sources::default(), Some(error)),
        };
        Self {
            storage,
            market: MarketClient::with_sources(sources).expect("创建行情客户端"),
            cache,
            board: Mutex::new(board),
            catalog: Mutex::new(None),
            custom_futures: Mutex::new(custom_futures),
            shanghai_quote: Mutex::new(None),
            source_error: Mutex::new(source_error),
            refreshing: AtomicBool::new(false),
        }
    }
}

fn custom_futures_path(storage: &BoardStorage) -> std::path::PathBuf {
    storage.directory().join("futures-watchlist.json")
}

fn load_custom_futures(storage: &BoardStorage) -> Vec<CustomFutures> {
    std::fs::read(custom_futures_path(storage))
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_default()
}

fn save_custom_futures(storage: &BoardStorage, items: &[CustomFutures]) {
    if let Ok(data) = serde_json::to_vec_pretty(items) {
        let path = custom_futures_path(storage);
        let temp = path.with_extension("json.tmp");
        if std::fs::write(&temp, data).is_ok() {
            let _ = std::fs::rename(temp, path);
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FundRow {
    pub code: String,
    pub name: String,
    pub kind: String,
    pub groups: Vec<String>,
    pub shares: Option<f64>,
    pub cost: Option<f64>,
    pub value: Option<f64>,
    pub profit: Option<f64>,
    pub profit_rate: Option<f64>,
    pub nav: Option<f64>,
    pub nav_day: Option<String>,
    pub nav_rate: Option<f64>,
    pub estimate_value: Option<f64>,
    pub estimate_rate: Option<f64>,
    pub estimate_time: Option<String>,
    pub estimate_market_day: Option<String>,
    pub estimate_fresh: bool,
    pub day_profit: Option<f64>,
    pub exclusion: Option<String>,
    pub has_observation: bool,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryView {
    pub value: Option<f64>,
    pub day_profit: Option<f64>,
    pub estimated: Option<f64>,
    pub published: Option<f64>,
    pub profit: Option<f64>,
    pub holding_count: usize,
    pub covered_count: usize,
    pub estimated_count: usize,
    pub published_count: usize,
    pub missing_count: usize,
    pub coverage: Option<f64>,
    pub exclusions: Vec<ExclusionView>,
    pub estimate_health: EstimateHealthView,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExclusionView {
    pub reason: String,
    pub count: usize,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EstimateHealthView {
    pub fresh_count: usize,
    pub stale_count: usize,
    pub failed_count: usize,
    pub missing_count: usize,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CountsView {
    pub all: usize,
    pub holding: usize,
    pub macd: usize,
    pub red: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsView {
    pub theme: String,
    pub refresh_interval: i32,
    pub menu_bar_visible: bool,
    pub menu_bar_items: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardView {
    pub rows: Vec<FundRow>,
    pub summary: SummaryView,
    pub counts: CountsView,
    pub settings: SettingsView,
    pub columns: Vec<String>,
    pub visible_columns: Vec<String>,
    pub detail_tabs: Vec<String>,
    pub data_dir: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BootstrapView {
    pub board: BoardView,
    pub platform: String,
    pub tray_mode: String,
    pub sources: DataSourceStatus,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DataSourceStatus {
    pub configured: bool,
    pub path: String,
    pub label: String,
    pub missing: Vec<String>,
    pub error: Option<String>,
}

fn to_f64(value: Option<Decimal>) -> Option<f64> {
    value.and_then(|value| value.to_f64())
}

fn sw_date_text(value: Option<SwiftDate>) -> Option<String> {
    let instant = value?.to_utc()?;
    Some(
        instant
            .with_timezone(&funddesk_core::clock::shanghai())
            .format("%H:%M:%S")
            .to_string(),
    )
}

pub fn build_view(
    board: &Board,
    storage: &BoardStorage,
    now: chrono::DateTime<chrono::Utc>,
) -> BoardView {
    let portfolio = Portfolio::new(board, now);
    let rows = board
        .holdings
        .iter()
        .map(|holding| {
            let snapshot = board
                .snapshots
                .get(holding.id())
                .cloned()
                .unwrap_or_default();
            let metrics = FundMetrics::new(holding, &snapshot, now);
            let nav = snapshot.nav();
            let effective = snapshot.effective_estimate(now);
            let estimate = snapshot.estimate.as_ref();
            FundRow {
                code: holding.id().to_string(),
                name: holding.fund.name.clone(),
                kind: holding.fund.kind.clone(),
                groups: holding
                    .group_values()
                    .iter()
                    .map(|group| match group {
                        FundGroup::Macd => "macd",
                        FundGroup::Red => "red",
                    })
                    .map(str::to_string)
                    .collect(),
                shares: to_f64(holding.shares),
                cost: to_f64(holding.cost_per_share),
                value: to_f64(metrics.value),
                profit: to_f64(metrics.profit),
                profit_rate: to_f64(metrics.rate),
                nav: to_f64(nav.map(|nav| nav.value)),
                nav_day: nav.map(|nav| nav.day.clone()),
                nav_rate: to_f64(nav.and_then(|nav| nav.rate)),
                estimate_value: to_f64(estimate.map(|estimate| estimate.value)),
                estimate_rate: to_f64(estimate.map(|estimate| estimate.percent)),
                estimate_time: sw_date_text(estimate.map(|estimate| estimate.timestamp)),
                estimate_market_day: estimate.map(|estimate| estimate.market_day.clone()),
                estimate_fresh: effective.is_some(),
                day_profit: to_f64(
                    metrics
                        .published_day_profit
                        .or(metrics.estimated_day_profit),
                ),
                exclusion: metrics
                    .day_profit_exclusion
                    .map(DayProfitExclusion::title)
                    .map(str::to_string),
                has_observation: board
                    .observations
                    .as_ref()
                    .is_some_and(|observations| observations.contains_key(holding.id())),
            }
        })
        .collect::<Vec<_>>();
    let mut exclusions = portfolio
        .day_profit_exclusions
        .iter()
        .map(|(reason, count)| ExclusionView {
            reason: reason.title().to_string(),
            count: *count,
        })
        .collect::<Vec<_>>();
    exclusions.sort_by(|left, right| right.count.cmp(&left.count));
    let estimate_health = EstimateHealth::new(board, &HashSet::new(), now);
    let counts = CountsView {
        all: board.holdings.len(),
        holding: board
            .holdings
            .iter()
            .filter(|holding| holding.shares.unwrap_or_default() > Decimal::ZERO)
            .count(),
        macd: board
            .holdings
            .iter()
            .filter(|holding| holding.group_values().contains(&FundGroup::Macd))
            .count(),
        red: board
            .holdings
            .iter()
            .filter(|holding| holding.group_values().contains(&FundGroup::Red))
            .count(),
    };
    BoardView {
        rows,
        summary: SummaryView {
            value: to_f64(portfolio.value),
            day_profit: to_f64(portfolio.day_profit()),
            estimated: to_f64(portfolio.estimated_day_profit),
            published: to_f64(portfolio.published_day_profit),
            profit: to_f64(portfolio.profit),
            holding_count: portfolio.holding_count,
            covered_count: portfolio.covered_day_count(),
            estimated_count: portfolio.estimated_day_count,
            published_count: portfolio.published_day_count,
            missing_count: portfolio.missing_valuation_count,
            coverage: to_f64(portfolio.estimated_coverage),
            exclusions,
            estimate_health: EstimateHealthView {
                fresh_count: estimate_health.fresh_count,
                stale_count: estimate_health.stale_count,
                failed_count: estimate_health.failed_count,
                missing_count: estimate_health.missing_count,
            },
        },
        counts,
        settings: SettingsView {
            theme: board
                .appearance_theme
                .clone()
                .unwrap_or_else(|| "system".to_string()),
            refresh_interval: board.refresh_interval_value(),
            menu_bar_visible: board.menu_bar_visible_value(),
            menu_bar_items: board
                .menu_bar_items_value()
                .into_iter()
                .map(|item| item.raw().to_string())
                .collect(),
        },
        columns: board
            .fund_columns()
            .into_iter()
            .map(|column| column.raw().to_string())
            .collect(),
        visible_columns: board
            .visible_fund_columns()
            .into_iter()
            .map(|column| column.raw().to_string())
            .collect(),
        detail_tabs: board
            .fund_detail_tabs()
            .into_iter()
            .map(|tab| tab.raw().to_string())
            .collect(),
        data_dir: storage.directory().display().to_string(),
        updated_at: now_text(),
    }
}

pub fn bootstrap(state: &AppState) -> BootstrapView {
    let board = state.board.lock().unwrap().clone();
    BootstrapView {
        board: build_view(&board, &state.storage, chrono::Utc::now()),
        platform: std::env::consts::OS.to_string(),
        tray_mode: if cfg!(target_os = "macos") {
            "menu-bar-title".to_string()
        } else {
            "tray-tooltip".to_string()
        },
        sources: data_source_status(state),
    }
}

pub fn data_source_status(state: &AppState) -> DataSourceStatus {
    let sources = state.market.sources();
    DataSourceStatus {
        configured: sources.is_configured(),
        path: state.storage.sources_path().display().to_string(),
        label: sources.label.clone(),
        missing: sources.missing_required(),
        error: state.source_error.lock().unwrap().clone(),
    }
}

pub fn data_sources_text(state: &AppState) -> Result<String, String> {
    state.market.sources().to_json()
}

pub fn save_data_sources(state: &AppState, text: &str) -> Result<DataSourceStatus, String> {
    let sources = Sources::from_json(text)?;
    sources.save(&state.storage.sources_path())?;
    state.market.set_sources(sources);
    *state.source_error.lock().unwrap() = None;
    Ok(data_source_status(state))
}

pub fn clear_data_sources(state: &AppState) -> Result<DataSourceStatus, String> {
    let sources = Sources::default();
    sources.save(&state.storage.sources_path())?;
    state.market.set_sources(sources);
    *state.source_error.lock().unwrap() = None;
    Ok(data_source_status(state))
}

pub async fn refresh_board(state: &AppState, manual: bool) -> BoardView {
    let board = state.board.lock().unwrap().clone();
    let now = chrono::Utc::now();
    let semaphore = Arc::new(Semaphore::new(4));
    let mut tasks = JoinSet::new();
    for holding in board.holdings.clone() {
        let market = state.market.clone();
        let snapshot = board
            .snapshots
            .get(holding.id())
            .cloned()
            .unwrap_or_default();
        let nav_due = snapshot
            .nav_checked_at
            .and_then(|value| value.to_utc())
            .is_none_or(|checked| now - checked > chrono::Duration::minutes(20));
        let want_estimate = manual || can_poll_estimates(now);
        let semaphore = semaphore.clone();
        tasks.spawn(async move {
            let _permit = semaphore.acquire_owned().await.ok();
            let navs = if nav_due {
                market.nav_history(&holding.fund, 20).await.ok()
            } else {
                None
            };
            let sina = if want_estimate {
                market.sina_snapshot(&holding.fund).await.ok()
            } else {
                None
            };
            (holding.id().to_string(), nav_due, navs, sina)
        });
    }
    let mut updates = Vec::new();
    while let Some(result) = tasks.join_next().await {
        if let Ok(update) = result {
            updates.push(update);
        }
    }
    {
        let mut board = state.board.lock().unwrap();
        let mut changed = false;
        for (code, nav_due, navs, sina) in updates {
            let snapshot = board.snapshots.entry(code).or_default();
            if let Some(navs) = navs {
                snapshot.merge_history(&navs);
                snapshot.nav_checked_at = Some(SwiftDate::now());
                changed = true;
            } else if nav_due {
                snapshot.nav_checked_at =
                    Some(SwiftDate::from_utc(now - chrono::Duration::minutes(16)));
            }
            if let Some(sina) = sina {
                if let Some(nav) = sina.nav {
                    snapshot.merge_history(&[nav]);
                }
                if let Some(estimate) = sina.estimate {
                    snapshot.merge_estimate(&estimate);
                    snapshot.estimate_available = Some(true);
                }
                snapshot.estimate_checked_at = Some(SwiftDate::now());
                changed = true;
            }
        }
        if changed {
            let _ = state.storage.save(&board);
        }
    }
    let _ = refresh_observations(state).await;
    let updated = state.board.lock().unwrap().clone();
    build_view(&updated, &state.storage, chrono::Utc::now())
}

pub async fn ensure_catalog(state: &AppState) -> Result<Vec<Fund>, String> {
    if let Some(catalog) = state.catalog.lock().unwrap().clone() {
        if !catalog.is_empty() {
            return Ok(catalog);
        }
    }
    let mut funds = state.storage.load_catalog();
    if funds.is_empty() {
        funds = state
            .market
            .catalog()
            .await
            .map_err(|error| error.to_string())?;
        let _ = state.storage.save_catalog(&funds);
    }
    *state.catalog.lock().unwrap() = Some(funds.clone());
    Ok(funds)
}

#[derive(Serialize)]
pub struct PluginImportResult {
    pub board: BoardView,
    pub report: PluginImportReport,
}

pub fn export_plugin_config(state: &AppState) -> Result<String, String> {
    let board = state.board.lock().unwrap();
    export_plugin(&board.holdings).map_err(|error| format!("导出配置失败：{error}"))
}

pub async fn import_plugin_config(
    state: &AppState,
    text: &str,
    overwrite: bool,
) -> Result<PluginImportResult, String> {
    let incoming = PluginImport::parse(text).map_err(|error| error.to_string())?;
    let needs_catalog = incoming.needs_catalog(&state.board.lock().unwrap().holdings);
    let catalog = if needs_catalog {
        ensure_catalog(state).await.unwrap_or_default()
    } else {
        Vec::new()
    };
    let mut board = state.board.lock().unwrap();
    let mut updated = board.clone();
    let report = incoming.merge(&mut updated.holdings, &catalog, overwrite);
    if updated.holdings != board.holdings {
        state
            .storage
            .save(&updated)
            .map_err(|error| format!("保存导入数据失败：{error}"))?;
        *board = updated;
    }
    Ok(PluginImportResult {
        board: build_view(&board, &state.storage, chrono::Utc::now()),
        report,
    })
}

pub async fn search_funds(state: &AppState, keyword: &str) -> Result<Vec<Fund>, String> {
    let catalog = ensure_catalog(state).await?;
    let local = funddesk_core::search::catalog_results(&catalog, keyword, 35);
    if local.len() >= 35 {
        return Ok(local);
    }
    let remote = state.market.search(keyword).await.unwrap_or_default();
    Ok(funddesk_core::search::merge(&local, &remote, 35))
}

pub async fn add_fund(
    state: &AppState,
    code: &str,
    group: Option<&str>,
) -> Result<BoardView, String> {
    let code = code.trim();
    if !Fund::valid_code(code) {
        return Err("基金代码应为 6 位数字".to_string());
    }
    let group = match group {
        None => None,
        Some("macd") => Some(FundGroup::Macd),
        Some("red") => Some(FundGroup::Red),
        Some(_) => return Err("未知基金分组".to_string()),
    };
    // Adding a fund must work before data sources are configured, and it must
    // not wait for a network catalog request. Only use an already loaded or
    // locally saved catalog to improve the display name.
    let fund = state
        .catalog
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|catalog| catalog.iter().find(|fund| fund.code == code).cloned())
        .or_else(|| {
            state
                .storage
                .load_catalog()
                .into_iter()
                .find(|fund| fund.code == code)
        })
        .unwrap_or_else(|| Fund {
            code: code.to_string(),
            name: code.to_string(),
            kind: String::new(),
            initials: String::new(),
            pinyin: String::new(),
        });
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    if board.add_holding(fund, group) {
        persist_board(&state.storage, &mut current, &board)?;
    }
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

// The caller holds the board lock across both the disk write and the in-memory commit.
fn persist_board(
    storage: &BoardStorage,
    current: &mut Board,
    updated: &Board,
) -> Result<(), String> {
    storage
        .save(updated)
        .map_err(|error| format!("保存看板失败，修改未生效：{error}"))?;
    current.clone_from(updated);
    Ok(())
}

pub fn remove_fund(state: &AppState, code: &str) -> Result<BoardView, String> {
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    board.holdings.retain(|holding| holding.id() != code);
    board.snapshots.remove(code);
    if let Some(journals) = &mut board.journals {
        journals.remove(code);
    }
    if let Some(observations) = &mut board.observations {
        observations.remove(code);
    }
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

pub fn set_holding(
    state: &AppState,
    code: &str,
    shares: Option<f64>,
    cost: Option<f64>,
) -> Result<BoardView, String> {
    if shares.is_some_and(|value| value < 0.0) || cost.is_some_and(|value| value < 0.0) {
        return Err("份额与成本不能为负数".to_string());
    }
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    let holding = board
        .holdings
        .iter_mut()
        .find(|holding| holding.id() == code)
        .ok_or_else(|| "未找到基金".to_string())?;
    holding.shares = shares.and_then(Decimal::from_f64_retain);
    holding.cost_per_share = cost
        .filter(|value| *value > 0.0)
        .and_then(Decimal::from_f64_retain);
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

pub fn save_settings(state: &AppState, theme: &str, interval: i32) -> Result<BoardView, String> {
    if !matches!(theme, "system" | "light" | "dark") {
        return Err("未知主题".to_string());
    }
    if ![5, 10, 30, 60].contains(&interval) {
        return Err("刷新间隔不在允许范围".to_string());
    }
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    board.appearance_theme = Some(theme.to_string());
    board.refresh_interval = Some(interval);
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

pub fn save_menu_bar(
    state: &AppState,
    visible: bool,
    items: &[String],
) -> Result<BoardView, String> {
    let mut selected = Vec::new();
    for value in items {
        let item = MenuBarItem::parse(value).ok_or_else(|| "未知菜单栏选项".to_string())?;
        if !selected.contains(&item) {
            selected.push(item);
        }
    }
    if visible && selected.is_empty() {
        return Err("请至少选择一项显示内容，或关闭菜单栏信息".to_string());
    }
    selected.sort_by_key(|item| {
        MenuBarItem::ALL
            .iter()
            .position(|candidate| candidate == item)
            .unwrap_or(usize::MAX)
    });
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    board.menu_bar_visible = Some(visible);
    board.menu_bar_items = Some(
        selected
            .into_iter()
            .map(|item| item.raw().to_string())
            .collect(),
    );
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

fn columns_from_raw(values: &[String]) -> Option<Vec<FundTableColumn>> {
    values
        .iter()
        .map(|value| value.parse::<FundTableColumn>().ok())
        .collect()
}

pub fn save_visible_columns(state: &AppState, visible: &[String]) -> Result<BoardView, String> {
    let columns = columns_from_raw(visible).ok_or_else(|| "未知表格列".to_string())?;
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    let columns = columns.into_iter().collect::<HashSet<FundTableColumn>>();
    board.set_visible_fund_columns(&columns);
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

pub fn reorder_columns(state: &AppState, visible: &[String]) -> Result<BoardView, String> {
    let columns = columns_from_raw(visible).ok_or_else(|| "未知表格列".to_string())?;
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    if !board.reorder_visible_fund_columns(&columns) {
        return Ok(build_view(&board, &state.storage, chrono::Utc::now()));
    }
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

pub fn move_fund(
    state: &AppState,
    code: &str,
    target: &str,
    after: bool,
    visible: &[String],
) -> Result<BoardView, String> {
    let codes = visible.iter().cloned().collect::<HashSet<_>>();
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    let moved = board.move_holding(
        code,
        target,
        if after {
            HoldingPlacement::After
        } else {
            HoldingPlacement::Before
        },
        &codes,
    );
    if !moved {
        return Ok(build_view(&board, &state.storage, chrono::Utc::now()));
    }
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

pub fn set_groups(state: &AppState, code: &str, groups: &[String]) -> Result<BoardView, String> {
    let mut values = Vec::new();
    for group in groups {
        match group.as_str() {
            "macd" if !values.contains(&FundGroup::Macd) => values.push(FundGroup::Macd),
            "red" if !values.contains(&FundGroup::Red) => values.push(FundGroup::Red),
            "macd" | "red" => {}
            _ => return Err("未知基金分组".to_string()),
        }
    }
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    let holding = board
        .holdings
        .iter_mut()
        .find(|holding| holding.id() == code)
        .ok_or_else(|| "未找到基金".to_string())?;
    holding.groups = if values.is_empty() {
        None
    } else {
        Some(values)
    };
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

pub fn move_detail_tab(state: &AppState, source: &str, target: &str) -> Result<BoardView, String> {
    let source = source
        .parse::<FundDetailTab>()
        .map_err(|_| "未知详情标签".to_string())?;
    let target = target
        .parse::<FundDetailTab>()
        .map_err(|_| "未知详情标签".to_string())?;
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    board.move_fund_detail_tab(source, target, true);
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

const OBSERVATION_CACHE_SECONDS: f64 = 6.0 * 60.0 * 60.0;
const BENCHMARK_CACHE_SECONDS: f64 = 6.0 * 60.0 * 60.0;
const HISTORY_CACHE_SECONDS: f64 = 6.0 * 60.0 * 60.0;

fn observation_cache_key(holding: &Holding) -> String {
    let groups = holding
        .group_values()
        .iter()
        .map(|group| match group {
            FundGroup::Macd => "macd",
            FundGroup::Red => "red",
        })
        .collect::<Vec<_>>()
        .join("-");
    let version = if holding.group_values().contains(&FundGroup::Macd) {
        3
    } else {
        2
    };
    format!("fund-observation-v{version}/{}/{}", holding.id(), groups)
}

fn parse_percent(value: Option<&str>) -> Option<Decimal> {
    value?
        .trim()
        .trim_end_matches('%')
        .parse::<Decimal>()
        .ok()
        .filter(|value| *value >= Decimal::ZERO)
}

fn accumulated_points(history: &FundHistory) -> Vec<ObservationPoint> {
    history
        .accumulated
        .iter()
        .filter_map(|point| {
            point.time.to_utc().map(|instant| ObservationPoint {
                day: day(instant),
                value: point.value,
            })
        })
        .collect()
}

fn build_auto_observation(
    holding: &Holding,
    history: &FundHistory,
    profile: Option<&FundProfile>,
    benchmark: Option<&[Nav]>,
) -> Option<FundObservation> {
    let groups = holding.group_values();
    if groups.is_empty() || history.is_degraded() {
        return None;
    }
    let accumulated = accumulated_points(history);
    observation::build(&ObservationInput {
        groups: &groups,
        history: &history.navs,
        accumulated: &accumulated,
        benchmark,
        fund_size: profile.and_then(|profile| profile.size),
        purchase_fee: profile.and_then(|profile| {
            parse_percent(profile.original_fee.as_deref())
                .or_else(|| parse_percent(profile.purchase_fee.as_deref()))
        }),
    })
}

async fn benchmark_history(state: &AppState) -> Option<Vec<Nav>> {
    cached(
        &state.cache,
        "market-daily-v1/sh000300",
        BENCHMARK_CACHE_SECONDS,
        async {
            state
                .market
                .index_daily_history(MarketIndex::Csi300, 1500)
                .await
                .map_err(|error| error.to_string())
        },
    )
    .await
    .ok()
}

async fn load_auto_observation(
    state: &AppState,
    holding: &Holding,
    benchmark: Option<&[Nav]>,
) -> Option<FundObservation> {
    if holding.group_values().is_empty() {
        return None;
    }
    let key = observation_cache_key(holding);
    if let Some(cached) = state.cache.read::<FundObservation>(&key) {
        if cached.age_seconds(funddesk_core::cache::now_seconds()) <= OBSERVATION_CACHE_SECONDS {
            return Some(cached.payload);
        }
    }
    let code = holding.id().to_string();
    let history = cached(
        &state.cache,
        &format!("fund-history/{code}"),
        HISTORY_CACHE_SECONDS,
        async {
            state
                .market
                .fund_history(&holding.fund)
                .await
                .map_err(|error| error.to_string())
        },
    )
    .await
    .ok()?;
    let profile = cached(
        &state.cache,
        &format!("fund-profile/{code}"),
        604_800.0,
        async {
            state
                .market
                .fund_profile(&code)
                .await
                .map_err(|error| error.to_string())
        },
    )
    .await
    .ok();
    let observation = build_auto_observation(holding, &history, profile.as_ref(), benchmark)?;
    let _ = state.cache.write(&key, &observation);
    Some(observation)
}

fn store_observation(state: &AppState, code: &str, observation: FundObservation) -> bool {
    let mut board = state.board.lock().unwrap();
    let observations = board.observations.get_or_insert_with(HashMap::new);
    if observations.get(code) == Some(&observation) {
        return false;
    }
    observations.insert(code.to_string(), observation);
    let _ = state.storage.save(&board);
    true
}

pub async fn refresh_observations(state: &AppState) -> bool {
    let holdings = state
        .board
        .lock()
        .unwrap()
        .holdings
        .iter()
        .filter(|holding| !holding.group_values().is_empty())
        .cloned()
        .collect::<Vec<_>>();
    if holdings.is_empty() {
        return false;
    }
    let benchmark = if holdings
        .iter()
        .any(|holding| holding.group_values().contains(&FundGroup::Red))
    {
        benchmark_history(state).await
    } else {
        None
    };
    let mut changed = false;
    for holding in holdings {
        let Some(observation) = load_auto_observation(state, &holding, benchmark.as_deref()).await
        else {
            continue;
        };
        changed |= store_observation(state, holding.id(), observation);
    }
    changed
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FundDetailView {
    pub code: String,
    pub name: String,
    pub kind: String,
    pub snapshot: Snapshot,
    pub history: Option<FundHistory>,
    pub returns: HashMap<String, Vec<funddesk_core::market::PlotPoint>>,
    pub estimate_series: Vec<Estimate>,
    pub stock_quotes: HashMap<String, StockQuote>,
    pub stock_quote_failed: bool,
    pub profile: Option<FundProfile>,
    pub disclosure: Option<FundDisclosure>,
    pub managers: Option<FundManagerHistory>,
    pub observation: Option<FundObservation>,
    pub errors: Vec<String>,
}

pub async fn fund_detail(state: &AppState, code: &str) -> Result<FundDetailView, String> {
    let board = state.board.lock().unwrap().clone();
    let holding = board
        .holdings
        .iter()
        .find(|holding| holding.id() == code)
        .cloned()
        .ok_or_else(|| "未找到基金".to_string())?;
    let snapshot = board.snapshots.get(code).cloned().unwrap_or_default();
    let history_key = format!("fund-history/{code}");
    let profile_key = format!("fund-profile/{code}");
    let disclosure_key = format!("fund-disclosure/{code}");
    let managers_key = format!("fund-managers/{code}");
    let wants_red = holding.group_values().contains(&FundGroup::Red);
    let (history, profile, disclosure, managers, benchmark) = tokio::join!(
        cached(&state.cache, &history_key, HISTORY_CACHE_SECONDS, async {
            state
                .market
                .fund_history(&holding.fund)
                .await
                .map_err(|error| error.to_string())
        }),
        cached(&state.cache, &profile_key, 604_800.0, async {
            state
                .market
                .fund_profile(code)
                .await
                .map_err(|error| error.to_string())
        }),
        cached(&state.cache, &disclosure_key, 604_800.0, async {
            state
                .market
                .fund_disclosure(code)
                .await
                .map_err(|error| error.to_string())
        }),
        cached(&state.cache, &managers_key, 604_800.0, async {
            state
                .market
                .fund_managers(code)
                .await
                .map_err(|error| error.to_string())
        }),
        async {
            if wants_red {
                benchmark_history(state).await
            } else {
                None
            }
        }
    );
    let symbols = disclosure
        .as_ref()
        .ok()
        .map(|report| {
            report
                .holdings
                .iter()
                .filter_map(|holding| holding.stock_quote_symbol())
                .collect::<HashSet<_>>()
        })
        .unwrap_or_default();
    let estimate_key = format!("fund-estimate/{code}");
    let quotes_key = format!("stock-quotes/{code}");
    let (estimate_series, stock_quotes) = tokio::join!(
        cached(&state.cache, &estimate_key, 90.0, async {
            if holding.fund.is_money() {
                Ok(Vec::new())
            } else {
                state
                    .market
                    .sina_snapshot(&holding.fund)
                    .await
                    .map(|snapshot| snapshot.series)
                    .map_err(|error| error.to_string())
            }
        }),
        async {
            if symbols.is_empty() {
                Ok(HashMap::new())
            } else {
                cached(&state.cache, &quotes_key, 60.0, async {
                    state
                        .market
                        .stock_quotes(&symbols)
                        .await
                        .map_err(|error| error.to_string())
                })
                .await
            }
        }
    );
    let mut errors = Vec::new();
    if let Err(error) = &history {
        errors.push(format!("历史净值: {error}"));
    }
    if let Err(error) = &profile {
        errors.push(format!("基金档案: {error}"));
    }
    if let Err(error) = &disclosure {
        errors.push(format!("披露持仓: {error}"));
    }
    if let Err(error) = &managers {
        errors.push(format!("基金经理: {error}"));
    }
    let history = history.ok();
    let profile = profile.ok();
    let auto_observation = history.as_ref().and_then(|history| {
        build_auto_observation(&holding, history, profile.as_ref(), benchmark.as_deref())
    });
    let observation = if let Some(observation) = auto_observation {
        let _ = state
            .cache
            .write(&observation_cache_key(&holding), &observation);
        store_observation(state, code, observation.clone());
        Some(observation)
    } else {
        board
            .observations
            .as_ref()
            .and_then(|observations| observations.get(code))
            .cloned()
    };
    let returns = history
        .as_ref()
        .map(|history| {
            HistoryPeriod::ALL
                .iter()
                .map(|period| {
                    (
                        period.title().to_string(),
                        history.returns(*period, holding.fund.is_money()),
                    )
                })
                .collect::<HashMap<_, _>>()
        })
        .unwrap_or_default();
    Ok(FundDetailView {
        code: code.to_string(),
        name: holding.fund.name.clone(),
        kind: holding.fund.kind.clone(),
        snapshot,
        history,
        returns,
        estimate_series: estimate_series.unwrap_or_default(),
        stock_quote_failed: stock_quotes.is_err() && !symbols.is_empty(),
        stock_quotes: stock_quotes.unwrap_or_default(),
        profile,
        disclosure: disclosure.ok(),
        managers: managers.ok(),
        observation,
        errors,
    })
}

pub async fn fund_disclosure(state: &AppState, code: &str) -> Result<FundDisclosure, String> {
    let key = format!("fund-disclosure/{code}");
    cached(&state.cache, &key, 604_800.0, async {
        state
            .market
            .fund_disclosure(code)
            .await
            .map_err(|error| error.to_string())
    })
    .await
}

async fn cached<T, F>(
    cache: &ResearchCache,
    key: &str,
    max_age_seconds: f64,
    fetch: F,
) -> Result<T, String>
where
    T: Serialize + DeserializeOwned + Clone,
    F: Future<Output = Result<T, String>>,
{
    let stored = cache.read::<T>(key);
    if let Some(cached) = &stored {
        if cached.age_seconds(funddesk_core::cache::now_seconds()) <= max_age_seconds {
            return Ok(cached.payload.clone());
        }
    }
    match fetch.await {
        Ok(value) => {
            let _ = cache.write(key, &value);
            Ok(value)
        }
        Err(error) => stored.map(|cached| cached.payload).ok_or(error),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketCenterView {
    pub breadth: Option<MarketBreadth>,
    pub flows: Option<MarketFlowSeries>,
    pub sectors: Option<Vec<SectorFlow>>,
    pub errors: Vec<String>,
}

pub async fn market_center(state: &AppState, category: &str, period: &str) -> MarketCenterView {
    let mut view = MarketCenterView {
        breadth: None,
        flows: None,
        sectors: None,
        errors: Vec::new(),
    };
    if category == "overview" {
        let (breadth, flows) =
            tokio::join!(state.market.market_breadth(), market_flows_cached(state));
        match breadth {
            Ok(value) => view.breadth = Some(value),
            Err(error) => view.errors.push(format!("两市统计: {error}")),
        }
        match flows {
            Ok(value) => view.flows = Some(value),
            Err(error) => view.errors.push(format!("资金流: {error}")),
        }
    } else {
        let category = match category {
            "style" => SectorCategory::Style,
            "concept" => SectorCategory::Concept,
            "region" => SectorCategory::Region,
            _ => SectorCategory::Industry,
        };
        let period = match period {
            "five" => SectorPeriod::FiveDays,
            "ten" => SectorPeriod::TenDays,
            _ => SectorPeriod::Today,
        };
        match state.market.sector_flows(category, period).await {
            Ok(value) => view.sectors = Some(value),
            Err(error) => view.errors.push(format!("板块: {error}")),
        }
    }
    view
}

async fn market_flows_cached(state: &AppState) -> Result<MarketFlowSeries, String> {
    const KEY: &str = "market-flows-fallback-v1";
    if let Some(cached) = state.cache.read::<MarketFlowSeries>(KEY) {
        if cached.age_seconds(funddesk_core::cache::now_seconds()) < 600.0
            && cached.payload.source.contains("备用")
        {
            return Ok(cached.payload);
        }
    }
    let series = state
        .market
        .market_flows()
        .await
        .map_err(|error| error.to_string())?;
    if series.source.contains("备用") {
        let _ = state.cache.write(KEY, &series);
    }
    Ok(series)
}

pub async fn index_trend(state: &AppState, index: MarketIndex) -> Result<IndexTrendData, String> {
    state
        .market
        .index_trend(index)
        .await
        .map_err(|error| error.to_string())
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FuturesQuoteView {
    pub instrument: String,
    pub title: String,
    pub kind: String,
    pub builtin: bool,
    pub price: f64,
    pub reference: Option<f64>,
    pub time: f64,
    pub open: Option<f64>,
    pub high: Option<f64>,
    pub low: Option<f64>,
    pub open_interest: Option<f64>,
}

fn builtin_futures_view(quote: FuturesQuote) -> FuturesQuoteView {
    let instrument = quote.instrument;
    FuturesQuoteView {
        instrument: instrument.raw().to_string(),
        title: instrument.title().to_string(),
        kind: instrument.quote_kind().to_string(),
        builtin: true,
        price: quote.price.to_f64().unwrap_or_default(),
        reference: to_f64(quote.reference),
        time: quote.time.0,
        open: to_f64(quote.open),
        high: to_f64(quote.high),
        low: to_f64(quote.low),
        open_interest: to_f64(quote.open_interest),
    }
}

fn custom_futures_view(quote: CustomFuturesQuote, title: &str) -> FuturesQuoteView {
    FuturesQuoteView {
        instrument: quote.symbol,
        title: if title.trim().is_empty() {
            quote.name
        } else {
            title.to_string()
        },
        kind: "外盘期货 · 新浪".to_string(),
        builtin: false,
        price: quote.price.to_f64().unwrap_or_default(),
        reference: to_f64(quote.reference),
        time: quote.time.0,
        open: to_f64(quote.open),
        high: to_f64(quote.high),
        low: to_f64(quote.low),
        open_interest: to_f64(quote.open_interest),
    }
}

pub async fn futures_quotes(state: &AppState) -> Result<Vec<FuturesQuoteView>, String> {
    let custom_items = state.custom_futures.lock().unwrap().clone();
    let builtin = state.market.futures_quotes().await;
    let symbols = custom_items
        .iter()
        .map(|item| item.symbol.clone())
        .collect::<Vec<_>>();
    let custom = if symbols.is_empty() {
        Vec::new()
    } else {
        state
            .market
            .custom_futures_quotes(&symbols)
            .await
            .unwrap_or_default()
    };
    let mut views = builtin
        .as_ref()
        .map(|quotes| {
            quotes
                .iter()
                .cloned()
                .map(builtin_futures_view)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    for item in custom_items {
        if let Some(quote) = custom
            .iter()
            .find(|quote| quote.symbol == item.symbol)
            .cloned()
        {
            views.push(custom_futures_view(quote, &item.title));
        }
    }
    if views.is_empty() {
        return Err(builtin
            .err()
            .map(|error| error.to_string())
            .unwrap_or_else(|| "暂无期货报价".to_string()));
    }
    Ok(views)
}

pub async fn futures_intraday(state: &AppState, raw: &str) -> Result<FuturesIntraday, String> {
    state
        .market
        .futures_intraday_raw(raw)
        .await
        .map_err(|error| error.to_string())
}

pub async fn add_futures(
    state: &AppState,
    symbol: &str,
    title: &str,
) -> Result<Vec<FuturesQuoteView>, String> {
    let symbol = symbol.trim().to_ascii_uppercase();
    if symbol.is_empty()
        || symbol.len() > 12
        || !symbol.bytes().all(|byte| byte.is_ascii_alphanumeric())
    {
        return Err("期货代码只能包含字母和数字".to_string());
    }
    if FuturesInstrument::ALL
        .iter()
        .any(|instrument| instrument.raw() == symbol)
    {
        return Err("该品种已在默认列表中".to_string());
    }
    if state
        .custom_futures
        .lock()
        .unwrap()
        .iter()
        .any(|item| item.symbol == symbol)
    {
        return Err("该品种已在自选期货中".to_string());
    }
    let quote = state
        .market
        .custom_futures_quotes(std::slice::from_ref(&symbol))
        .await
        .map_err(|_| "未找到该期货代码，或当前没有报价".to_string())?
        .into_iter()
        .next()
        .ok_or_else(|| "未找到该期货代码".to_string())?;
    let title = if title.trim().is_empty() {
        quote.name
    } else {
        title.trim().to_string()
    };
    {
        let mut items = state.custom_futures.lock().unwrap();
        items.push(CustomFutures { symbol, title });
        save_custom_futures(&state.storage, &items);
    }
    futures_quotes(state).await
}

pub async fn remove_futures(
    state: &AppState,
    symbol: &str,
) -> Result<Vec<FuturesQuoteView>, String> {
    if FuturesInstrument::ALL
        .iter()
        .any(|instrument| instrument.raw() == symbol)
    {
        return Err("默认品种不能移除".to_string());
    }
    {
        let mut items = state.custom_futures.lock().unwrap();
        let before = items.len();
        items.retain(|item| item.symbol != symbol);
        if items.len() == before {
            return Err("未找到该自选期货".to_string());
        }
        save_custom_futures(&state.storage, &items);
    }
    futures_quotes(state).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FuturesDetailView {
    pub instrument: String,
    pub title: String,
    pub quote: Option<FuturesQuoteView>,
    pub intraday: Option<FuturesIntraday>,
    pub daily: Vec<FuturesCandle>,
    pub weekly: Vec<FuturesCandle>,
    pub monthly: Vec<FuturesCandle>,
    pub five: Option<FuturesFiveSessions>,
    pub errors: Vec<String>,
}

pub async fn futures_detail(state: &AppState, raw: &str) -> Result<FuturesDetailView, String> {
    let instrument = FuturesInstrument::ALL
        .into_iter()
        .find(|instrument| instrument.raw() == raw);
    let custom = state
        .custom_futures
        .lock()
        .unwrap()
        .iter()
        .find(|item| item.symbol == raw)
        .cloned();
    let title = instrument
        .map(|instrument| instrument.title().to_string())
        .or_else(|| custom.as_ref().map(|item| item.title.clone()))
        .ok_or_else(|| "未知期货品种".to_string())?;
    if let Some(instrument) = instrument {
        let quotes = state.market.futures_quotes().await;
        let (quotes, intraday, daily, five) = tokio::join!(
            async { quotes },
            state.market.futures_intraday(instrument),
            state.market.futures_daily(instrument),
            state.market.futures_five_sessions(instrument, None)
        );
        let mut errors = Vec::new();
        if let Err(error) = &intraday {
            errors.push(format!("分时: {error}"));
        }
        if let Err(error) = &daily {
            errors.push(format!("日 K: {error}"));
        }
        if let Err(error) = &five {
            errors.push(format!("五日: {error}"));
        }
        if let Err(error) = &quotes {
            errors.push(format!("报价: {error}"));
        }
        let daily = daily.unwrap_or_default();
        let weekly = FuturesCandle::aggregate(&daily, funddesk_core::market::CandlePeriod::Weekly);
        let monthly =
            FuturesCandle::aggregate(&daily, funddesk_core::market::CandlePeriod::Monthly);
        return Ok(FuturesDetailView {
            instrument: instrument.raw().to_string(),
            title,
            quote: quotes
                .ok()
                .unwrap_or_default()
                .into_iter()
                .find(|quote| quote.instrument == instrument)
                .map(builtin_futures_view),
            intraday: intraday.ok(),
            daily,
            weekly,
            monthly,
            five: five.ok(),
            errors,
        });
    }
    let custom_symbol = vec![raw.to_string()];
    let (quote, intraday, daily) = tokio::join!(
        state.market.custom_futures_quotes(&custom_symbol),
        state.market.futures_intraday_raw(raw),
        state.market.futures_daily_raw(raw)
    );
    let mut errors = Vec::new();
    if let Err(error) = &intraday {
        errors.push(format!("分时: {error}"));
    }
    if let Err(error) = &daily {
        errors.push(format!("日 K: {error}"));
    }
    if let Err(error) = &quote {
        errors.push(format!("报价: {error}"));
    }
    let daily = daily.unwrap_or_default();
    let weekly = FuturesCandle::aggregate(&daily, funddesk_core::market::CandlePeriod::Weekly);
    let monthly = FuturesCandle::aggregate(&daily, funddesk_core::market::CandlePeriod::Monthly);
    let five = five_sessions_from_daily(&daily);
    let quote = quote
        .ok()
        .and_then(|quotes| quotes.into_iter().next())
        .map(|quote| custom_futures_view(quote, &title));
    Ok(FuturesDetailView {
        instrument: raw.to_string(),
        title,
        quote,
        intraday: intraday.ok(),
        daily,
        weekly,
        monthly,
        five,
        errors,
    })
}

fn five_sessions_from_daily(candles: &[FuturesCandle]) -> Option<FuturesFiveSessions> {
    if candles.len() < 5 {
        return None;
    }
    let sessions = candles
        .iter()
        .rev()
        .take(5)
        .rev()
        .map(|candle| FuturesSessionPrices {
            day: candle.day,
            prices: vec![candle.close],
        })
        .collect::<Vec<_>>();
    Some(FuturesFiveSessions {
        sessions,
        is_minute_series: false,
        reference: candles.iter().rev().nth(5).map(|candle| candle.close),
    })
}

pub fn journal_records(state: &AppState, code: &str) -> Vec<PositionRecord> {
    state
        .board
        .lock()
        .unwrap()
        .journals
        .as_ref()
        .and_then(|journals| journals.get(code))
        .cloned()
        .unwrap_or_default()
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JournalInput {
    pub code: String,
    pub action: String,
    pub day: String,
    pub shares: Option<f64>,
    pub price: Option<f64>,
    pub fee: f64,
    pub distribution: Option<f64>,
}

pub fn add_journal(state: &AppState, input: JournalInput) -> Result<BoardView, String> {
    let change = journal_change(&input)?;
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    let index = board
        .holdings
        .iter()
        .position(|holding| holding.id() == input.code)
        .ok_or_else(|| "未找到基金".to_string())?;
    let (updated, record) = change
        .apply(&board.holdings[index], &day(chrono::Utc::now()))
        .map_err(|error| error.to_string())?;
    board.holdings[index] = updated;
    board
        .journals
        .get_or_insert_with(HashMap::new)
        .entry(input.code)
        .or_default()
        .push(record);
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

pub fn replace_journal(
    state: &AppState,
    id: &str,
    input: JournalInput,
) -> Result<BoardView, String> {
    let change = journal_change(&input)?;
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    board
        .replace_journal_record(&input.code, id, &change, &day(chrono::Utc::now()))
        .map_err(|error| error.to_string())?;
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

fn journal_change(input: &JournalInput) -> Result<funddesk_core::journal::PositionChange, String> {
    let action = match input.action.as_str() {
        "sell" => PositionAction::Sell,
        "distribution" => PositionAction::Distribution,
        _ => PositionAction::Buy,
    };
    let mut change = funddesk_core::journal::PositionChange::new(action, &input.day);
    change.shares = input.shares.and_then(Decimal::from_f64_retain);
    change.price = input.price.and_then(Decimal::from_f64_retain);
    change.fee = Decimal::from_f64_retain(input.fee).unwrap_or_default();
    change.distribution = input.distribution.and_then(Decimal::from_f64_retain);
    Ok(change)
}

pub fn delete_journal(state: &AppState, code: &str, id: &str) -> Result<BoardView, String> {
    let mut current = state.board.lock().unwrap();
    let mut board = current.clone();
    board
        .delete_journal_record(code, id)
        .map_err(|error| error.to_string())?;
    persist_board(&state.storage, &mut current, &board)?;
    drop(current);
    Ok(build_view(&board, &state.storage, chrono::Utc::now()))
}

pub fn try_begin_refresh(state: &AppState) -> bool {
    state
        .refreshing
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
}

pub fn clear_refresh_flag(state: &AppState) {
    state.refreshing.store(false, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_writes_keep_persisted_holding_and_journal_and_allow_retry() {
        let root = std::env::temp_dir().join(format!(
            "funddesk-save-test-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        std::fs::create_dir(&root).unwrap();
        let storage = BoardStorage::new(&root);
        let mut board = Board::default();
        let code = "123456";
        board.add_holding(
            Fund {
                code: code.into(),
                name: "虚构基金".into(),
                kind: "股票".into(),
                initials: String::new(),
                pinyin: String::new(),
            },
            None,
        );
        let state = AppState {
            cache: ResearchCache::new(&root),
            storage,
            market: MarketClient::with_sources(Sources::default()).unwrap(),
            board: Mutex::new(board),
            catalog: Mutex::default(),
            custom_futures: Mutex::default(),
            shanghai_quote: Mutex::default(),
            source_error: Mutex::default(),
            refreshing: AtomicBool::default(),
        };
        let input = JournalInput {
            code: code.into(),
            action: "buy".into(),
            day: "2026-01-01".into(),
            shares: Some(100.0),
            price: Some(2.0),
            fee: 0.0,
            distribution: None,
        };
        let obstruction = root.join("board.json.tmp");
        std::fs::create_dir(&obstruction).unwrap();
        let initial = state.board.lock().unwrap().clone();
        assert!(add_journal(&state, input.clone()).is_err());
        assert_eq!(*state.board.lock().unwrap(), initial);

        std::fs::remove_dir(&obstruction).unwrap();
        add_journal(&state, input.clone()).unwrap();
        let saved = state.storage.open().board;
        let id = &saved.journals.as_ref().unwrap()[code][0].id;
        std::fs::create_dir(&obstruction).unwrap();
        assert!(set_holding(&state, code, Some(25.0), Some(1.0)).is_err());
        assert!(replace_journal(&state, id, input).is_err());
        assert!(delete_journal(&state, code, id).is_err());
        assert_eq!(*state.board.lock().unwrap(), saved);
        assert_eq!(state.storage.open().board, saved);

        std::fs::remove_dir(&obstruction).unwrap();
        delete_journal(&state, code, id).unwrap();
        assert_eq!(state.storage.open().board.journal_count(), 0);
        std::fs::remove_dir_all(&root).unwrap();
    }
}
