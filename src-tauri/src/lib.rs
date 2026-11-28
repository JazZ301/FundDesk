mod service;
#[cfg(target_os = "macos")]
mod tray_quotes;

use funddesk_core::market::{
    index_session, FuturesIntraday, IndexQuote, IndexTradingSession, IndexTrendData, MarketIndex,
};
use funddesk_core::metrics::Portfolio;
use funddesk_core::model::{Fund, MenuBarItem, PositionRecord};
use funddesk_core::provider::now_text;
use rust_decimal::Decimal;
use std::io::Write;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tauri_plugin_dialog::DialogExt;

use service::{
    AppState, BoardView, BootstrapView, FundDetailView, FuturesDetailView, FuturesQuoteView,
    MarketCenterView,
};

#[tauri::command]
fn bootstrap(state: State<'_, AppState>) -> BootstrapView {
    service::bootstrap(&state)
}

#[tauri::command]
fn data_sources(state: State<'_, AppState>) -> service::DataSourceStatus {
    service::data_source_status(&state)
}

#[tauri::command]
fn data_sources_text(state: State<'_, AppState>) -> Result<String, String> {
    service::data_sources_text(&state)
}

#[tauri::command]
fn save_data_sources(
    state: State<'_, AppState>,
    text: String,
) -> Result<service::DataSourceStatus, String> {
    service::save_data_sources(&state, &text)
}

#[tauri::command]
fn clear_data_sources(state: State<'_, AppState>) -> Result<service::DataSourceStatus, String> {
    service::clear_data_sources(&state)
}

#[tauri::command]
async fn refresh_board(app: AppHandle) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    if !service::try_begin_refresh(&state) {
        // A background refresh is already running. Return the current view
        // instead of surfacing an error for an ordinary manual refresh.
        return Ok(service::bootstrap(&state).board);
    }
    let view = service::refresh_board(&state, true).await;
    service::clear_refresh_flag(&state);
    let _ = app.emit("board://updated", &view);
    update_tray(&app);
    Ok(view)
}

#[tauri::command]
async fn indices(app: AppHandle) -> Result<Vec<IndexQuote>, String> {
    let state = app.state::<AppState>();
    let quotes = state
        .market
        .indices()
        .await
        .map_err(|error| error.to_string())?;
    if let Some(shanghai) = quotes
        .iter()
        .find(|quote| quote.index == MarketIndex::ShanghaiComposite)
    {
        *state.shanghai_quote.lock().unwrap() = Some(shanghai.clone());
    }
    drop(state);
    update_tray(&app);
    let _ = app.emit("market://indices", &quotes);
    Ok(quotes)
}

#[derive(serde::Serialize)]
struct IndexTrendView {
    #[serde(flatten)]
    trend: IndexTrendData,
    session: IndexTradingSession,
}

#[tauri::command]
async fn index_trend(app: AppHandle, index: String) -> Result<IndexTrendView, String> {
    let index = MarketIndex::from_raw(&index).ok_or_else(|| "未知指数".to_string())?;
    let state = app.state::<AppState>();
    let trend = service::index_trend(&state, index).await?;
    Ok(IndexTrendView {
        trend,
        session: index_session(index),
    })
}

#[tauri::command]
async fn search_funds(app: AppHandle, keyword: String) -> Result<Vec<Fund>, String> {
    let state = app.state::<AppState>();
    service::search_funds(&state, &keyword).await
}

#[tauri::command]
async fn add_fund(
    app: AppHandle,
    code: String,
    group: Option<String>,
) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::add_fund(&state, &code, group.as_deref()).await?;
    let _ = app.emit("board://updated", &view);
    if group.is_some() {
        let handle = app.clone();
        tauri::async_runtime::spawn(async move {
            let state = handle.state::<AppState>();
            if service::refresh_observations(&state).await {
                let board = service::bootstrap(&state).board;
                let _ = handle.emit("board://updated", &board);
            }
        });
    }
    Ok(view)
}

#[tauri::command]
fn remove_fund(app: AppHandle, code: String) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::remove_fund(&state, &code)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

