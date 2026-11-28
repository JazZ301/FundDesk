use crate::clock::{day, timestamp};
use crate::csv::decimal;
use crate::model::{Estimate, Fund, Nav};
use crate::provider::MarketClient;
use crate::provider::ProviderError;
use crate::sources::Sources;
use crate::swift::SwiftDate;
use chrono::{DateTime, Datelike, NaiveDate, TimeZone, Timelike, Utc};
use chrono_tz::Asia::Shanghai;
use encoding_rs::GBK;
use futures::future::join_all;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::str::FromStr;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MarketIndex {
    #[serde(rename = "sh000001")]
    ShanghaiComposite,
    #[serde(rename = "sh000300")]
    Csi300,
    #[serde(rename = "sz399001")]
    ShenzhenComposite,
    #[serde(rename = "sz399006")]
    Chinext,
    #[serde(rename = "hkHSI")]
    HangSeng,
    #[serde(rename = "usINX")]
    Sp500,
    #[serde(rename = "usIXIC")]
    Nasdaq,
}

impl MarketIndex {
    pub const DISPLAY_ORDER: [Self; 7] = [
        Self::ShanghaiComposite,
        Self::Csi300,
        Self::ShenzhenComposite,
        Self::Chinext,
        Self::HangSeng,
        Self::Sp500,
        Self::Nasdaq,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::ShanghaiComposite => "sh000001",
            Self::Csi300 => "sh000300",
            Self::ShenzhenComposite => "sz399001",
            Self::Chinext => "sz399006",
            Self::HangSeng => "hkHSI",
            Self::Sp500 => "usINX",
            Self::Nasdaq => "usIXIC",
        }
    }

    pub fn quote_key(self) -> &'static str {
        if self == Self::HangSeng {
            "r_hkHSI"
        } else {
            self.raw()
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::ShanghaiComposite => "上证指数",
            Self::Csi300 => "沪深300",
            Self::ShenzhenComposite => "深证成指",
            Self::Chinext => "创业板指",
            Self::HangSeng => "恒生指数",
            Self::Sp500 => "标普500",
            Self::Nasdaq => "纳斯达克综合",
        }
    }

    pub fn is_us(self) -> bool {
        matches!(self, Self::Sp500 | Self::Nasdaq)
    }

    pub fn from_raw(value: &str) -> Option<Self> {
        Self::DISPLAY_ORDER
            .into_iter()
            .find(|index| index.raw() == value)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexQuote {
    pub index: MarketIndex,
    #[serde(with = "crate::swift::decimal")]
    pub value: Decimal,
    #[serde(with = "crate::swift::decimal")]
    pub change: Decimal,
    #[serde(with = "crate::swift::decimal")]
    pub rate: Decimal,
    pub timestamp: String,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub turnover: Option<Decimal>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlotPoint {
    pub time: SwiftDate,
    #[serde(with = "crate::swift::decimal")]
    pub value: Decimal,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexTrendData {
    pub source: String,
    pub points: Vec<PlotPoint>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub previous_close: Option<Decimal>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volumes: Option<Vec<PlotPoint>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexTradingWindow {
    pub start_minute: i32,
    pub end_minute: i32,
}

impl IndexTradingWindow {
    pub fn duration(self) -> i32 {
        self.end_minute - self.start_minute
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexAxisMark {
    pub position: i32,
    pub title: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct IndexTradingSession {
    pub time_zone: String,
    pub time_zone_label: String,
    pub windows: Vec<IndexTradingWindow>,
    pub axis_marks: Vec<IndexAxisMark>,
}

impl IndexTradingSession {
    pub fn total_minutes(&self) -> i32 {
        self.windows.iter().map(|window| window.duration()).sum()
    }

    pub fn position(&self, date: DateTime<Utc>) -> Option<i32> {
        let zone: chrono_tz::Tz = self.time_zone.parse().ok()?;
        let local = date.with_timezone(&zone);
        let minute = local.hour() as i32 * 60 + local.minute() as i32;
        let mut offset = 0;
        for window in &self.windows {
            if (window.start_minute..=window.end_minute).contains(&minute) {
                return Some(offset + minute - window.start_minute);
            }
            offset += window.duration();
        }
        None
    }

    pub fn time_label(&self, date: DateTime<Utc>) -> String {
        self.formatted(date, "%H:%M")
    }

    pub fn date_time_label(&self, date: DateTime<Utc>) -> String {
        self.formatted(date, "%m-%d %H:%M")
    }

    pub fn timestamp(&self, day_text: &str, time_text: &str) -> Option<DateTime<Utc>> {
        let zone: chrono_tz::Tz = self.time_zone.parse().ok()?;
        let date = NaiveDate::parse_from_str(day_text, "%Y-%m-%d").ok()?;
        let mut parts = time_text.split(':');
        let hour: u32 = parts.next()?.parse().ok()?;
        let minute: u32 = parts.next()?.parse().ok()?;
        let second: u32 = parts.next().unwrap_or("0").parse().ok()?;
        if hour > 23 || minute > 59 || second > 59 {
            return None;
        }
        let local = date.and_hms_opt(hour, minute, second)?;
        Some(
            zone.from_local_datetime(&local)
                .single()?
                .with_timezone(&Utc),
        )
    }

    fn formatted(&self, date: DateTime<Utc>, format: &str) -> String {
        let Ok(zone) = self.time_zone.parse::<chrono_tz::Tz>() else {
            return String::new();
        };
        date.with_timezone(&zone).format(format).to_string()
    }
}

fn mainland_session() -> IndexTradingSession {
    IndexTradingSession {
        time_zone: "Asia/Shanghai".to_string(),
        time_zone_label: "北京时间".to_string(),
        windows: vec![
            IndexTradingWindow {
                start_minute: 570,
                end_minute: 690,
            },
            IndexTradingWindow {
                start_minute: 780,
                end_minute: 900,
            },
        ],
        axis_marks: vec![
            IndexAxisMark {
                position: 0,
                title: "09:30".to_string(),
            },
            IndexAxisMark {
                position: 60,
                title: "10:30".to_string(),
            },
            IndexAxisMark {
                position: 120,
                title: "11:30/13:00".to_string(),
            },
            IndexAxisMark {
                position: 180,
                title: "14:00".to_string(),
            },
            IndexAxisMark {
                position: 240,
                title: "15:00".to_string(),
            },
        ],
    }
}

fn hong_kong_session() -> IndexTradingSession {
    IndexTradingSession {
        time_zone: "Asia/Hong_Kong".to_string(),
        time_zone_label: "香港时间".to_string(),
        windows: vec![
            IndexTradingWindow {
                start_minute: 570,
                end_minute: 720,
            },
            IndexTradingWindow {
                start_minute: 780,
                end_minute: 960,
            },
        ],
        axis_marks: vec![
            (0, "09:30"),
            (60, "10:30"),
            (120, "11:30"),
            (150, "12:00/13:00"),
            (210, "14:00"),
            (270, "15:00"),
            (330, "16:00"),
        ]
        .into_iter()
        .map(|(position, title)| IndexAxisMark {
            position,
            title: title.to_string(),
        })
        .collect(),
    }
}

fn united_states_session() -> IndexTradingSession {
    IndexTradingSession {
        time_zone: "America/New_York".to_string(),
        time_zone_label: "美东时间".to_string(),
        windows: vec![IndexTradingWindow {
            start_minute: 570,
            end_minute: 960,
        }],
        axis_marks: [
            (0, "09:30"),
            (60, "10:30"),
            (120, "11:30"),
            (180, "12:30"),
            (240, "13:30"),
            (300, "14:30"),
            (360, "15:30"),
            (390, "16:00"),
        ]
        .into_iter()
        .map(|(position, title)| IndexAxisMark {
            position,
            title: title.to_string(),
        })
        .collect(),
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StockQuote {
    #[serde(with = "crate::swift::decimal")]
    pub rate: Decimal,
    pub time: SwiftDate,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum FuturesInstrument {
    #[serde(rename = "VX")]
    Vix,
    #[serde(rename = "CL")]
    WtiOil,
    #[serde(rename = "OIL")]
    BrentOil,
    #[serde(rename = "GC")]
    Gold,
    #[serde(rename = "XAU")]
    SpotGold,
    #[serde(rename = "SI")]
    Silver,
    #[serde(rename = "HG")]
    Copper,
    #[serde(rename = "CAD")]
    LondonCopper,
    #[serde(rename = "CHA50CFD")]
    ChinaA50,
    #[serde(rename = "ES")]
    Sp500,
    #[serde(rename = "YM")]
    Dow,
}

impl FuturesInstrument {
    pub const ALL: [Self; 11] = [
        Self::Vix,
        Self::WtiOil,
        Self::BrentOil,
        Self::Gold,
        Self::SpotGold,
        Self::Silver,
        Self::Copper,
        Self::LondonCopper,
        Self::ChinaA50,
        Self::Sp500,
        Self::Dow,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Vix => "VX",
            Self::WtiOil => "CL",
            Self::BrentOil => "OIL",
            Self::Gold => "GC",
            Self::SpotGold => "XAU",
            Self::Silver => "SI",
            Self::Copper => "HG",
            Self::LondonCopper => "CAD",
            Self::ChinaA50 => "CHA50CFD",
            Self::Sp500 => "ES",
            Self::Dow => "YM",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Vix => "VIX 恐慌指数期货",
            Self::WtiOil => "纽约原油",
            Self::BrentOil => "布伦特原油",
            Self::Gold => "纽约黄金",
            Self::SpotGold => "伦敦金（现货黄金）",
            Self::Silver => "纽约白银",
            Self::Copper => "美铜",
            Self::LondonCopper => "伦铜",
            Self::ChinaA50 => "富时中国 A50 期货",
            Self::Sp500 => "标普 500 指数期货",
            Self::Dow => "道琼斯指数期货",
        }
    }

    pub fn quote_kind(self) -> &'static str {
        if self == Self::SpotGold {
            "现货报价（CFD）"
        } else {
            "CFD"
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FuturesQuote {
    pub instrument: FuturesInstrument,
    #[serde(with = "crate::swift::decimal")]
    pub price: Decimal,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub reference: Option<Decimal>,
    pub time: SwiftDate,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub open: Option<Decimal>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub high: Option<Decimal>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub low: Option<Decimal>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub open_interest: Option<Decimal>,
}

impl FuturesQuote {
    pub fn change(&self) -> Option<Decimal> {
        self.reference.map(|reference| self.price - reference)
    }

    pub fn rate(&self) -> Option<Decimal> {
        let reference = self.reference?;
        (reference != Decimal::ZERO)
            .then(|| (self.price - reference) / reference.abs() * Decimal::ONE_HUNDRED)
    }

    pub fn amplitude(&self) -> Option<Decimal> {
        let (high, low, reference) = (self.high?, self.low?, self.reference?);
        (reference != Decimal::ZERO).then(|| (high - low) / reference.abs() * Decimal::ONE_HUNDRED)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomFuturesQuote {
    pub symbol: String,
    pub name: String,
    #[serde(with = "crate::swift::decimal")]
    pub price: Decimal,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub reference: Option<Decimal>,
    pub time: SwiftDate,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub open: Option<Decimal>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub high: Option<Decimal>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub low: Option<Decimal>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub open_interest: Option<Decimal>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FuturesSuggestion {
    pub symbol: String,
    pub title: String,
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FuturesIntraday {
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub reference: Option<Decimal>,
    pub points: Vec<PlotPoint>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub averages: Option<Vec<PlotPoint>>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FuturesCandle {
    pub day: SwiftDate,
    #[serde(with = "crate::swift::decimal")]
    pub open: Decimal,
    #[serde(with = "crate::swift::decimal")]
    pub high: Decimal,
    #[serde(with = "crate::swift::decimal")]
    pub low: Decimal,
    #[serde(with = "crate::swift::decimal")]
    pub close: Decimal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CandlePeriod {
    Daily,
    Weekly,
    Monthly,
}

impl FuturesCandle {
    pub fn aggregate(daily: &[Self], period: CandlePeriod) -> Vec<Self> {
        if period == CandlePeriod::Daily {
            return daily.to_vec();
        }
        let mut candles: Vec<Self> = Vec::new();
        let mut bucket: Option<(i32, u32)> = None;
        for bar in daily {
            let Some(local) = bar.day.to_utc().map(|date| date.with_timezone(&Shanghai)) else {
                continue;
            };
            let key = match period {
                CandlePeriod::Weekly => (local.iso_week().year(), local.iso_week().week()),
                CandlePeriod::Monthly => (local.year(), local.month()),
                CandlePeriod::Daily => unreachable!(),
            };
            if bucket == Some(key) {
                if let Some(prior) = candles.last_mut() {
                    *prior = Self {
                        day: bar.day,
                        open: prior.open,
                        high: prior.high.max(bar.high),
                        low: prior.low.min(bar.low),
                        close: bar.close,
                    };
                }
            } else {
                candles.push(bar.clone());
                bucket = Some(key);
            }
        }
        candles
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FuturesSessionPrices {
    pub day: SwiftDate,
    pub prices: Vec<Decimal>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FuturesFiveSessions {
    pub sessions: Vec<FuturesSessionPrices>,
    pub is_minute_series: bool,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub reference: Option<Decimal>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketBreadth {
    #[serde(with = "crate::swift::decimal")]
    pub turnover: Decimal,
    pub advancing: Option<i64>,
    pub flat: Option<i64>,
    pub declining: Option<i64>,
    pub as_of: Option<SwiftDate>,
    pub source: String,
    pub cached_counts_as_of: Option<SwiftDate>,
}

impl MarketBreadth {
    pub fn has_counts(&self) -> bool {
        self.advancing.is_some() && self.flat.is_some() && self.declining.is_some()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FlowKind {
    Main,
    Huge,
    Large,
    Medium,
    Small,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketFlow {
    pub time: SwiftDate,
    #[serde(with = "crate::swift::decimal")]
    pub main: Decimal,
    #[serde(with = "crate::swift::decimal")]
    pub small: Decimal,
    #[serde(with = "crate::swift::decimal")]
    pub medium: Decimal,
    #[serde(with = "crate::swift::decimal")]
    pub large: Decimal,
    #[serde(with = "crate::swift::decimal")]
    pub huge: Decimal,
}

impl MarketFlow {
    pub fn amount(&self, kind: FlowKind) -> Decimal {
        match kind {
            FlowKind::Main => self.main,
            FlowKind::Huge => self.huge,
            FlowKind::Large => self.large,
            FlowKind::Medium => self.medium,
            FlowKind::Small => self.small,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MarketFlowSeries {
    pub points: Vec<MarketFlow>,
    pub intraday: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub source: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SectorCategory {
    Industry,
    Style,
    Concept,
    Region,
}

impl SectorCategory {
    pub const ALL: [Self; 4] = [Self::Industry, Self::Style, Self::Concept, Self::Region];

    pub fn provider_code(self) -> &'static str {
        match self {
            Self::Industry => "m:90+s:4",
            Self::Style => "m:90+e:4",
            Self::Concept => "m:90+t:3",
            Self::Region => "m:90+t:1",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SectorPeriod {
    Today,
    FiveDays,
    TenDays,
}

impl SectorPeriod {
    pub fn provider_field(self) -> &'static str {
        match self {
            Self::Today => "f62",
            Self::FiveDays => "f164",
            Self::TenDays => "f174",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SectorFlow {
    pub code: String,
    pub name: String,
    #[serde(with = "crate::swift::decimal")]
    pub amount: Decimal,
}

impl IndexTradingSession {
    pub fn new(
        time_zone: &str,
        time_zone_label: &str,
        windows: &[(i32, i32)],
        marks: &[(i32, &str)],
    ) -> Self {
        Self {
            time_zone: time_zone.to_string(),
            time_zone_label: time_zone_label.to_string(),
            windows: windows
                .iter()
                .map(|(start, end)| IndexTradingWindow {
                    start_minute: *start,
                    end_minute: *end,
                })
                .collect(),
            axis_marks: marks
                .iter()
                .map(|(position, title)| IndexAxisMark {
                    position: *position,
                    title: (*title).to_string(),
                })
                .collect(),
        }
    }
}

pub fn index_session(index: MarketIndex) -> IndexTradingSession {
    if index.is_us() {
        united_states_session()
    } else if index == MarketIndex::HangSeng {
        hong_kong_session()
    } else {
        mainland_session()
    }
}

// ---------------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------------

pub fn decode_catalog(data: &[u8]) -> Result<Vec<Fund>, ProviderError> {
    let text = String::from_utf8_lossy(data);
    let start = text
        .find('[')
        .ok_or_else(|| ProviderError::Parse("目录缺少数组".to_string()))?;
    let end = text
        .rfind(']')
        .ok_or_else(|| ProviderError::Parse("目录缺少数组结尾".to_string()))?;
    let rows: Vec<Vec<String>> = serde_json::from_str(&text[start..=end])
        .map_err(|error| ProviderError::Parse(error.to_string()))?;
    let funds = rows
        .into_iter()
        .filter_map(|row| {
            if row.len() < 5 || !Fund::valid_code(&row[0]) || row[2].is_empty() {
                return None;
            }
            Some(Fund {
                code: row[0].clone(),
                name: row[2].clone(),
                kind: row[3].clone(),
                initials: row[1].clone(),
                pinyin: row[4].clone(),
            })
        })
        .collect::<Vec<_>>();
    if funds.is_empty() {
        return Err(ProviderError::Missing("基金目录"));
    }
    Ok(funds)
}

pub fn decode_search(value: &Value) -> Result<Vec<Fund>, ProviderError> {
    let rows = value
        .get("Datas")
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("Datas"))?;
    let funds = rows
        .iter()
        .filter_map(|row| {
            let code = row.get("CODE")?.as_str()?;
            if !Fund::valid_code(code) {
                return None;
            }
            let name = row.get("NAME").and_then(Value::as_str)?;
            let kind = row
                .get("FundBaseInfo")
                .and_then(|base| base.get("FTYPE"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            Some(Fund {
                code: code.to_string(),
                name: name.to_string(),
                kind: kind.to_string(),
                initials: row
                    .get("JP")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                pinyin: String::new(),
            })
        })
        .collect::<Vec<_>>();
    Ok(funds)
}

pub fn decode_history(value: &Value, money: bool) -> Result<Vec<Nav>, ProviderError> {
    let data = value.get("Data").ok_or(ProviderError::Missing("Data"))?;
    let money = money
        || data
            .get("FundType")
            .and_then(|value| value.as_str())
            .is_some_and(|kind| kind == "005");
    let rows = data
        .get("LSJZList")
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("LSJZList"))?;
    let mut result = Vec::new();
    for row in rows {
        let Some(day_text) = row.get("FSRQ").and_then(Value::as_str) else {
            continue;
        };
        if timestamp(day_text, "00:00").is_none() {
            continue;
        }
        let Some(value) = row.get("DWJZ").and_then(number) else {
            continue;
        };
        if !money && value <= Decimal::ZERO {
            continue;
        }
        result.push(Nav {
            day: day_text.to_string(),
            value,
            rate: if money {
                None
            } else {
                row.get("JZZZL").and_then(number)
            },
            annualized_rate: if money {
                row.get("LJJZ").and_then(number)
            } else {
                None
            },
            cumulative_value: if money {
                None
            } else {
                row.get("LJJZ").and_then(number)
            },
            source: "天天基金".to_string(),
        });
    }
    if result.is_empty() {
        return Err(ProviderError::Missing("历史净值"));
    }
    Ok(result)
}

pub fn decode_index_daily(value: &Value) -> Result<Vec<Nav>, ProviderError> {
    let rows = value
        .get("data")
        .and_then(|data| data.get("klines"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("klines"))?;
    let mut result = Vec::new();
    for row in rows {
        let Some(row) = row.as_str() else {
            continue;
        };
        let cells = row.split(',').collect::<Vec<_>>();
        if cells.len() < 3 || timestamp(cells[0], "00:00").is_none() {
            continue;
        }
        let Some(value) = decimal(cells[2]).filter(|value| *value > Decimal::ZERO) else {
            continue;
        };
        result.push(Nav {
            day: cells[0].to_string(),
            value,
            rate: None,
            annualized_rate: None,
            cumulative_value: None,
            source: "东方财富指数".to_string(),
        });
    }
    result.sort_by(|left, right| left.day.cmp(&right.day));
    if result.is_empty() {
        return Err(ProviderError::Missing("指数日线"));
    }
    Ok(result)
}

pub fn decode_tencent_daily(value: &Value, symbol: &str) -> Result<Vec<Nav>, ProviderError> {
    let node = value
        .get("data")
        .and_then(|data| data.get(symbol))
        .ok_or(ProviderError::Missing("腾讯指数日线"))?;
    let rows = node
        .get("day")
        .or_else(|| node.get("qfqday"))
        .or_else(|| node.get("hfqday"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("腾讯指数日线"))?;
    let mut result = Vec::new();
    for row in rows {
        let Some(cells) = row.as_array() else {
            continue;
        };
        let Some(day) = cells.first().and_then(Value::as_str) else {
            continue;
        };
        if timestamp(day, "00:00").is_none() {
            continue;
        }
        let Some(value) = cells
            .get(2)
            .and_then(number)
            .filter(|value| *value > Decimal::ZERO)
        else {
            continue;
        };
        result.push(Nav {
            day: day.to_string(),
            value,
            rate: None,
            annualized_rate: None,
            cumulative_value: None,
            source: "腾讯指数".to_string(),
        });
    }
    result.sort_by(|left, right| left.day.cmp(&right.day));
    if result.is_empty() {
        return Err(ProviderError::Missing("腾讯指数日线"));
    }
    Ok(result)
}

pub fn decode_history_script(
    script: &str,
    money: bool,
    limit: usize,
) -> Result<Vec<Nav>, ProviderError> {
    if money || script.contains("var Data_millionCopiesIncome") {
        let incomes = currency_series(script, "Data_millionCopiesIncome")?;
        let annualized = currency_series(script, "Data_sevenDaysYearIncome").unwrap_or_default();
        let mut rows = incomes
            .into_iter()
            .map(|(day, value)| Nav {
                annualized_rate: annualized.get(&day).copied(),
                day,
                value,
                rate: None,
                cumulative_value: None,
                source: "天天基金".to_string(),
            })
            .collect::<Vec<_>>();
        rows.sort_by(|left, right| left.day.cmp(&right.day));
        let rows = rows.split_off(rows.len().saturating_sub(limit));
        if rows.is_empty() {
            return Err(ProviderError::Missing("货币基金收益"));
        }
        return Ok(rows);
    }
    let payload = script_json(script, "Data_netWorthTrend")?;
    let rows = payload
        .as_array()
        .ok_or(ProviderError::Missing("Data_netWorthTrend"))?;
    let mut result = Vec::new();
    for row in rows
        .iter()
        .rev()
        .take(limit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        let Some(millis) = row.get("x").and_then(Value::as_f64) else {
            continue;
        };
        let Some(value) = row.get("y").and_then(number) else {
            continue;
        };
        if value <= Decimal::ZERO {
            continue;
        }
        let Some(date) = DateTime::<Utc>::from_timestamp_millis(millis as i64) else {
            continue;
        };
        result.push(Nav {
            day: day(date),
            value,
            rate: row.get("equityReturn").and_then(number),
            annualized_rate: None,
            cumulative_value: None,
            source: "天天基金".to_string(),
        });
    }
    if result.is_empty() {
        return Err(ProviderError::Missing("历史净值序列"));
    }
    Ok(result)
}

pub fn decode_sina(value: &Value, fund: &Fund) -> Result<SinaSnapshot, ProviderError> {
    let status = value
        .get("result")
        .and_then(|result| result.get("status"))
        .and_then(|status| status.get("code"))
        .and_then(Value::as_i64);
    if status != Some(0) {
        return Err(ProviderError::Missing("新浪估值状态"));
    }
    let data = value
        .get("result")
        .and_then(|result| result.get("data"))
        .ok_or(ProviderError::Missing("新浪估值"))?;
    let base_day = data
        .get("worth_date")
        .and_then(Value::as_str)
        .and_then(normalized_day);
    let official = match (
        base_day.as_deref(),
        data.get("worth").and_then(number),
        data.get("worth_rate").and_then(number),
    ) {
        (Some(day_text), Some(worth), rate) if worth > Decimal::ZERO && !fund.is_money() => {
            Some(Nav {
                day: day_text.to_string(),
                value: worth,
                rate: rate.map(|rate| rate * Decimal::ONE_HUNDRED),
                annualized_rate: None,
                cumulative_value: None,
                source: "新浪财经".to_string(),
            })
        }
        _ => None,
    };
    let mut series = Vec::new();
    if let Some(rows) = data.get("networth").and_then(Value::as_array) {
        for row in rows {
            if row.get("symbol").and_then(Value::as_str) != Some(fund.code.as_str()) {
                continue;
            }
            let Some(day_text) = row
                .get("pre_date")
                .and_then(Value::as_str)
                .and_then(normalized_day)
            else {
                continue;
            };
            let Some(time_text) = row.get("min_time").and_then(Value::as_str) else {
                continue;
            };
            let Some(mut instant) = timestamp(&day_text, time_text) else {
                continue;
            };
            let Some(value) = row
                .get("pre_nav2")
                .and_then(number)
                .filter(|value| *value > Decimal::ZERO)
            else {
                continue;
            };
            let Some(rate) = row
                .get("growthrate2")
                .and_then(number)
                .filter(|rate| *rate > -Decimal::ONE)
            else {
                continue;
            };
            let market_day = if fund.is_cross_border() && time_text < "09:00" {
                instant -= chrono::Duration::days(1);
                day(instant)
            } else {
                day_text
            };
            series.push(Estimate {
                timestamp: SwiftDate::from_utc(instant),
                market_day,
                base_day: base_day.clone(),
                value,
                percent: rate * Decimal::ONE_HUNDRED,
            });
        }
    }
    series.sort_by(|left, right| left.timestamp.0.partial_cmp(&right.timestamp.0).unwrap());
    let estimate = series.last().cloned();
    Ok(SinaSnapshot {
        nav: official,
        estimate,
        series,
    })
}

pub fn decode_indices(text: &str) -> Result<Vec<IndexQuote>, ProviderError> {
    let mut by_index = HashMap::new();
    for chunk in text.split(';') {
        let Some((key, payload)) = chunk.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let index = MarketIndex::DISPLAY_ORDER
            .into_iter()
            .find(|index| key == format!("v_{}", index.quote_key()));
        let Some(index) = index else {
            continue;
        };
        let fields = payload
            .trim_matches(|character| character == '"' || character == '\n' || character == '\r')
            .split('~')
            .collect::<Vec<_>>();
        if fields.len() < 34 {
            continue;
        }
        let (Some(value), Some(change), Some(rate)) =
            (decimal(fields[3]), decimal(fields[31]), decimal(fields[32]))
        else {
            continue;
        };
        if value <= Decimal::ZERO {
            continue;
        }
        let timestamp = normalized_timestamp(fields[30]);
        let turnover = if fields.len() > 35
            && matches!(
                index,
                MarketIndex::ShanghaiComposite | MarketIndex::ShenzhenComposite
            ) {
            fields[35].split('/').next_back().and_then(decimal)
        } else {
            None
        };
        by_index.insert(
            index,
            IndexQuote {
                index,
                value,
                change,
                rate,
                timestamp,
                turnover,
            },
        );
    }
    let results = MarketIndex::DISPLAY_ORDER
        .into_iter()
        .filter_map(|index| by_index.remove(&index))
        .collect::<Vec<_>>();
    if results.is_empty() {
        return Err(ProviderError::Missing("指数报价"));
    }
    Ok(results)
}

pub fn decode_stock_quotes(text: &str, symbols: &HashSet<String>) -> HashMap<String, StockQuote> {
    let mut quotes = HashMap::new();
    for row in text.split(';') {
        let Some((key, payload)) = row.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let Some(symbol) = key.strip_prefix("v_") else {
            continue;
        };
        if !symbols.contains(symbol) {
            continue;
        }
        let fields = payload
            .trim_matches(|character| character == '"' || character == '\n' || character == '\r')
            .split('~')
            .collect::<Vec<_>>();
        if fields.len() < 33 {
            continue;
        }
        let (Some(price), Some(rate)) = (decimal(fields[3]), decimal(fields[32])) else {
            continue;
        };
        if price <= Decimal::ZERO {
            continue;
        }
        let Some(instant) = stock_timestamp(fields[30], symbol) else {
            continue;
        };
        quotes.insert(
            symbol.to_string(),
            StockQuote {
                rate,
                time: SwiftDate::from_utc(instant),
            },
        );
    }
    quotes
}

pub fn decode_futures_quotes(text: &str) -> Result<Vec<FuturesQuote>, ProviderError> {
    let mut by_instrument: HashMap<FuturesInstrument, FuturesQuote> = HashMap::new();
    for assignment in text.split(';') {
        let Some((key, payload)) = assignment.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let Some(raw) = key.strip_prefix("var hq_str_hf_") else {
            continue;
        };
        let Some(instrument) = FuturesInstrument::ALL
            .into_iter()
            .find(|instrument| instrument.raw() == raw)
        else {
            continue;
        };
        let Some(start) = payload.find('"') else {
            continue;
        };
        let Some(end) = payload.rfind('"') else {
            continue;
        };
        if start >= end {
            continue;
        }
        let fields = payload[start + 1..end].split(',').collect::<Vec<_>>();
        if fields.len() <= 12 {
            continue;
        }
        let Some(price) = decimal(fields[0]) else {
            continue;
        };
        let Some(instant) = timestamp(fields[12].trim(), fields[6].trim()) else {
            continue;
        };
        let quote = FuturesQuote {
            instrument,
            price,
            reference: decimal(fields[7]),
            time: SwiftDate::from_utc(instant),
            open: decimal(fields[8]),
            high: decimal(fields[4]),
            low: decimal(fields[5]),
            open_interest: decimal(fields[9]).filter(|value| *value > Decimal::ZERO),
        };
        match by_instrument.get(&instrument) {
            Some(existing) if existing.time.0 > quote.time.0 => {}
            _ => {
                by_instrument.insert(instrument, quote);
            }
        }
    }
    let results = FuturesInstrument::ALL
        .into_iter()
        .filter_map(|instrument| by_instrument.remove(&instrument))
        .collect::<Vec<_>>();
    if results.is_empty() {
        return Err(ProviderError::Missing("期货报价"));
    }
    Ok(results)
}

pub fn decode_custom_futures_quotes(text: &str, wanted: &[String]) -> Vec<CustomFuturesQuote> {
    let wanted = wanted.iter().cloned().collect::<HashSet<_>>();
    let mut quotes = Vec::new();
    for assignment in text.split(';') {
        let Some((key, payload)) = assignment.split_once('=') else {
            continue;
        };
        let Some(symbol) = key.trim().strip_prefix("var hq_str_hf_") else {
            continue;
        };
        if !wanted.contains(symbol) {
            continue;
        }
        let Some(start) = payload.find('"') else {
            continue;
        };
        let Some(end) = payload.rfind('"') else {
            continue;
        };
        if start >= end {
            continue;
        }
        let fields = payload[start + 1..end].split(',').collect::<Vec<_>>();
        if fields.len() <= 13 {
            continue;
        }
        let Some(price) = decimal(fields[0]) else {
            continue;
        };
        let Some(instant) = timestamp(fields[12].trim(), fields[6].trim()) else {
            continue;
        };
        quotes.push(CustomFuturesQuote {
            symbol: symbol.to_string(),
            name: fields[13].trim().to_string(),
            price,
            reference: decimal(fields[7]),
            time: SwiftDate::from_utc(instant),
            open: decimal(fields[8]),
            high: decimal(fields[4]),
            low: decimal(fields[5]),
            open_interest: decimal(fields[9]).filter(|value| *value > Decimal::ZERO),
        });
    }
    quotes.sort_by(|left, right| left.symbol.cmp(&right.symbol));
    quotes
}

pub fn decode_futures_suggest(text: &str) -> Vec<FuturesSuggestion> {
    let Some(start) = text.find('"') else {
        return Vec::new();
    };
    let Some(end) = text.rfind('"') else {
        return Vec::new();
    };
    if start >= end {
        return Vec::new();
    }
    let mut suggestions: Vec<FuturesSuggestion> = Vec::new();
    for entry in text[start + 1..end].split(';') {
        let fields = entry.split(',').collect::<Vec<_>>();
        if fields.len() < 7 || fields[1].trim() != "86" {
            continue;
        }
        let symbol = fields[3].trim().to_ascii_uppercase();
        if symbol.is_empty()
            || symbol.len() > 12
            || !symbol.bytes().all(|byte| byte.is_ascii_alphanumeric())
        {
            continue;
        }
        let title = if fields[6].trim().is_empty() {
            fields[4].trim()
        } else {
            fields[6].trim()
        };
        if title.is_empty() || suggestions.iter().any(|item| item.symbol == symbol) {
            continue;
        }
        suggestions.push(FuturesSuggestion {
            symbol,
            title: title.to_string(),
            kind: "外盘期货".to_string(),
        });
    }
    suggestions
}

pub fn decode_futures_intraday(value: &Value) -> Result<FuturesIntraday, ProviderError> {
    let rows = value
        .get("result")
        .and_then(|result| result.get("data"))
        .and_then(|data| data.get("minLine_1d"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("minLine_1d"))?;
    let first = rows
        .first()
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("首行"))?;
    if first.len() < 10 {
        return Err(ProviderError::Missing("首行字段"));
    }
    let reference = first.get(1).and_then(number);
    let mut points = BTreeMap::new();
    let mut averages = BTreeMap::new();
    for (index, row) in rows.iter().enumerate() {
        let Some(cells) = row.as_array() else {
            continue;
        };
        let offset = if index == 0 { 4 } else { 0 };
        if cells.len() < offset + 6 {
            continue;
        }
        let Some(price) = cells.get(offset + 1).and_then(number) else {
            continue;
        };
        let Some(stamp) = cells.get(offset + 5).and_then(Value::as_str) else {
            continue;
        };
        let parts = stamp.split(' ').collect::<Vec<_>>();
        if parts.len() != 2 {
            continue;
        }
        let Some(instant) = timestamp(parts[0], parts[1]) else {
            continue;
        };
        let key = instant.timestamp_millis();
        points.insert(
            key,
            PlotPoint {
                time: SwiftDate::from_utc(instant),
                value: price,
            },
        );
        if let Some(avg) = cells
            .get(offset + 4)
            .and_then(number)
            .filter(|value| *value != Decimal::ZERO)
        {
            averages.insert(
                key,
                PlotPoint {
                    time: SwiftDate::from_utc(instant),
                    value: avg,
                },
            );
        }
    }
    if points.is_empty() {
        return Err(ProviderError::Missing("期货分时"));
    }
    Ok(FuturesIntraday {
        reference,
        points: points.into_values().collect(),
        averages: Some(averages.into_values().collect()),
    })
}

pub fn decode_futures_daily(value: &Value) -> Result<Vec<FuturesCandle>, ProviderError> {
    let rows = value
        .get("result")
        .and_then(|result| result.get("data"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("日 K"))?;
    let mut by_day: BTreeMap<i64, FuturesCandle> = BTreeMap::new();
    for row in rows {
        let Some(day_text) = row.get("date").and_then(Value::as_str) else {
            continue;
        };
        let Some(instant) = timestamp(day_text, "00:00") else {
            continue;
        };
        let (Some(open), Some(high), Some(low), Some(close)) = (
            row.get("open").and_then(number),
            row.get("high").and_then(number),
            row.get("low").and_then(number),
            row.get("close").and_then(number),
        ) else {
            continue;
        };
        if high < low {
            continue;
        }
        by_day.insert(
            instant.timestamp_millis(),
            FuturesCandle {
                day: SwiftDate::from_utc(instant),
                open,
                high,
                low,
                close,
            },
        );
    }
    if by_day.is_empty() {
        return Err(ProviderError::Missing("期货日 K"));
    }
    let values = by_day.into_values().collect::<Vec<_>>();
    Ok(values[values.len().saturating_sub(1500)..].to_vec())
}

pub fn decode_futures_five_minutes(
    value: &Value,
    instrument: FuturesInstrument,
    quote_day: Option<DateTime<Utc>>,
) -> Result<FuturesFiveSessions, ProviderError> {
    let days = value
        .get("result")
        .and_then(|result| result.get("data"))
        .and_then(|data| data.get(instrument.raw()))
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("五日分时"))?;
    let mut sessions: Vec<FuturesSessionPrices> = Vec::new();
    let mut reference = None;
    for rows in days {
        let Some(rows) = rows.as_array() else {
            continue;
        };
        let Some(first) = rows.first().and_then(Value::as_array) else {
            continue;
        };
        if first.len() < 4 {
            continue;
        }
        let Some(day_text) = first[0].as_str() else {
            continue;
        };
        let Some(instant) = timestamp(day_text, "00:00") else {
            continue;
        };
        if sessions
            .last()
            .is_some_and(|session| session.day.0 >= SwiftDate::from_utc(instant).0)
        {
            continue;
        }
        let mut prices = Vec::new();
        if let Some(value) = first.get(first.len().saturating_sub(2)).and_then(number) {
            prices.push(value);
        }
        for row in rows.iter().skip(1) {
            let Some(cells) = row.as_array() else {
                continue;
            };
            if cells.len() < 3 {
                continue;
            }
            if let Some(value) = cells.get(1).and_then(number) {
                prices.push(value);
            }
        }
        if prices.len() < 2 {
            continue;
        }
        if sessions.is_empty() && first.len() >= 5 {
            reference = first.get(1).and_then(number);
        }
        sessions.push(FuturesSessionPrices {
            day: SwiftDate::from_utc(instant),
            prices,
        });
    }
    let cutoff_day = quote_day.unwrap_or_else(|| Utc::now() - chrono::Duration::days(3));
    let cutoff = day(cutoff_day);
    if sessions.len() < 5
        || sessions
            .last()
            .is_none_or(|session| day(session.day.to_utc().unwrap_or(cutoff_day)) < cutoff)
    {
        return Err(ProviderError::Missing("五日分时不足"));
    }
    let start = sessions.len() - 5;
    Ok(FuturesFiveSessions {
        sessions: sessions[start..].to_vec(),
        is_minute_series: true,
        reference,
    })
}

pub fn decode_breadth(value: &Value, source: &str) -> Result<MarketBreadth, ProviderError> {
    let rows = value
        .get("data")
        .and_then(|data| data.get("diff"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("breadth.diff"))?;
    let sh = rows
        .iter()
        .find(|row| row.get("f12").and_then(Value::as_str) == Some("000001"))
        .ok_or(ProviderError::Missing("上证统计"))?;
    let sz = rows
        .iter()
        .find(|row| row.get("f12").and_then(Value::as_str) == Some("399001"))
        .ok_or(ProviderError::Missing("深证统计"))?;
    let sum = |field: &str| -> Option<Decimal> {
        let left = sh.get(field).and_then(number)?;
        let right = sz.get(field).and_then(number)?;
        if left < Decimal::ZERO || right < Decimal::ZERO {
            return None;
        }
        Some(left + right)
    };
    let turnover = sum("f6").ok_or(ProviderError::Missing("成交额"))?;
    if turnover <= Decimal::ZERO {
        return Err(ProviderError::Missing("成交额"));
    }
    let stamps = ["f124"]
        .into_iter()
        .flat_map(|field| {
            [sh, sz]
                .into_iter()
                .filter_map(move |row| row.get(field).and_then(number))
        })
        .filter_map(|value| DateTime::<Utc>::from_timestamp(value.to_i64()?, 0))
        .collect::<Vec<_>>();
    let as_of = shared_market_time(&stamps);
    if stamps.len() == 2 && as_of.is_none() {
        return Err(ProviderError::Missing("行情时间不一致"));
    }
    Ok(MarketBreadth {
        turnover,
        advancing: sum("f104").and_then(|value| value.to_i64()),
        flat: sum("f106").and_then(|value| value.to_i64()),
        declining: sum("f105").and_then(|value| value.to_i64()),
        as_of: as_of.map(SwiftDate::from_utc),
        source: source.to_string(),
        cached_counts_as_of: None,
    })
}

pub fn decode_sina_breadth(value: &Value) -> Result<MarketBreadth, ProviderError> {
    let rows = value
        .as_array()
        .ok_or(ProviderError::Missing("新浪全市场快照"))?;
    let mut advancing = 0_i64;
    let mut flat = 0_i64;
    let mut declining = 0_i64;
    let mut turnover = Decimal::ZERO;
    let mut latest_time = String::new();
    for row in rows {
        let Some(symbol) = row.get("symbol").and_then(Value::as_str) else {
            continue;
        };
        if !(symbol.starts_with("sh") || symbol.starts_with("sz")) {
            continue;
        }
        let Some(trade) = row.get("trade").and_then(number) else {
            continue;
        };
        if let Some(amount) = row.get("amount").and_then(number) {
            turnover += amount;
        }
        if trade <= Decimal::ZERO {
            continue;
        }
        let Some(change) = row.get("changepercent").and_then(number) else {
            continue;
        };
        if change > Decimal::ZERO {
            advancing += 1;
        } else if change < Decimal::ZERO {
            declining += 1;
        } else {
            flat += 1;
        }
        if let Some(ticktime) = row.get("ticktime").and_then(Value::as_str) {
            if ticktime > latest_time.as_str() {
                latest_time = ticktime.to_string();
            }
        }
    }
    if advancing + flat + declining == 0 {
        return Err(ProviderError::Missing("新浪涨跌家数"));
    }
    let as_of = timestamp(&day(Utc::now()), &latest_time).map(SwiftDate::from_utc);
    Ok(MarketBreadth {
        turnover,
        advancing: Some(advancing),
        flat: Some(flat),
        declining: Some(declining),
        as_of,
        source: "新浪财经 · 全市场".to_string(),
        cached_counts_as_of: None,
    })
}

pub fn decode_flows(value: &Value, intraday: bool) -> Result<Vec<MarketFlow>, ProviderError> {
    let lines = value
        .get("data")
        .and_then(|data| data.get("klines"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("klines"))?;
    let limit = Utc::now() + chrono::Duration::seconds(180);
    let mut flows = Vec::new();
    for line in lines {
        let Some(line) = line.as_str() else {
            continue;
        };
        let cells = line.split(',').collect::<Vec<_>>();
        if cells.len() < 6 {
            continue;
        }
        let stamp = cells[0].split(' ').collect::<Vec<_>>();
        let expected = if intraday { 2 } else { 1 };
        if stamp.len() != expected {
            continue;
        }
        let Some(instant) = timestamp(stamp[0], stamp.get(1).copied().unwrap_or("00:00")) else {
            continue;
        };
        if instant > limit {
            continue;
        }
        let amounts = cells[1..6]
            .iter()
            .map(|value| decimal(value))
            .collect::<Option<Vec<_>>>();
        let Some(amounts) = amounts.filter(|values| values.len() == 5) else {
            continue;
        };
        flows.push(MarketFlow {
            time: SwiftDate::from_utc(instant),
            main: amounts[0],
            small: amounts[1],
            medium: amounts[2],
            large: amounts[3],
            huge: amounts[4],
        });
    }
    if flows.is_empty() {
        return Err(ProviderError::Missing("资金流"));
    }
    flows.sort_by(|left, right| left.time.0.partial_cmp(&right.time.0).unwrap());
    Ok(flows)
}

pub fn decode_sectors(
    value: &Value,
    period: SectorPeriod,
) -> Result<Vec<SectorFlow>, ProviderError> {
    let rows = value
        .get("data")
        .and_then(|data| data.get("diff"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("sectors.diff"))?;
    let field = period.provider_field();
    let mut entries = rows
        .iter()
        .filter_map(|row| {
            Some(SectorFlow {
                code: row.get("f12")?.as_str()?.to_string(),
                name: row.get("f14")?.as_str()?.to_string(),
                amount: row.get(field).and_then(number)?,
            })
        })
        .collect::<Vec<_>>();
    if entries.is_empty() {
        return Err(ProviderError::Missing("板块资金"));
    }
    entries.sort_by(|left, right| {
        right
            .amount
            .cmp(&left.amount)
            .then_with(|| left.code.cmp(&right.code))
    });
    Ok(entries)
}

#[derive(Clone, Debug)]
pub struct SinaSnapshot {
    pub nav: Option<Nav>,
    pub estimate: Option<Estimate>,
    pub series: Vec<Estimate>,
}

fn number(value: &Value) -> Option<Decimal> {
    match value {
        Value::String(text) => decimal(text),
        Value::Number(number) => Decimal::from_str(&number.to_string()).ok(),
        _ => None,
    }
}

fn normalized_day(input: &str) -> Option<String> {
    let cleaned = input.replace('-', "");
    if cleaned.len() != 8 || !cleaned.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let day_text = format!("{}-{}-{}", &cleaned[0..4], &cleaned[4..6], &cleaned[6..8]);
    timestamp(&day_text, "00:00").map(|_| day_text)
}

fn normalized_timestamp(raw: &str) -> String {
    let raw = raw.trim();
    if raw.len() == 14 && raw.bytes().all(|byte| byte.is_ascii_digit()) {
        return format!(
            "{}-{}-{} {}:{}:{}",
            &raw[0..4],
            &raw[4..6],
            &raw[6..8],
            &raw[8..10],
            &raw[10..12],
            &raw[12..14]
        );
    }
    raw.replace('/', "-")
}

fn stock_timestamp(raw: &str, symbol: &str) -> Option<DateTime<Utc>> {
    let raw = raw.trim();
    if raw.len() == 14 && raw.bytes().all(|byte| byte.is_ascii_digit()) {
        let day_text = format!("{}-{}-{}", &raw[0..4], &raw[4..6], &raw[6..8]);
        let time = format!("{}:{}:{}", &raw[8..10], &raw[10..12], &raw[12..14]);
        return timestamp(&day_text, &time);
    }
    let parts = raw.split(' ').collect::<Vec<_>>();
    if parts.len() != 2 {
        return None;
    }
    let session = if symbol.starts_with("us") {
        united_states_session()
    } else if symbol.starts_with("hk") {
        hong_kong_session()
    } else {
        mainland_session()
    };
    session.timestamp(&parts[0].replace('/', "-"), parts[1])
}

fn shared_market_time(stamps: &[DateTime<Utc>]) -> Option<DateTime<Utc>> {
    if stamps.len() != 2 || day(stamps[0]) != day(stamps[1]) {
        return None;
    }
    stamps.iter().min().copied()
}

fn currency_series(
    script: &str,
    variable: &str,
) -> Result<BTreeMap<String, Decimal>, ProviderError> {
    let value = script_json(script, variable)?;
    let rows = value.as_array().ok_or(ProviderError::Missing("货币序列"))?;
    let mut result = BTreeMap::new();
    for row in rows {
        let Some(cells) = row.as_array() else {
            continue;
        };
        if cells.len() != 2 {
            continue;
        }
        let Some(millis) = cells[0].as_f64() else {
            continue;
        };
        let Some(value) = number(&cells[1]) else {
            continue;
        };
        let Some(date) = DateTime::<Utc>::from_timestamp_millis(millis as i64) else {
            continue;
        };
        result.insert(day(date), value);
    }
    Ok(result)
}

pub(crate) fn script_json(script: &str, variable: &str) -> Result<Value, ProviderError> {
    let marker = format!("var {variable}");
    let start = script
        .find(&marker)
        .ok_or_else(|| ProviderError::Missing("脚本变量"))?;
    let rest = &script[start + marker.len()..];
    let open = rest
        .find('[')
        .ok_or_else(|| ProviderError::Missing("脚本数组"))?;
    let mut depth = 0_i32;
    let mut quoted = false;
    let mut escaped = false;
    let mut end = None;
    for (offset, character) in rest[open..].char_indices() {
        if quoted {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                quoted = false;
            }
            continue;
        }
        match character {
            '"' => quoted = true,
            '[' | '{' => depth += 1,
            ']' | '}' => {
                depth -= 1;
                if depth == 0 {
                    end = Some(open + offset + 1);
                    break;
                }
            }
            _ => {}
        }
    }
    let end = end.ok_or_else(|| ProviderError::Missing("脚本数组结尾"))?;
    serde_json::from_str(&rest[open..end]).map_err(|error| ProviderError::Parse(error.to_string()))
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

impl MarketClient {
    async fn fetch(
        &self,
        url: &str,
        query: &[(&str, &str)],
        referer: Option<&str>,
    ) -> Result<Vec<u8>, ProviderError> {
        let mut request = self
            .http()
            .get(url)
            .header(reqwest::header::USER_AGENT, self.user_agent());
        if !query.is_empty() {
            request = request.query(query);
        }
        if let Some(referer) = referer {
            request = request.header(reqwest::header::REFERER, referer);
        }
        let response = request.send().await?.error_for_status()?;
        let bytes = response.bytes().await?;
        if bytes.is_empty() || bytes.len() > 10_000_000 {
            return Err(ProviderError::Missing("响应体"));
        }
        Ok(bytes.to_vec())
    }

    pub async fn catalog(&self) -> Result<Vec<Fund>, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.eastmoney.fund,
            "eastmoney.fund",
            "/js/fundcode_search.js",
        )?;
        let data = self.fetch(&url, &[], None).await?;
        decode_catalog(&data)
    }

    pub async fn search(&self, keyword: &str) -> Result<Vec<Fund>, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.eastmoney.fund_suggest,
            "eastmoney.fundSuggest",
            "/FundSearch/api/FundSearchAPI.ashx",
        )?;
        let data = self
            .fetch(&url, &[("key", keyword), ("m", "9")], None)
            .await?;
        let value: Value = serde_json::from_slice(&data)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        decode_search(&value)
    }

    pub async fn nav_history(&self, fund: &Fund, limit: usize) -> Result<Vec<Nav>, ProviderError> {
        let sources = self.sources();
        let api = self.endpoint(
            &sources.eastmoney.fund_api,
            "eastmoney.fundApi",
            "/f10/lsjz",
        )?;
        let referer = if sources.eastmoney.fund_f10.trim().is_empty() {
            None
        } else {
            Some(format!(
                "{}/jjjz_{}.html",
                sources.eastmoney.fund_f10.trim_end_matches('/'),
                fund.code
            ))
        };
        let primary = self
            .fetch(
                &api,
                &[
                    ("fundCode", &fund.code),
                    ("pageIndex", "1"),
                    ("pageSize", &limit.max(1).to_string()),
                ],
                referer.as_deref(),
            )
            .await
            .and_then(|data| {
                let value: Value = serde_json::from_slice(&data)
                    .map_err(|error| ProviderError::Parse(error.to_string()))?;
                decode_history(&value, fund.is_money())
            });
        if let Ok(navs) = primary {
            return Ok(navs);
        }
        let script_url = self.endpoint(
            &sources.eastmoney.fund,
            "eastmoney.fund",
            &format!("/pingzhongdata/{}.js", fund.code),
        )?;
        let script = self.fetch(&script_url, &[], None).await?;
        decode_history_script(&String::from_utf8_lossy(&script), fund.is_money(), limit)
    }

    pub async fn sina_snapshot(&self, fund: &Fund) -> Result<SinaSnapshot, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.sina.stock,
            "sina.stock",
            "/fundInfo/api/openapi.php/FdFundService.getEstimateNetworthPic",
        )?;
        let data = self.fetch(&url, &[("symbol", &fund.code)], None).await?;
        let value: Value = serde_json::from_slice(&data)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        decode_sina(&value, fund)
    }

    pub async fn indices(&self) -> Result<Vec<IndexQuote>, ProviderError> {
        let sources = self.sources();
        let codes = MarketIndex::DISPLAY_ORDER
            .iter()
            .map(|index| index.quote_key())
            .collect::<Vec<_>>()
            .join(",");
        let url = self.endpoint(&sources.tencent.qt, "tencent.qt", &format!("/q={codes}"))?;
        let data = self.fetch(&url, &[], None).await?;
        decode_indices(&String::from_utf8_lossy(&data))
    }

    pub async fn index_daily_history(
        &self,
        index: MarketIndex,
        limit: usize,
    ) -> Result<Vec<Nav>, ProviderError> {
        let (secid, symbol) = match index {
            MarketIndex::ShanghaiComposite => ("1.000001", "sh000001"),
            MarketIndex::Csi300 => ("1.000300", "sh000300"),
            MarketIndex::ShenzhenComposite => ("0.399001", "sz399001"),
            MarketIndex::Chinext => ("0.399006", "sz399006"),
            _ => return Err(ProviderError::Missing("指数日线")),
        };
        let sources = self.sources();
        let url = self.endpoint(
            &sources.tencent.ifzq,
            "tencent.ifzq",
            "/appstock/app/fqkline/get",
        )?;
        let referer = if sources.tencent.portal.trim().is_empty() {
            None
        } else {
            Some(sources.tencent.portal.as_str())
        };
        let primary = self
            .fetch(
                &url,
                &[("param", &format!("{symbol},day,,,{limit},qfq"))],
                referer,
            )
            .await
            .and_then(|data| {
                let value: Value = serde_json::from_slice(&data)
                    .map_err(|error| ProviderError::Parse(error.to_string()))?;
                decode_tencent_daily(&value, symbol)
            });
        let mut rows = match primary {
            Ok(rows) => rows,
            Err(_) => {
                let data = self
                    .east_quote(
                        "/api/qt/stock/kline/get",
                        &[
                            ("secid", secid),
                            ("klt", "101"),
                            ("fqt", "1"),
                            ("lmt", &limit.max(1).to_string()),
                            ("end", "20500101"),
                            ("fields1", "f1,f2,f3,f4,f5,f6"),
                            ("fields2", "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"),
                        ],
                        &["push2his", "push2", "push2delay"],
                    )
                    .await?;
                let value: Value = serde_json::from_slice(&data)
                    .map_err(|error| ProviderError::Parse(error.to_string()))?;
                decode_index_daily(&value)?
            }
        };
        if rows.len() > limit {
            rows = rows.split_off(rows.len() - limit);
        }
        Ok(rows)
    }

    pub async fn index_trend(&self, index: MarketIndex) -> Result<IndexTrendData, ProviderError> {
        let sources = self.sources();
        if index.is_us() {
            let symbol = if index == MarketIndex::Sp500 {
                "^GSPC"
            } else {
                "^IXIC"
            };
            if !sources.yahoo.query1.trim().is_empty() {
                let yahoo_url = self.endpoint(
                    &sources.yahoo.query1,
                    "yahoo.query1",
                    &format!("/v8/finance/chart/{symbol}"),
                )?;
                let yahoo = self
                    .fetch(&yahoo_url, &[("range", "1d"), ("interval", "5m")], None)
                    .await
                    .and_then(|data| {
                        let value: Value = serde_json::from_slice(&data)
                            .map_err(|error| ProviderError::Parse(error.to_string()))?;
                        decode_yahoo_index_trend(&value, symbol)
                    });
                if let Ok(trend) = yahoo {
                    return Ok(trend);
                }
            }
            let secid = if index == MarketIndex::Sp500 {
                "100.SPX"
            } else {
                "100.NDX"
            };
            let data = self
                .east_quote(
                    "/api/qt/stock/trends2/get",
                    &[
                        ("secid", secid),
                        ("ndays", "1"),
                        ("fields1", "f1,f2,f3,f6,f7,f8"),
                        ("fields2", "f51,f53,f56"),
                    ],
                    &["push2his", "push2", "push2delay"],
                )
                .await?;
            let value: Value = serde_json::from_slice(&data)
                .map_err(|error| ProviderError::Parse(error.to_string()))?;
            return decode_eastmoney_index_trend(&value);
        }
        let url = self.endpoint(
            &sources.tencent.ifzq,
            "tencent.ifzq",
            "/appstock/app/minute/query",
        )?;
        let data = self.fetch(&url, &[("code", index.raw())], None).await?;
        let value: Value = serde_json::from_slice(&data)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        decode_tencent_index_trend(&value, index)
    }

    pub async fn stock_quotes(
        &self,
        symbols: &HashSet<String>,
    ) -> Result<HashMap<String, StockQuote>, ProviderError> {
        let sources = self.sources();
        let mut symbols = symbols
            .iter()
            .filter(|symbol| valid_quote_symbol(symbol))
            .cloned()
            .collect::<Vec<_>>();
        symbols.sort();
        if symbols.is_empty() {
            return Ok(HashMap::new());
        }
        let mut quotes = HashMap::new();
        for batch in symbols.chunks(60) {
            let url = self.endpoint(
                &sources.tencent.qt,
                "tencent.qt",
                &format!("/q={}", batch.join(",")),
            )?;
            let data = self.fetch(&url, &[], None).await?;
            let text = String::from_utf8_lossy(&data);
            let wanted = batch.iter().cloned().collect::<HashSet<_>>();
            quotes.extend(decode_stock_quotes(&text, &wanted));
        }
        if quotes.is_empty() {
            return Err(ProviderError::Missing("个股报价"));
        }
        Ok(quotes)
    }

    pub async fn futures_quotes(&self) -> Result<Vec<FuturesQuote>, ProviderError> {
        let sources = self.sources();
        let symbols = FuturesInstrument::ALL
            .iter()
            .map(|instrument| format!("hf_{}", instrument.raw()))
            .collect::<Vec<_>>()
            .join(",");
        let url = self.endpoint(&sources.sina.hq, "sina.hq", &format!("/list={symbols}"))?;
        let data = self.fetch(&url, &[], sina_referer(&sources)).await?;
        let (text, _, _) = GBK.decode(&data);
        decode_futures_quotes(&text)
    }

    pub async fn custom_futures_quotes(
        &self,
        symbols: &[String],
    ) -> Result<Vec<CustomFuturesQuote>, ProviderError> {
        if symbols.is_empty() {
            return Ok(Vec::new());
        }
        let sources = self.sources();
        let list = symbols
            .iter()
            .map(|symbol| format!("hf_{symbol}"))
            .collect::<Vec<_>>()
            .join(",");
        let url = self.endpoint(&sources.sina.hq, "sina.hq", &format!("/list={list}"))?;
        let data = self.fetch(&url, &[], sina_referer(&sources)).await?;
        let (text, _, _) = GBK.decode(&data);
        let quotes = decode_custom_futures_quotes(&text, symbols);
        if quotes.is_empty() {
            return Err(ProviderError::Missing("期货报价"));
        }
        Ok(quotes)
    }

    pub async fn search_futures(
        &self,
        keyword: &str,
    ) -> Result<Vec<FuturesSuggestion>, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(&sources.sina.suggest, "sina.suggest", "/suggest/type=86")?;
        let data = self
            .fetch(&url, &[("key", keyword)], sina_referer(&sources))
            .await?;
        let (text, _, _) = GBK.decode(&data);
        Ok(decode_futures_suggest(&text))
    }

    pub async fn futures_intraday(
        &self,
        instrument: FuturesInstrument,
    ) -> Result<FuturesIntraday, ProviderError> {
        self.futures_intraday_raw(instrument.raw()).await
    }

    pub async fn futures_intraday_raw(
        &self,
        symbol: &str,
    ) -> Result<FuturesIntraday, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.sina.stock2,
            "sina.stock2",
            "/futures/api/openapi.php/GlobalFuturesService.getGlobalFuturesMinLine",
        )?;
        let data = self
            .fetch(&url, &[("symbol", symbol)], sina_referer(&sources))
            .await?;
        let value: Value = serde_json::from_slice(&data)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        decode_futures_intraday(&value)
    }

    pub async fn futures_daily(
        &self,
        instrument: FuturesInstrument,
    ) -> Result<Vec<FuturesCandle>, ProviderError> {
        self.futures_daily_raw(instrument.raw()).await
    }

    pub async fn futures_daily_raw(
        &self,
        symbol: &str,
    ) -> Result<Vec<FuturesCandle>, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.sina.stock2,
            "sina.stock2",
            "/futures/api/openapi.php/GlobalFuturesService.getGlobalFuturesDailyKLine",
        )?;
        let data = self
            .fetch(&url, &[("symbol", symbol)], sina_referer(&sources))
            .await?;
        let value: Value = serde_json::from_slice(&data)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        decode_futures_daily(&value)
    }

    pub async fn futures_five_sessions(
        &self,
        instrument: FuturesInstrument,
        quote_day: Option<DateTime<Utc>>,
    ) -> Result<FuturesFiveSessions, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.sina.stock2,
            "sina.stock2",
            "/futures/api/openapi.php/GlobalFuturesService.getGlobalFutures5MLine",
        )?;
        let data = self
            .fetch(
                &url,
                &[("symbol", instrument.raw())],
                sina_referer(&sources),
            )
            .await
            .and_then(|data| {
                let value: Value = serde_json::from_slice(&data)
                    .map_err(|error| ProviderError::Parse(error.to_string()))?;
                decode_futures_five_minutes(&value, instrument, quote_day)
            });
        if let Ok(sessions) = data {
            return Ok(sessions);
        }
        let candles = self.futures_daily(instrument).await?;
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
        if sessions.len() < 5 {
            return Err(ProviderError::Missing("五日行情"));
        }
        Ok(FuturesFiveSessions {
            reference: candles.iter().rev().nth(5).map(|candle| candle.close),
            sessions,
            is_minute_series: false,
        })
    }

    pub async fn market_breadth(&self) -> Result<MarketBreadth, ProviderError> {
        for host in ["push2", "push2delay"] {
            if let Ok(data) = self
                .east_quote(
                    "/api/qt/ulist.np/get",
                    &[
                        ("fltt", "2"),
                        ("fields", "f6,f12,f13,f104,f105,f106,f124"),
                        ("secids", "1.000001,0.399001"),
                    ],
                    &[host],
                )
                .await
            {
                let value: Value = serde_json::from_slice(&data)
                    .map_err(|error| ProviderError::Parse(error.to_string()))?;
                let label = if host == "push2" {
                    "东方财富"
                } else {
                    "东方财富 · 延时来源"
                };
                return decode_breadth(&value, label);
            }
        }
        if let Ok(breadth) = self.sina_market_breadth().await {
            return Ok(breadth);
        }
        let quotes = self.indices().await?;
        let sh = quotes
            .iter()
            .find(|quote| quote.index == MarketIndex::ShanghaiComposite)
            .and_then(|quote| quote.turnover)
            .ok_or(ProviderError::Missing("上证成交额"))?;
        let sz = quotes
            .iter()
            .find(|quote| quote.index == MarketIndex::ShenzhenComposite)
            .and_then(|quote| quote.turnover)
            .ok_or(ProviderError::Missing("深证成交额"))?;
        let mut stamps = Vec::new();
        for quote in quotes.iter().filter(|quote| {
            matches!(
                quote.index,
                MarketIndex::ShanghaiComposite | MarketIndex::ShenzhenComposite
            )
        }) {
            let parts = quote.timestamp.split(' ').collect::<Vec<_>>();
            if parts.len() == 2 {
                if let Some(instant) = timestamp(parts[0], parts[1]) {
                    stamps.push(instant);
                }
            }
        }
        Ok(MarketBreadth {
            turnover: sh + sz,
            advancing: None,
            flat: None,
            declining: None,
            as_of: shared_market_time(&stamps).map(SwiftDate::from_utc),
            source: "腾讯行情".to_string(),
            cached_counts_as_of: None,
        })
    }

    pub async fn sina_market_breadth(&self) -> Result<MarketBreadth, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.sina.vip,
            "sina.vip",
            "/quotes_service/api/json_v2.php/Market_Center.getHQNodeDataSimple",
        )?;
        let data = self
            .fetch(
                &url,
                &[
                    ("page", "1"),
                    ("num", "6000"),
                    ("sort", "symbol"),
                    ("asc", "1"),
                    ("node", "hs_a"),
                    ("symbol", ""),
                    ("_s_r_a", "page"),
                ],
                sina_referer(&sources),
            )
            .await?;
        let value: Value = serde_json::from_slice(&data)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        decode_sina_breadth(&value)
    }

    pub async fn market_flows(&self) -> Result<MarketFlowSeries, ProviderError> {
        let intraday = self
            .east_quote(
                "/api/qt/stock/fflow/kline/get",
                &[
                    ("lmt", "0"),
                    ("klt", "1"),
                    ("secid", "1.000001"),
                    ("secid2", "0.399001"),
                    ("fields1", "f1,f2,f3,f7"),
                    (
                        "fields2",
                        "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63",
                    ),
                ],
                &["push2", "push2delay", "push2his"],
            )
            .await
            .and_then(|data| {
                let value: Value = serde_json::from_slice(&data)
                    .map_err(|error| ProviderError::Parse(error.to_string()))?;
                decode_flows(&value, true)
            });
        if let Ok(points) = intraday {
            return Ok(MarketFlowSeries {
                points,
                intraday: true,
                source: "东方财富".to_string(),
            });
        }
        let daily = self
            .east_quote(
                "/api/qt/stock/fflow/daykline/get",
                &[
                    ("lmt", "20"),
                    ("klt", "101"),
                    ("secid", "1.000001"),
                    ("secid2", "0.399001"),
                    ("fields1", "f1,f2,f3,f7"),
                    ("fields2", "f51,f52,f53,f54,f55,f56"),
                ],
                &["push2his", "push2", "push2delay"],
            )
            .await
            .and_then(|data| {
                let value: Value = serde_json::from_slice(&data)
                    .map_err(|error| ProviderError::Parse(error.to_string()))?;
                decode_flows(&value, false)
            });
        if let Ok(points) = daily {
            return Ok(MarketFlowSeries {
                points,
                intraday: false,
                source: "东方财富".to_string(),
            });
        }
        self.sina_market_flows().await
    }

    pub async fn sina_market_flows(&self) -> Result<MarketFlowSeries, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.sina.vip,
            "sina.vip",
            "/quotes_service/api/json_v2.php/MoneyFlow.ssl_bkzj_bk",
        )?;
        let snapshot = self
            .fetch(
                &url,
                &[
                    ("page", "1"),
                    ("num", "500"),
                    ("sort", "netamount"),
                    ("asc", "0"),
                    ("fenlei", "0"),
                ],
                sina_referer(&sources),
            )
            .await?;
        let snapshot: Value = serde_json::from_slice(&snapshot)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        let rows = snapshot
            .as_array()
            .ok_or(ProviderError::Missing("新浪行业资金流"))?;
        let sectors = rows
            .iter()
            .filter_map(|row| {
                Some((
                    row.get("category")?.as_str()?.to_string(),
                    row.get("netamount").and_then(number).unwrap_or_default(),
                ))
            })
            .collect::<Vec<_>>();
        if sectors.is_empty() {
            return Err(ProviderError::Missing("新浪行业资金流"));
        }
        let current = sectors.iter().map(|(_, amount)| *amount).sum::<Decimal>();
        let tasks = sectors.iter().map(|(category, _)| {
            let category = category.clone();
            async move { self.sina_sector_flow_history(&category).await }
        });
        let histories = join_all(tasks).await;
        let mut by_day: BTreeMap<String, Decimal> = BTreeMap::new();
        for history in histories.into_iter().flatten() {
            for (day_text, amount) in history {
                *by_day.entry(day_text).or_default() += amount;
            }
        }
        by_day.insert(day(Utc::now()), current);
        let mut points = by_day
            .into_iter()
            .filter_map(|(day_text, amount)| {
                let instant = timestamp(&day_text, "15:00")?;
                Some(MarketFlow {
                    time: SwiftDate::from_utc(instant),
                    main: amount,
                    small: Decimal::ZERO,
                    medium: Decimal::ZERO,
                    large: Decimal::ZERO,
                    huge: Decimal::ZERO,
                })
            })
            .collect::<Vec<_>>();
        if points.is_empty() {
            return Err(ProviderError::Missing("新浪资金流日期"));
        }
        let keep = points.len().saturating_sub(20);
        points.drain(..keep);
        Ok(MarketFlowSeries {
            points,
            intraday: false,
            source: "新浪财经 · 行业汇总（备用）".to_string(),
        })
    }

    async fn sina_sector_flow_history(&self, category: &str) -> Option<Vec<(String, Decimal)>> {
        let sources = self.sources();
        let url = self
            .endpoint(
                &sources.sina.vip,
                "sina.vip",
                "/quotes_service/api/json_v2.php/MoneyFlow.ssl_bkzj_zjlrqs",
            )
            .ok()?;
        let data = self
            .fetch(
                &url,
                &[
                    ("page", "1"),
                    ("num", "20"),
                    ("sort", "opendate"),
                    ("asc", "0"),
                    ("bankuai", category),
                ],
                sina_referer(&sources),
            )
            .await
            .ok()?;
        let value: Value = serde_json::from_slice(&data).ok()?;
        let rows = value.as_array()?;
        Some(
            rows.iter()
                .filter_map(|row| {
                    let day_text = row.get("opendate")?.as_str()?.to_string();
                    let amount = row
                        .get("r0_net")
                        .and_then(number)
                        .or_else(|| row.get("netamount").and_then(number))?;
                    Some((day_text, amount))
                })
                .collect(),
        )
    }

    pub async fn sector_flows(
        &self,
        category: SectorCategory,
        period: SectorPeriod,
    ) -> Result<Vec<SectorFlow>, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.eastmoney.data,
            "eastmoney.data",
            "/dataapi/bkzj/getbkzj",
        )?;
        let data = self
            .fetch(
                &url,
                &[
                    ("key", period.provider_field()),
                    ("code", category.provider_code()),
                ],
                None,
            )
            .await?;
        let value: Value = serde_json::from_slice(&data)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        decode_sectors(&value, period)
    }

    async fn east_quote(
        &self,
        path: &str,
        query: &[(&str, &str)],
        hosts: &[&str],
    ) -> Result<Vec<u8>, ProviderError> {
        let sources = self.sources();
        let mut last_error = ProviderError::Missing("东方财富接口");
        for host in hosts {
            let base = match *host {
                "push2" => &sources.eastmoney.push2,
                "push2his" => &sources.eastmoney.push2his,
                "push2delay" => &sources.eastmoney.push2delay,
                _ => continue,
            };
            let url = match self.endpoint(base, "eastmoney.push2", path) {
                Ok(url) => url,
                Err(error) => {
                    last_error = error;
                    continue;
                }
            };
            let referer = if sources.eastmoney.data.trim().is_empty() {
                None
            } else {
                Some(format!("{}/zjlx/dpzjlx.html", sources.eastmoney.data))
            };
            match self.fetch(&url, query, referer.as_deref()).await {
                Ok(data) => return Ok(data),
                Err(error) => last_error = error,
            }
        }
        Err(last_error)
    }
}

fn sina_referer(sources: &Sources) -> Option<&str> {
    if sources.sina.finance.trim().is_empty() {
        None
    } else {
        Some(sources.sina.finance.as_str())
    }
}

pub fn valid_quote_symbol(symbol: &str) -> bool {
    let digits = |text: &str| !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit());
    if let Some(code) = symbol
        .strip_prefix("sh")
        .or_else(|| symbol.strip_prefix("sz"))
        .or_else(|| symbol.strip_prefix("bj"))
    {
        return code.len() == 6 && digits(code);
    }
    if let Some(code) = symbol.strip_prefix("hk") {
        return code.len() == 5 && digits(code);
    }
    if let Some(code) = symbol.strip_prefix("us") {
        let mut parts = code.split('.');
        let Some(ticker) = parts.next() else {
            return false;
        };
        if ticker.is_empty()
            || ticker.len() > 8
            || !ticker
                .bytes()
                .next()
                .is_some_and(|byte| byte.is_ascii_uppercase())
            || !ticker
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
        {
            return false;
        }
        return match parts.next() {
            None => true,
            Some(suffix) => {
                parts.next().is_none()
                    && !suffix.is_empty()
                    && suffix.len() <= 4
                    && suffix
                        .bytes()
                        .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
            }
        };
    }
    false
}

pub fn decode_tencent_index_trend(
    value: &Value,
    index: MarketIndex,
) -> Result<IndexTrendData, ProviderError> {
    let source = value
        .get("data")
        .and_then(|data| data.get(index.raw()))
        .ok_or(ProviderError::Missing("腾讯指数分时"))?;
    let series = source
        .get("data")
        .ok_or(ProviderError::Missing("分时数据"))?;
    let raw_day = series
        .get("date")
        .and_then(Value::as_str)
        .filter(|day| day.len() == 8)
        .ok_or(ProviderError::Missing("分时日期"))?;
    let day_text = format!("{}-{}-{}", &raw_day[0..4], &raw_day[4..6], &raw_day[6..8]);
    let rows = series
        .get("data")
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("分时行"))?;
    let mut points = Vec::new();
    let mut volumes = Vec::new();
    let mut previous_volume: Option<Decimal> = None;
    for row in rows {
        let Some(row) = row.as_str() else {
            continue;
        };
        let parts = row.split_whitespace().collect::<Vec<_>>();
        if parts.len() < 2 || parts[0].len() != 4 {
            continue;
        }
        let time = format!("{}:{}", &parts[0][0..2], &parts[0][2..4]);
        let Some(instant) = timestamp(&day_text, &time) else {
            continue;
        };
        let Some(price) = decimal(parts[1]) else {
            continue;
        };
        points.push(PlotPoint {
            time: SwiftDate::from_utc(instant),
            value: price,
        });
        if let Some(cumulative) = parts.get(2).and_then(|value| decimal(value)) {
            if cumulative >= Decimal::ZERO {
                let volume = previous_volume
                    .map(|previous| (cumulative - previous).max(Decimal::ZERO))
                    .unwrap_or(cumulative);
                previous_volume = Some(cumulative);
                volumes.push(PlotPoint {
                    time: SwiftDate::from_utc(instant),
                    value: volume,
                });
            }
        }
    }
    if points.is_empty() {
        return Err(ProviderError::Missing("指数分时"));
    }
    let previous_close = source
        .get("qt")
        .and_then(|quotes| quotes.get(index.raw()))
        .and_then(Value::as_array)
        .and_then(|quote| quote.get(4))
        .and_then(number);
    Ok(IndexTrendData {
        source: "腾讯行情".to_string(),
        points,
        previous_close,
        volumes: (!volumes.is_empty()).then_some(volumes),
    })
}

pub fn decode_yahoo_index_trend(
    value: &Value,
    symbol: &str,
) -> Result<IndexTrendData, ProviderError> {
    let result = value
        .get("chart")
        .and_then(|chart| chart.get("result"))
        .and_then(Value::as_array)
        .and_then(|results| results.first())
        .ok_or(ProviderError::Missing("Yahoo chart"))?;
    let meta = result
        .get("meta")
        .ok_or(ProviderError::Missing("Yahoo meta"))?;
    if meta.get("symbol").and_then(Value::as_str) != Some(symbol) {
        return Err(ProviderError::Missing("Yahoo symbol"));
    }
    let times = result
        .get("timestamp")
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("Yahoo timestamp"))?;
    let quote = result
        .get("indicators")
        .and_then(|indicators| indicators.get("quote"))
        .and_then(Value::as_array)
        .and_then(|quotes| quotes.first())
        .ok_or(ProviderError::Missing("Yahoo quote"))?;
    let closes = quote
        .get("close")
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("Yahoo close"))?;
    let volumes = quote.get("volume").and_then(Value::as_array);
    let mut points = Vec::new();
    let mut volume_points = Vec::new();
    for (position, time) in times.iter().enumerate() {
        let Some(seconds) = time.as_i64() else {
            continue;
        };
        if seconds <= 0 {
            continue;
        }
        let Some(date) = DateTime::<Utc>::from_timestamp(seconds, 0) else {
            continue;
        };
        if let Some(price) = closes
            .get(position)
            .and_then(number)
            .filter(|value| *value > Decimal::ZERO)
        {
            points.push(PlotPoint {
                time: SwiftDate::from_utc(date),
                value: price,
            });
        }
        if let Some(volume) = volumes
            .and_then(|values| values.get(position))
            .and_then(number)
            .filter(|value| *value > Decimal::ZERO)
        {
            volume_points.push(PlotPoint {
                time: SwiftDate::from_utc(date),
                value: volume,
            });
        }
    }
    if points.is_empty() {
        return Err(ProviderError::Missing("Yahoo 分时"));
    }
    let previous_close = meta
        .get("previousClose")
        .or_else(|| meta.get("chartPreviousClose"))
        .and_then(number);
    Ok(IndexTrendData {
        source: "Yahoo Finance · 5 分钟间隔".to_string(),
        points,
        previous_close,
        volumes: (!volume_points.is_empty()).then_some(volume_points),
    })
}

pub fn decode_eastmoney_index_trend(value: &Value) -> Result<IndexTrendData, ProviderError> {
    let data = value
        .get("data")
        .ok_or(ProviderError::Missing("东方财富分时"))?;
    let rows = data
        .get("trends")
        .and_then(Value::as_array)
        .ok_or(ProviderError::Missing("trends"))?;
    let mut points = Vec::new();
    let mut volumes = Vec::new();
    for row in rows {
        let Some(row) = row.as_str() else {
            continue;
        };
        let cells = row.split(',').collect::<Vec<_>>();
        if cells.len() < 3 {
            continue;
        }
        let stamp = cells[0].split(' ').collect::<Vec<_>>();
        if stamp.len() != 2 {
            continue;
        }
        let Some(instant) = timestamp(stamp[0], stamp[1]) else {
            continue;
        };
        let Some(price) = decimal(cells[1]) else {
            continue;
        };
        points.push(PlotPoint {
            time: SwiftDate::from_utc(instant),
            value: price,
        });
        if let Some(volume) = decimal(cells[2]).filter(|value| *value >= Decimal::ZERO) {
            volumes.push(PlotPoint {
                time: SwiftDate::from_utc(instant),
                value: volume,
            });
        }
    }
    if points.is_empty() {
        return Err(ProviderError::Missing("东方财富分时"));
    }
    Ok(IndexTrendData {
        source: "东方财富".to_string(),
        points,
        previous_close: data.get("preClose").and_then(number),
        volumes: (!volumes.is_empty()).then_some(volumes),
    })
}
