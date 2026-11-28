use crate::clock::{day, timestamp};
use crate::csv::decimal;
use crate::market::{
    decode_history_script, index_session, script_json, valid_quote_symbol, PlotPoint,
};
use crate::model::{Fund, Nav};
use crate::provider::{MarketClient, ProviderError};
use crate::swift::SwiftDate;
use chrono::{DateTime, Months, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum HistoryPeriod {
    Month,
    Quarter,
    Half,
    Year,
    ThreeYears,
    FiveYears,
    SinceStart,
}

impl HistoryPeriod {
    pub const ALL: [Self; 7] = [
        Self::Month,
        Self::Quarter,
        Self::Half,
        Self::Year,
        Self::ThreeYears,
        Self::FiveYears,
        Self::SinceStart,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::Month => "近1月",
            Self::Quarter => "近3月",
            Self::Half => "近6月",
            Self::Year => "近1年",
            Self::ThreeYears => "近3年",
            Self::FiveYears => "近5年",
            Self::SinceStart => "成立以来",
        }
    }

    pub fn months(self) -> Option<u32> {
        match self {
            Self::Month => Some(1),
            Self::Quarter => Some(3),
            Self::Half => Some(6),
            Self::Year => Some(12),
            Self::ThreeYears => Some(36),
            Self::FiveYears => Some(60),
            Self::SinceStart => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FundHistory {
    pub navs: Vec<Nav>,
    pub accumulated: Vec<PlotPoint>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub degraded: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub degradation_note: Option<String>,
}

impl FundHistory {
    pub fn new(navs: Vec<Nav>, accumulated: Vec<PlotPoint>) -> Self {
        let mut navs = navs;
        navs.sort_by(|left, right| left.day.cmp(&right.day));
        let mut accumulated = accumulated;
        accumulated.sort_by(|left, right| left.time.0.partial_cmp(&right.time.0).unwrap());
        Self {
            navs,
            accumulated,
            degraded: None,
            degradation_note: None,
        }
    }

    pub fn is_degraded(&self) -> bool {
        self.degraded == Some(true)
    }

    pub fn merging_recent(&self, recent: &[Nav]) -> Self {
        if recent.is_empty() {
            return self.clone();
        }
        let mut by_day = self
            .navs
            .iter()
            .cloned()
            .map(|nav| (nav.day.clone(), nav))
            .collect::<HashMap<_, _>>();
        let mut accumulated = self
            .accumulated
            .iter()
            .cloned()
            .filter_map(|point| point.time.to_utc().map(|time| (day(time), point)))
            .collect::<HashMap<_, _>>();
        for row in recent {
            let replace = by_day
                .get(&row.day)
                .map(|existing| existing.source != "天天基金" || row.source == "天天基金")
                .unwrap_or(true);
            if replace {
                by_day.insert(row.day.clone(), row.clone());
            }
            if let (Some(value), Some(time)) = (row.cumulative_value, timestamp(&row.day, "00:00"))
            {
                accumulated.insert(
                    row.day.clone(),
                    PlotPoint {
                        time: SwiftDate::from_utc(time),
                        value,
                    },
                );
            }
        }
        let mut navs = by_day.into_values().collect::<Vec<_>>();
        navs.sort_by(|left, right| left.day.cmp(&right.day));
        let mut accumulated = accumulated.into_values().collect::<Vec<_>>();
        accumulated.sort_by(|left, right| left.time.0.partial_cmp(&right.time.0).unwrap());
        Self {
            navs,
            accumulated,
            degraded: self.degraded,
            degradation_note: self.degradation_note.clone(),
        }
    }

    pub fn rows(&self, period: HistoryPeriod) -> Vec<Nav> {
        match self.cutoff(period) {
            Some(cut) => self
                .navs
                .iter()
                .filter(|nav| nav.day >= cut)
                .cloned()
                .collect(),
            None => self.navs.clone(),
        }
    }

    pub fn returns(&self, period: HistoryPeriod, money: bool) -> Vec<PlotPoint> {
        let start_index = match self.cutoff(period) {
            Some(cut) => self
                .navs
                .iter()
                .rposition(|nav| nav.day <= cut)
                .unwrap_or(0),
            None => 0,
        };
        let mut result: Vec<PlotPoint> = Vec::new();
        let mut value = Decimal::ONE;
        let mut previous: Option<&Nav> = None;
        for row in self.navs[start_index..].iter() {
            let Some(instant) = timestamp(&row.day, "00:00") else {
                previous = Some(row);
                continue;
            };
            if result.is_empty() {
                result.push(PlotPoint {
                    time: SwiftDate::from_utc(instant),
                    value: Decimal::ZERO,
                });
            } else if let Some(fraction) = return_fraction(row, previous, money) {
                if fraction > -Decimal::ONE {
                    value *= Decimal::ONE + fraction;
                    result.push(PlotPoint {
                        time: SwiftDate::from_utc(instant),
                        value: (value - Decimal::ONE) * Decimal::ONE_HUNDRED,
                    });
                } else {
                    value = Decimal::ONE;
                    result = vec![PlotPoint {
                        time: SwiftDate::from_utc(instant),
                        value: Decimal::ZERO,
                    }];
                }
            } else {
                value = Decimal::ONE;
                result = vec![PlotPoint {
                    time: SwiftDate::from_utc(instant),
                    value: Decimal::ZERO,
                }];
            }
            previous = Some(row);
        }
        result
    }

    fn cutoff(&self, period: HistoryPeriod) -> Option<String> {
        let months = period.months()?;
        let end = self
            .navs
            .last()
            .and_then(|nav| timestamp(&nav.day, "00:00"))?;
        end.checked_sub_months(Months::new(months)).map(day)
    }
}

fn return_fraction(row: &Nav, previous: Option<&Nav>, money: bool) -> Option<Decimal> {
    if money {
        return Some(row.value / Decimal::from(10_000));
    }
    let disclosed = row.rate?;
    if let Some(base) = previous
        .map(|nav| nav.value)
        .filter(|value| *value > Decimal::ZERO)
    {
        let unrounded = (row.value - base) / base;
        if (unrounded * Decimal::ONE_HUNDRED - disclosed).abs() <= Decimal::new(51, 4) {
            return Some(unrounded);
        }
    }
    Some(disclosed / Decimal::ONE_HUNDRED)
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeriodResult {
    pub period: String,
    #[serde(with = "crate::swift::decimal")]
    pub rate: Decimal,
    pub rank: Option<String>,
    pub sample: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FundProfile {
    pub category: Option<String>,
    pub company: Option<String>,
    pub manager_names: Option<String>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub size: Option<Decimal>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub cumulative_nav: Option<Decimal>,
    pub subscription: Option<String>,
    pub redemption: Option<String>,
    pub original_fee: Option<String>,
    pub purchase_fee: Option<String>,
    pub recent: Vec<PeriodResult>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FundManager {
    pub id: String,
    pub name: String,
    pub since: Option<String>,
    pub education: Option<String>,
    pub resume: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagerTenure {
    pub name: String,
    pub since: Option<String>,
    pub end: Option<String>,
    #[serde(
        default,
        with = "crate::swift::decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub rate: Option<Decimal>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FundManagerHistory {
    pub current: Vec<FundManager>,
    pub tenures: Vec<ManagerTenure>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StockMarket {
    Shanghai,
    Shenzhen,
    Beijing,
    HongKong,
    UnitedStates,
}

impl StockMarket {
    pub fn from_exchange(exchange: Option<&str>, legacy: Option<&str>) -> Option<Self> {
        match (exchange, legacy) {
            (Some("0"), Some("4")) | (None, Some("4")) => Some(Self::Beijing),
            (Some("1"), _) | (None, Some("1")) => Some(Self::Shanghai),
            (Some("0"), _) | (None, Some("0")) | (None, Some("2")) => Some(Self::Shenzhen),
            (Some("116"), _) | (None, Some("5")) => Some(Self::HongKong),
            (Some("105"), _) | (Some("106"), _) | (Some("107"), _) | (None, Some("7")) => {
                Some(Self::UnitedStates)
            }
            _ => None,
        }
    }

    pub fn quote_symbol(self, code: &str) -> Option<String> {
        let ticker = if self == Self::UnitedStates {
            code.to_uppercase().replace('-', ".")
        } else {
            code.to_string()
        };
        let symbol = format!("{}{ticker}", self.prefix());
        valid_quote_symbol(&symbol).then_some(symbol)
    }

    fn prefix(self) -> &'static str {
        match self {
            Self::Shanghai => "sh",
            Self::Shenzhen => "sz",
            Self::Beijing => "bj",
            Self::HongKong => "hk",
            Self::UnitedStates => "us",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DisclosureHolding {
    pub code: String,
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(with = "crate::swift::decimal")]
    pub weight: Decimal,
    pub change: Option<String>,
    pub stock_market: Option<StockMarket>,
}

impl DisclosureHolding {
    pub fn stock_quote_symbol(&self) -> Option<String> {
        self.stock_market?.quote_symbol(&self.code)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FundDisclosure {
    pub report_day: Option<String>,
    pub target_code: Option<String>,
    pub target_name: Option<String>,
    pub holdings: Vec<DisclosureHolding>,
}

impl FundDisclosure {
    pub fn needs_stock_market_refresh(&self) -> bool {
        self.holdings
            .iter()
            .any(|holding| holding.kind == "股票" && holding.stock_market.is_none())
    }
}

pub fn decode_profile(value: &Value) -> Result<FundProfile, ProviderError> {
    let data = value.get("Datas").ok_or(ProviderError::Missing("Datas"))?;
    if field(data, "FCODE").is_none() {
        return Err(ProviderError::Missing("FCODE"));
    }
    let periods = [
        ("近1月", "SYL_Y", "RANKM", "MSC"),
        ("近3月", "SYL_3Y", "RANKQ", "QSC"),
        ("近6月", "SYL_6Y", "RANKHY", "HYSC"),
        ("近1年", "SYL_1N", "RANKY", "YSC"),
    ];
    let mut recent = Vec::new();
    for (label, rate, rank, sample) in periods {
        let Some(rate) = field(data, rate).and_then(|text| decimal(&text)) else {
            continue;
        };
        recent.push(PeriodResult {
            period: label.to_string(),
            rate,
            rank: field(data, rank),
            sample: field(data, sample),
        });
    }
    let is_money = data.get("FundType").and_then(Value::as_str) == Some("005")
        || field(data, "FTYPE").is_some_and(|kind| kind.contains("货币"));
    Ok(FundProfile {
        category: field(data, "FTYPE"),
        company: field(data, "JJGS"),
        manager_names: field(data, "JJJL"),
        size: field(data, "ENDNAV").and_then(|text| decimal(&text)),
        cumulative_nav: if is_money {
            None
        } else {
            field(data, "LJJZ").and_then(|text| decimal(&text))
        },
        subscription: field(data, "SGZT"),
        redemption: field(data, "SHZT"),
        original_fee: field(data, "SOURCERATE"),
        purchase_fee: field(data, "RATE"),
        recent,
    })
}

pub fn decode_disclosure(value: &Value) -> Result<FundDisclosure, ProviderError> {
    let data = value.get("Datas").ok_or(ProviderError::Missing("Datas"))?;
    let groups = [
        ("fundStocks", "股票", "GPDM", "GPJC", "JZBL", true),
        ("fundboods", "债券", "ZQDM", "ZQMC", "ZJZBL", false),
        ("fundfofs", "基金", "TZJJDM", "TZJJMC", "ZJZBL", false),
    ];
    let mut holdings = Vec::new();
    for (key, kind, code_key, name_key, ratio_key, stock) in groups {
        let Some(rows) = data.get(key).and_then(Value::as_array) else {
            continue;
        };
        for row in rows {
            let (Some(code), Some(name), Some(weight)) = (
                field(row, code_key),
                field(row, name_key),
                field(row, ratio_key).and_then(|text| decimal(&text)),
            ) else {
                continue;
            };
            if weight < Decimal::ZERO {
                continue;
            }
            let market = if stock {
                StockMarket::from_exchange(
                    field(row, "NEWTEXCH").as_deref(),
                    field(row, "TEXCH").as_deref(),
                )
            } else {
                None
            };
            let mut change = Vec::new();
            if let Some(kind_text) = field(row, "PCTNVCHGTYPE") {
                change.push(kind_text);
            }
            if let Some(amount) = field(row, "PCTNVCHG") {
                change.push(format!("{amount} 个百分点"));
            }
            holdings.push(DisclosureHolding {
                code,
                name,
                kind: kind.to_string(),
                weight,
                change: (!change.is_empty()).then(|| change.join(" ")),
                stock_market: market,
            });
        }
    }
    let target_code = field(data, "ETFCODE").filter(|code| Fund::valid_code(code));
    Ok(FundDisclosure {
        report_day: field(value, "Expansion"),
        target_code,
        target_name: field(data, "ETFSHORTNAME"),
        holdings,
    })
}

pub fn decode_managers(
    current: Option<&Value>,
    tenures: Option<&Value>,
) -> Result<FundManagerHistory, ProviderError> {
    let staff = current
        .and_then(|value| value.get("Datas"))
        .and_then(Value::as_array);
    let records = tenures
        .and_then(|value| value.get("Datas"))
        .and_then(Value::as_array);
    if staff.is_none() && records.is_none() {
        return Err(ProviderError::Missing("基金经理"));
    }
    let mut managers = Vec::new();
    for row in staff.into_iter().flatten() {
        let (Some(id), Some(name)) = (field(row, "MGRID"), field(row, "MGRNAME")) else {
            continue;
        };
        managers.push(FundManager {
            id,
            name,
            since: field(row, "FEMPDATE"),
            education: field(row, "EDUCATION"),
            resume: field(row, "RESUME"),
        });
    }
    let mut history = Vec::new();
    for row in records.into_iter().flatten() {
        let Some(name) = field(row, "MGRNAME") else {
            continue;
        };
        history.push(ManagerTenure {
            name,
            since: field(row, "FEMPDATE"),
            end: field(row, "LEMPDATE"),
            rate: field(row, "PENAVGROWTH").and_then(|text| decimal(&text)),
        });
    }
    Ok(FundManagerHistory {
        current: managers,
        tenures: history,
    })
}

fn field(document: &Value, key: &str) -> Option<String> {
    let raw = match document.get(key) {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Number(number)) => number.to_string(),
        _ => return None,
    };
    let clean = raw.trim();
    if ["", "-", "--", "None", "null"].contains(&clean) {
        return None;
    }
    Some(clean.to_string())
}

impl MarketClient {
    async fn fund_endpoint(&self, path: &str, code: &str) -> Result<Vec<u8>, ProviderError> {
        if !Fund::valid_code(code) {
            return Err(ProviderError::Missing("基金代码"));
        }
        let sources = self.sources();
        let url = self.endpoint(
            &sources.eastmoney.fund_mobile,
            "eastmoney.fundMobile",
            &format!("/{path}"),
        )?;
        self.fetch_public(
            &url,
            &[
                ("FCODE", code),
                ("deviceid", "Wap"),
                ("plat", "Wap"),
                ("product", "EFund"),
                ("version", "2.0.0"),
            ],
        )
        .await
    }

    async fn fetch_public(
        &self,
        url: &str,
        query: &[(&str, &str)],
    ) -> Result<Vec<u8>, ProviderError> {
        let response = self
            .http()
            .get(url)
            .query(query)
            .header(reqwest::header::USER_AGENT, self.user_agent())
            .send()
            .await?
            .error_for_status()?;
        let bytes = response.bytes().await?;
        if bytes.is_empty() {
            return Err(ProviderError::Missing("响应体"));
        }
        Ok(bytes.to_vec())
    }

    pub async fn fund_history(&self, fund: &Fund) -> Result<FundHistory, ProviderError> {
        let recent = self.nav_history(fund, 20).await.ok();
        let sources = self.sources();
        let url = self.endpoint(
            &sources.eastmoney.fund,
            "eastmoney.fund",
            &format!("/pingzhongdata/{}.js", fund.code),
        )?;
        let script = self.fetch_public(&url, &[]).await;
        if let Ok(script) = script {
            let text = String::from_utf8_lossy(&script);
            if let Ok(navs) = decode_history_script(&text, fund.is_money(), 20_000) {
                let accumulated = if fund.is_money() {
                    Vec::new()
                } else {
                    decode_accumulated(&text).unwrap_or_default()
                };
                return Ok(
                    FundHistory::new(navs, accumulated).merging_recent(&recent.unwrap_or_default())
                );
            }
        }
        if let Some(rows) = recent.filter(|rows| !rows.is_empty()) {
            return Ok(FundHistory {
                navs: Vec::new(),
                accumulated: Vec::new(),
                degraded: Some(true),
                degradation_note: Some(
                    "历史净值接口暂时不可用，当前显示最近披露数据。".to_string(),
                ),
            }
            .merging_recent(&rows));
        }
        Err(ProviderError::Missing("历史净值"))
    }

    pub async fn fund_profile(&self, code: &str) -> Result<FundProfile, ProviderError> {
        let data = self
            .fund_endpoint("FundMApi/FundBaseTypeInformation.ashx", code)
            .await?;
        let value: Value = serde_json::from_slice(&data)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        decode_profile(&value)
    }

    pub async fn fund_disclosure(&self, code: &str) -> Result<FundDisclosure, ProviderError> {
        let data = self
            .fund_endpoint("FundMNewApi/FundMNInverstPosition", code)
            .await?;
        let value: Value = serde_json::from_slice(&data)
            .map_err(|error| ProviderError::Parse(error.to_string()))?;
        decode_disclosure(&value)
    }

    pub async fn fund_managers(&self, code: &str) -> Result<FundManagerHistory, ProviderError> {
        let current = self
            .fund_endpoint("FundMApi/FundMangerDetail.ashx", code)
            .await
            .ok()
            .and_then(|data| serde_json::from_slice::<Value>(&data).ok());
        let tenures = self
            .fund_endpoint("FundMApi/FundManagerList.ashx", code)
            .await
            .ok()
            .and_then(|data| serde_json::from_slice::<Value>(&data).ok());
        decode_managers(current.as_ref(), tenures.as_ref())
    }
}

pub fn decode_accumulated(script: &str) -> Result<Vec<PlotPoint>, ProviderError> {
    let value = script_json(script, "Data_ACWorthTrend")?;
    let rows = value.as_array().ok_or(ProviderError::Missing("累计净值"))?;
    let mut points = Vec::new();
    for row in rows {
        let Some(cells) = row.as_array() else {
            continue;
        };
        if cells.len() < 2 {
            continue;
        }
        let Some(millis) = cells[0].as_f64() else {
            continue;
        };
        let Some(value) = cells[1]
            .as_str()
            .and_then(decimal)
            .or_else(|| cells[1].as_f64().and_then(Decimal::from_f64_retain))
        else {
            continue;
        };
        let Some(instant) = DateTime::<Utc>::from_timestamp_millis(millis as i64) else {
            continue;
        };
        points.push(PlotPoint {
            time: SwiftDate::from_utc(instant),
            value,
        });
    }
    points.sort_by(|left, right| left.time.0.partial_cmp(&right.time.0).unwrap());
    Ok(points)
}

pub fn market_session_label(index: crate::market::MarketIndex) -> String {
    index_session(index).time_zone_label
}