#[tauri::command]
fn set_holding(
    app: AppHandle,
    code: String,
    shares: Option<f64>,
    cost: Option<f64>,
) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::set_holding(&state, &code, shares, cost)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

const MAX_PLUGIN_CONFIG_BYTES: u64 = 8 * 1024 * 1024;

#[tauri::command]
async fn read_data_source_file(window: tauri::WebviewWindow) -> Result<Option<String>, String> {
    use std::io::Read;

    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = window
            .dialog()
            .file()
            .add_filter("数据源配置", &["json", "txt"])
            .set_parent(&window)
            .set_title("选择数据源配置文件")
            .blocking_pick_file()
        else {
            return Ok(None);
        };
        let path = file.into_path().map_err(|error| error.to_string())?;
        let mut bytes = Vec::new();
        std::fs::File::open(path)
            .and_then(|file| {
                file.take(MAX_PLUGIN_CONFIG_BYTES + 1)
                    .read_to_end(&mut bytes)
            })
            .map_err(|error| format!("读取数据源配置失败：{error}"))?;
        if bytes.len() as u64 > MAX_PLUGIN_CONFIG_BYTES {
            return Err("数据源配置超过 8 MB。".to_string());
        }
        String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| "请选择 UTF-8 编码的数据源配置。".to_string())
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn read_plugin_config_file(window: tauri::WebviewWindow) -> Result<Option<String>, String> {
    use std::io::Read;

    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = window
            .dialog()
            .file()
            .add_filter("自选基金助手配置", &["json", "txt"])
            .set_parent(&window)
            .set_title("选择自选基金助手配置文件")
            .blocking_pick_file()
        else {
            return Ok(None);
        };
        let path = file.into_path().map_err(|error| error.to_string())?;
        let mut bytes = Vec::new();
        std::fs::File::open(path)
            .and_then(|file| {
                file.take(MAX_PLUGIN_CONFIG_BYTES + 1)
                    .read_to_end(&mut bytes)
            })
            .map_err(|error| format!("读取配置文件失败：{error}"))?;
        if bytes.len() as u64 > MAX_PLUGIN_CONFIG_BYTES {
            return Err("配置文件超过 8 MB。".to_string());
        }
        String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| "请选择 UTF-8 编码的配置文件。".to_string())
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn export_plugin_config_file(window: tauri::WebviewWindow) -> Result<bool, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let text = service::export_plugin_config(&window.state::<AppState>())?;
        let Some(file) = window
            .dialog()
            .file()
            .add_filter("JSON 配置文件", &["json"])
            .set_parent(&window)
            .set_file_name("自选基金助手配置文件.json")
            .set_title("导出自选基金助手配置文件")
            .blocking_save_file()
        else {
            return Ok(false);
        };
        let path = file.into_path().map_err(|error| error.to_string())?;
        std::fs::write(path, text).map_err(|error| format!("写入配置文件失败：{error}"))?;
        Ok(true)
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
fn export_plugin_config_text(state: State<'_, AppState>) -> Result<String, String> {
    service::export_plugin_config(&state)
}

#[tauri::command]
async fn import_plugin_config(
    app: AppHandle,
    text: String,
    overwrite: bool,
) -> Result<service::PluginImportResult, String> {
    if text.len() as u64 > MAX_PLUGIN_CONFIG_BYTES {
        return Err("配置文本超过 8 MB。".to_string());
    }
    let result = service::import_plugin_config(&app.state::<AppState>(), &text, overwrite).await?;
    let _ = app.emit("board://updated", &result.board);
    Ok(result)
}

#[tauri::command]
fn save_settings(app: AppHandle, theme: String, interval: i32) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::save_settings(&state, &theme, interval)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

#[tauri::command]
fn save_menu_bar(app: AppHandle, visible: bool, items: Vec<String>) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::save_menu_bar(&state, visible, &items)?;
    let _ = app.emit("board://updated", &view);
    update_tray(&app);
    Ok(view)
}

#[tauri::command]
fn save_visible_columns(app: AppHandle, columns: Vec<String>) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::save_visible_columns(&state, &columns)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

