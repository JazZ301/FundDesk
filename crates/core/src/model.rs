use crate::swift::{date, decimal, SwiftDate};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fund {
    pub code: String,
    pub name: String,
    pub kind: String,
    pub initials: String,
    pub pinyin: String,
}

impl Fund {
    pub fn is_money(&self) -> bool {
        self.kind.contains("货币")
    }

    pub fn is_cross_border(&self) -> bool {
        let kind = self.kind.to_lowercase();
        let name = self.name.to_lowercase();
        kind.contains("qdii")
            || name.contains("qdii")
            || self.kind.contains("海外")
            || self.kind.contains("跨境")
    }

    pub fn valid_code(value: &str) -> bool {
        value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_digit())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FundGroup {
    Macd,
    Red,
}

impl FundGroup {
    pub fn title(self) -> &'static str {
        match self {
            Self::Macd => "MACD 观察",
            Self::Red => "红利观察",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Holding {
    pub fund: Fund,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub shares: Option<Decimal>,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub cost_per_share: Option<Decimal>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub groups: Option<Vec<FundGroup>>,
}

impl Holding {
    pub fn id(&self) -> &str {
        &self.fund.code
    }

    pub fn group_values(&self) -> &[FundGroup] {
        self.groups.as_deref().unwrap_or(&[])
    }

    pub fn join_group(&mut self, group: FundGroup) -> bool {
        let groups = self.groups.get_or_insert_with(Vec::new);
        if groups.contains(&group) {
            return false;
        }
        groups.push(group);
        true
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Nav {
    pub day: String,
    #[serde(with = "decimal")]
    pub value: Decimal,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub rate: Option<Decimal>,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub annualized_rate: Option<Decimal>,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub cumulative_value: Option<Decimal>,
    pub source: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Estimate {
    pub timestamp: SwiftDate,
    pub market_day: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_day: Option<String>,
    #[serde(with = "decimal")]
    pub value: Decimal,
    #[serde(with = "decimal")]
    pub percent: Decimal,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    #[serde(default)]
    pub history: Vec<Nav>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimate: Option<Estimate>,
    #[serde(default, with = "date", skip_serializing_if = "Option::is_none")]
    pub nav_checked_at: Option<SwiftDate>,
    #[serde(default, with = "date", skip_serializing_if = "Option::is_none")]
    pub estimate_checked_at: Option<SwiftDate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimate_available: Option<bool>,
}

impl Snapshot {
    pub fn nav(&self) -> Option<&Nav> {
        self.history.last()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservationMetric {
    pub key: String,
    pub label: String,
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservationPoint {
    pub day: String,
    #[serde(with = "decimal")]
    pub value: Decimal,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MacdRating {
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub score: Option<Decimal>,
    pub grade: String,
    pub recommendation: String,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub fee8: Option<Decimal>,
    #[serde(default)]
    pub reasons: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub score_parts: Vec<MacdScorePart>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ValuationAnchor {
    pub key: String,
    pub name: String,
    pub value: String,
    pub score: i32,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MacdScorePart {
    pub label: String,
    pub points: f64,
    pub maximum: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RedValuation {
    pub total: i32,
    pub maximum: i32,
    pub level: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub level_description: Option<String>,
    pub advice: String,
    pub anchors: Vec<ValuationAnchor>,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub one_year_percentile: Option<Decimal>,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub one_year_high: Option<Decimal>,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub one_year_low: Option<Decimal>,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub one_year_return: Option<Decimal>,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub from_high: Option<Decimal>,
    #[serde(
        default,
        with = "decimal::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub relative_difference: Option<Decimal>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relative_label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relative_advice: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FundObservation {
    pub updated_day: String,
    pub source: String,
    pub metrics: Vec<ObservationMetric>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub series: Option<Vec<ObservationPoint>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub macd: Option<MacdRating>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub valuation: Option<RedValuation>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Board {
    #[serde(default)]
    pub holdings: Vec<Holding>,
    #[serde(default)]
    pub snapshots: HashMap<String, Snapshot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observations: Option<HashMap<String, FundObservation>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_interval: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub appearance_theme: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fund_column_order: Option<Vec<String>>,
    #[serde(
        default,
        rename = "hiddenFundColumnIDs",
        skip_serializing_if = "Option::is_none"
    )]
    pub hidden_fund_column_ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fund_detail_tab_order: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub menu_bar_visible: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub menu_bar_items: Option<Vec<String>>,
}

impl Board {
    pub fn refresh_interval_value(&self) -> i32 {
        match self.refresh_interval {
            Some(5) => 5,
            Some(30) => 30,
            Some(60) => 60,
            _ => 10,
        }
    }

    pub fn menu_bar_visible_value(&self) -> bool {
        self.menu_bar_visible.unwrap_or(true)
    }

    pub fn menu_bar_items_value(&self) -> Vec<MenuBarItem> {
        match self.menu_bar_items.as_deref() {
            None => vec![MenuBarItem::Points, MenuBarItem::Rate],
            Some(values) => MenuBarItem::ALL
                .into_iter()
                .filter(|item| values.iter().any(|value| value == item.raw()))
                .collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MenuBarItem {
    Points,
    Rate,
    DayProfit,
}

impl MenuBarItem {
    pub const ALL: [Self; 3] = [Self::Points, Self::Rate, Self::DayProfit];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Points => "points",
            Self::Rate => "rate",
            Self::DayProfit => "dayProfit",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|item| item.raw() == value)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardBackup {
    pub version: i32,
    pub board: Board,
}