#[tauri::command]
fn reorder_columns(app: AppHandle, columns: Vec<String>) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::reorder_columns(&state, &columns)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

#[tauri::command]
fn move_fund(
    app: AppHandle,
    code: String,
    target: String,
    after: bool,
    visible: Vec<String>,
) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::move_fund(&state, &code, &target, after, &visible)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

#[tauri::command]
fn set_groups(app: AppHandle, code: String, groups: Vec<String>) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::set_groups(&state, &code, &groups)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

#[tauri::command]
fn move_detail_tab(app: AppHandle, source: String, target: String) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::move_detail_tab(&state, &source, &target)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

#[tauri::command]
async fn fund_detail(app: AppHandle, code: String) -> Result<FundDetailView, String> {
    let state = app.state::<AppState>();
    service::fund_detail(&state, &code).await
}

#[tauri::command]
async fn fund_disclosure(
    app: AppHandle,
    code: String,
) -> Result<funddesk_core::research::FundDisclosure, String> {
    let state = app.state::<AppState>();
    service::fund_disclosure(&state, &code).await
}

#[tauri::command]
async fn market_center(app: AppHandle, category: String, period: String) -> MarketCenterView {
    let state = app.state::<AppState>();
    service::market_center(&state, &category, &period).await
}

#[tauri::command]
async fn futures_quotes(app: AppHandle) -> Result<Vec<FuturesQuoteView>, String> {
    let state = app.state::<AppState>();
    service::futures_quotes(&state).await
}

#[tauri::command]
async fn add_futures(
    app: AppHandle,
    symbol: String,
    title: String,
) -> Result<Vec<FuturesQuoteView>, String> {
    let state = app.state::<AppState>();
    service::add_futures(&state, &symbol, &title).await
}

#[tauri::command]
async fn remove_futures(app: AppHandle, symbol: String) -> Result<Vec<FuturesQuoteView>, String> {
    let state = app.state::<AppState>();
    service::remove_futures(&state, &symbol).await
}

#[tauri::command]
async fn futures_intraday(app: AppHandle, symbol: String) -> Result<FuturesIntraday, String> {
    let state = app.state::<AppState>();
    service::futures_intraday(&state, &symbol).await
}

#[tauri::command]
async fn futures_detail(app: AppHandle, symbol: String) -> Result<FuturesDetailView, String> {
    let state = app.state::<AppState>();
    service::futures_detail(&state, &symbol).await
}

#[tauri::command]
fn journal_records(state: State<'_, AppState>, code: String) -> Vec<PositionRecord> {
    service::journal_records(&state, &code)
}

#[tauri::command]
fn add_journal(app: AppHandle, payload: service::JournalInput) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::add_journal(&state, payload)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

#[tauri::command]
fn delete_journal(app: AppHandle, code: String, id: String) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::delete_journal(&state, &code, &id)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

#[tauri::command]
fn replace_journal(
    app: AppHandle,
    id: String,
    payload: service::JournalInput,
) -> Result<BoardView, String> {
    let state = app.state::<AppState>();
    let view = service::replace_journal(&state, &id, payload)?;
    let _ = app.emit("board://updated", &view);
    Ok(view)
}

fn show_main(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    let _ = app.show();

    let window = app.get_webview_window("main");
    trace(&format!("show_main found={}", window.is_some()));
    if let Some(window) = window {
        let shown = window.show();
        let unminimized = window.unminimize();
        let focused = window.set_focus();
        trace(&format!(
            "show={shown:?} unminimize={unminimized:?} focus={focused:?} visible={:?}",
            window.is_visible()
        ));
    }
}

fn trace(message: &str) {
    let directory = std::env::var_os("FUND_DESK_DATA_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(funddesk_core::storage::default_data_dir);
    let _ = std::fs::create_dir_all(&directory);
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(directory.join("trace.log"))
    {
        let _ = writeln!(file, "{} {message}", now_text());
    }
}

const TRAY_LABEL: &str = "上证";
const TRAY_PROFIT_LABEL: &str = "持仓";

fn tone_of(value: Decimal) -> i8 {
    match value.cmp(&Decimal::ZERO) {
        std::cmp::Ordering::Greater => 1,
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
    }
}

fn tray_points_text(quote: &IndexQuote) -> String {
    let text = format!("{:.2}", quote.value.abs());
    if quote.value.is_sign_negative() && !quote.value.is_zero() {
        format!("-{text}")
    } else {
        text
    }
}

fn tray_rate_text(quote: &IndexQuote) -> String {
    let percent = quote
        .rate
        .round_dp_with_strategy(2, rust_decimal::RoundingStrategy::MidpointAwayFromZero);
    match percent.cmp(&Decimal::ZERO) {
        std::cmp::Ordering::Greater => format!("+{percent}%"),
        std::cmp::Ordering::Less => format!("{percent}%"),
        std::cmp::Ordering::Equal => "0.00%".to_string(),
    }
}

fn group_thousands(value: &str) -> String {
    let (integer, fraction) = value.split_once('.').unwrap_or((value, ""));
    let mut grouped = String::new();
    for (index, digit) in integer.chars().rev().enumerate() {
        if index > 0 && index % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    let integer = grouped.chars().rev().collect::<String>();
    if fraction.is_empty() {
        integer
    } else {
        format!("{integer}.{fraction}")
    }
}

fn tray_profit_text(profit: Option<Decimal>) -> String {
    let Some(profit) = profit else {
        return "¥—".to_string();
    };
    let rounded =
        profit.round_dp_with_strategy(2, rust_decimal::RoundingStrategy::MidpointAwayFromZero);
    let amount = group_thousands(&format!("{:.2}", rounded.abs()));
    match rounded.cmp(&Decimal::ZERO) {
        std::cmp::Ordering::Greater => format!("¥+{amount}"),
        std::cmp::Ordering::Less => format!("¥-{amount}"),
        std::cmp::Ordering::Equal => format!("¥{amount}"),
    }
}

#[derive(Clone, Debug, PartialEq)]
struct TraySegment {
    text: String,
    tone: i8,
}

#[derive(Clone, Debug, PartialEq)]
struct TrayContent {
    prefix: &'static str,
    segments: Vec<TraySegment>,
}

fn tray_content(
    quote: Option<&IndexQuote>,
    items: &[MenuBarItem],
    day_profit: Option<Decimal>,
) -> TrayContent {
    let has_index = items
        .iter()
        .any(|item| matches!(item, MenuBarItem::Points | MenuBarItem::Rate));
    let prefix = if has_index {
        TRAY_LABEL
    } else if items.contains(&MenuBarItem::DayProfit) {
        TRAY_PROFIT_LABEL
    } else {
        TRAY_LABEL
    };
    let mut segments = Vec::new();
    for item in MenuBarItem::ALL {
        if !items.contains(&item) {
            continue;
        }
        match item {
            MenuBarItem::Points => {
                if let Some(quote) = quote {
                    segments.push(TraySegment {
                        text: tray_points_text(quote),
                        tone: tone_of(quote.change),
                    });
                }
            }
            MenuBarItem::Rate => {
                if let Some(quote) = quote {
                    segments.push(TraySegment {
                        text: tray_rate_text(quote),
                        tone: tone_of(quote.rate),
                    });
                }
            }
            MenuBarItem::DayProfit => segments.push(TraySegment {
                text: tray_profit_text(day_profit),
                tone: day_profit.map(tone_of).unwrap_or(0),
            }),
        }
    }
    TrayContent { prefix, segments }
}

fn tray_tooltip(
    quote: Option<&IndexQuote>,
    items: &[MenuBarItem],
    day_profit: Option<Decimal>,
) -> String {
    let content = tray_content(quote, items, day_profit);
    let mut parts = vec![content.prefix.to_string()];
    parts.extend(content.segments.into_iter().map(|segment| segment.text));
    let mut tooltip = parts.join(" ");
    if let Some(quote) = quote {
        tooltip.push('\n');
        tooltip.push_str(&quote.timestamp);
    }
    tooltip
}

#[cfg(target_os = "macos")]
fn tray_rows(
    quote: Option<&IndexQuote>,
    items: &[MenuBarItem],
    day_profit: Option<Decimal>,
) -> tray_quotes::Rows {
    let content = tray_content(quote, items, day_profit);
    tray_quotes::Rows {
        prefix: Some(content.prefix.to_string()),
        segments: content
            .segments
            .into_iter()
            .map(|segment| tray_quotes::Segment {
                text: segment.text,
                tone: segment.tone,
            })
            .collect(),
    }
}

fn update_tray(app: &AppHandle) {
    let Some(tray) = app.tray_by_id("main") else {
        return;
    };
    let (visible, items, day_profit, quote) = {
        let state = app.state::<AppState>();
        let board = state.board.lock().unwrap();
        let visible = board.menu_bar_visible_value();
        let items = board.menu_bar_items_value();
        let day_profit = Portfolio::new(&board, chrono::Utc::now()).day_profit();
        drop(board);
        let quote = state.shanghai_quote.lock().unwrap().clone();
        (visible, items, day_profit, quote)
    };
    let tooltip = if visible {
        tray_tooltip(quote.as_ref(), &items, day_profit)
    } else {
        "基金看板".to_string()
    };
    let _ = tray.set_tooltip(Some(&tooltip));
    #[cfg(target_os = "macos")]
    {
        tray_quotes::apply(&tray, &tray_rows(quote.as_ref(), &items, day_profit));
        tray_quotes::set_visible(&tray, visible);
    }
}

fn start_market_loop(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            let quotes = {
                let state = app.state::<AppState>();
                state.market.indices().await
            };
            if let Ok(quotes) = quotes {
                if let Some(shanghai) = quotes
                    .iter()
                    .find(|quote| quote.index == MarketIndex::ShanghaiComposite)
                {
                    let state = app.state::<AppState>();
                    *state.shanghai_quote.lock().unwrap() = Some(shanghai.clone());
                }
                update_tray(&app);
                let _ = app.emit("market://indices", &quotes);
            }
            tokio::time::sleep(Duration::from_secs(60)).await;
        }
    });
}

fn start_board_loop(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut last = tokio::time::Instant::now() - Duration::from_secs(120);
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let interval = {
                let state = app.state::<AppState>();
                let board = state.board.lock().unwrap();
                board.refresh_interval_value().max(5) as u64
            };
            if last.elapsed().as_secs() < interval {
                continue;
            }
            last = tokio::time::Instant::now();
            let state = app.state::<AppState>();
            if state.refreshing.swap(true, Ordering::SeqCst) {
                continue;
            }
            let view = service::refresh_board(&state, false).await;
            state.refreshing.store(false, Ordering::SeqCst);
            let _ = app.emit("board://updated", &view);
            update_tray(&app);
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            trace("single-instance callback");
            show_main(app);
        }))
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::new())
        .invoke_handler(tauri::generate_handler![
            bootstrap,
            data_sources,
            data_sources_text,
            save_data_sources,
            clear_data_sources,
            read_data_source_file,
            refresh_board,
            indices,
            index_trend,
            search_funds,
            add_fund,
            remove_fund,
            set_holding,
            read_plugin_config_file,
            export_plugin_config_file,
            export_plugin_config_text,
            import_plugin_config,
            save_settings,
            save_menu_bar,
            save_visible_columns,
            reorder_columns,
            move_fund,
            set_groups,
            move_detail_tab,
            fund_detail,
            fund_disclosure,
            market_center,
            futures_quotes,
            add_futures,
            remove_futures,
            futures_intraday,
            futures_detail,
            journal_records,
            add_journal,
            replace_journal,
            delete_journal
        ])
        .setup(|app| {
            let open = MenuItem::with_id(app, "open", "打开看板", true, None::<&str>)?;
            let refresh = MenuItem::with_id(app, "refresh", "刷新行情", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &refresh, &quit])?;

            let builder = TrayIconBuilder::with_id("main");
            #[cfg(not(target_os = "macos"))]
            let builder = builder.icon(
                tauri::image::Image::from_bytes(include_bytes!("../icons/32x32.png"))
                    .unwrap_or_else(|_| app.default_window_icon().cloned().expect("缺少应用图标")),
            );

            let builder = builder
                .tooltip("基金看板")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "open" => show_main(app),
                    "refresh" => {
                        let _ = app.emit("app://refresh", ());
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main(tray.app_handle());
                    }
                });

            builder.build(app)?;
            update_tray(app.handle());
            start_market_loop(app.handle().clone());
            start_board_loop(app.handle().clone());
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .build(tauri::generate_context!())
        .expect("启动基金看板失败");

    app.run(|app, event| {
        #[cfg(target_os = "macos")]
        if let tauri::RunEvent::Reopen { .. } = event {
            show_main(app);
        }
        #[cfg(not(target_os = "macos"))]
        let _ = (app, event);
    });
}

#[cfg(test)]
mod tests {
    use super::{
        group_thousands, tray_content, tray_points_text, tray_profit_text, tray_rate_text,
    };
    use funddesk_core::market::{IndexQuote, MarketIndex};
    use funddesk_core::model::MenuBarItem;
    use rust_decimal::Decimal;

    fn quote(value: i64, change: i64, rate: i64) -> IndexQuote {
        IndexQuote {
            index: MarketIndex::ShanghaiComposite,
            value: Decimal::new(value, 2),
            change: Decimal::new(change, 2),
            rate: Decimal::new(rate, 2),
            timestamp: "2026-11-27 14:30:00".to_string(),
            turnover: None,
        }
    }

    #[test]
    fn index_points_have_no_thousands_separator() {
        assert_eq!(tray_points_text(&quote(355527, 5507, 157)), "3555.27");
    }

    #[test]
    fn rate_is_signed_and_percented() {
        assert_eq!(tray_rate_text(&quote(355527, 5507, 157)), "+1.57%");
        assert_eq!(tray_rate_text(&quote(355527, -5507, -157)), "-1.57%");
        assert_eq!(tray_rate_text(&quote(355527, 0, 0)), "0.00%");
    }

    #[test]
    fn profit_has_currency_sign_and_separators() {
        assert_eq!(
            tray_profit_text(Some(Decimal::new(123456, 2))),
            "¥+1,234.56"
        );
        assert_eq!(
            tray_profit_text(Some(Decimal::new(-123456, 2))),
            "¥-1,234.56"
        );
        assert_eq!(tray_profit_text(Some(Decimal::ZERO)), "¥0.00");
        assert_eq!(tray_profit_text(None), "¥—");
        assert_eq!(group_thousands("1234567.89"), "1,234,567.89");
    }

    #[test]
    fn content_combines_selected_fields_in_fixed_order() {
        let quote = quote(355527, 5507, 157);
        let content = tray_content(
            Some(&quote),
            &[
                MenuBarItem::DayProfit,
                MenuBarItem::Rate,
                MenuBarItem::Points,
            ],
            Some(Decimal::new(123456, 2)),
        );
        assert_eq!(content.prefix, "上证");
        assert_eq!(
            content
                .segments
                .iter()
                .map(|segment| segment.text.as_str())
                .collect::<Vec<_>>(),
            vec!["3555.27", "+1.57%", "¥+1,234.56"]
        );
        assert_eq!(
            content
                .segments
                .iter()
                .map(|segment| segment.tone)
                .collect::<Vec<_>>(),
            vec![1, 1, 1]
        );
    }

    #[test]
    fn profit_only_uses_holding_prefix() {
        let content = tray_content(
            None,
            &[MenuBarItem::DayProfit],
            Some(Decimal::new(-1250, 2)),
        );
        assert_eq!(content.prefix, "持仓");
        assert_eq!(content.segments.len(), 1);
        assert_eq!(content.segments[0].text, "¥-12.50");
        assert_eq!(content.segments[0].tone, -1);
    }

    #[test]
    fn index_fields_wait_for_first_quote() {
        let content = tray_content(None, &[MenuBarItem::Points, MenuBarItem::Rate], None);
        assert_eq!(content.prefix, "上证");
        assert!(content.segments.is_empty());
    }
}
