use crate::clock::{day, is_fresh_estimate};
use crate::model::{Board, Estimate, Holding, Nav, Snapshot};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DayProfitExclusion {
    MissingNav,
    MoneyFund,
    IncompletePublishedNav,
    MissingEstimate,
    DifferentMarketDay,
    StaleEstimate,
    MismatchedBase,
}

impl DayProfitExclusion {
    pub fn title(self) -> &'static str {
        match self {
            Self::MissingNav => "缺少正式净值",
            Self::MoneyFund => "货币基金",
            Self::IncompletePublishedNav => "已披露，缺少涨跌幅或前一净值",
            Self::MissingEstimate => "暂无可用估值",
            Self::DifferentMarketDay => "估值归属其他交易日",
            Self::StaleEstimate => "估值时间超出有效范围",
            Self::MismatchedBase => "估值基准日与正式净值日不一致",
        }
    }
}

impl Snapshot {
    pub fn effective_estimate(&self, now: DateTime<Utc>) -> Option<&Estimate> {
        if self.estimate_available == Some(false) {
            return None;
        }
        let estimate = self.estimate.as_ref()?;
        if !is_fresh_estimate(estimate, now) {
            return None;
        }
        if let Some(nav) = self.nav() {
            if estimate.market_day <= nav.day {
                return None;
            }
        }
        Some(estimate)
    }

    pub fn merge_history(&mut self, rows: &[Nav]) {
        let mut by_day = std::collections::HashMap::new();
        for row in &self.history {
            by_day.insert(row.day.clone(), row.clone());
        }
        for row in rows {
            if let Some(existing) = by_day.get(&row.day) {
                if existing.source == "天天基金" && row.source != "天天基金" {
                    continue;
                }
            }
            by_day.insert(row.day.clone(), row.clone());
        }
        let mut values = by_day.into_values().collect::<Vec<_>>();
        values.sort_by(|left, right| left.day.cmp(&right.day));
        let start = values.len().saturating_sub(365);
        self.history = values[start..].to_vec();
    }

    pub fn merge_estimate(&mut self, quote: &Estimate) {
        if self
            .estimate
            .as_ref()
            .is_some_and(|existing| existing.timestamp.0 > quote.timestamp.0)
        {
            return;
        }
        self.estimate = Some(quote.clone());
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FundMetrics {
    pub value: Option<Decimal>,
    pub rate: Option<Decimal>,
    pub profit: Option<Decimal>,
    pub estimated_day_profit: Option<Decimal>,
    pub published_day_profit: Option<Decimal>,
    pub day_profit_exclusion: Option<DayProfitExclusion>,
}

impl FundMetrics {
    pub fn new(holding: &Holding, snapshot: &Snapshot, now: DateTime<Utc>) -> Self {
        let Some(shares) = holding.shares.filter(|shares| *shares > Decimal::ZERO) else {
            return Self {
                day_profit_exclusion: if holding.shares.unwrap_or_default() > Decimal::ZERO {
                    Some(DayProfitExclusion::MissingNav)
                } else {
                    None
                },
                ..Self::default()
            };
        };
        let Some(nav) = snapshot.nav() else {
            return Self {
                day_profit_exclusion: Some(DayProfitExclusion::MissingNav),
                ..Self::default()
            };
        };

        let is_money = holding.fund.is_money() || nav.annualized_rate.is_some();
        let unit_value = if is_money { Decimal::ONE } else { nav.value };
        let value = shares * unit_value;
        let (profit, rate) = match holding.cost_per_share {
            Some(cost) if cost > Decimal::ZERO && !is_money => {
                let profit = (unit_value - cost) * shares;
                let rate = (unit_value - cost) / cost * Decimal::ONE_HUNDRED;
                (Some(profit), Some(rate))
            }
            _ => (None, None),
        };

        let today = day(now);
        let mut estimated = None;
        let mut published = None;
        let mut exclusion = None;

        if is_money {
            exclusion = Some(DayProfitExclusion::MoneyFund);
        } else if nav.day == today {
            let previous = snapshot.history.iter().rev().nth(1);
            match (nav.rate, previous) {
                (Some(nav_rate), Some(previous))
                    if previous.day < nav.day && previous.annualized_rate.is_none() =>
                {
                    published = Some(previous.value * nav_rate / Decimal::ONE_HUNDRED * shares);
                }
                _ => exclusion = Some(DayProfitExclusion::IncompletePublishedNav),
            }
        } else if snapshot
            .estimate
            .as_ref()
            .is_some_and(|estimate| estimate.market_day != today)
        {
            exclusion = Some(DayProfitExclusion::DifferentMarketDay);
        } else if let Some(quote) = snapshot.effective_estimate(now) {
            if quote.base_day.as_deref() == Some(nav.day.as_str()) {
                estimated = Some((quote.value - nav.value) * shares);
            } else {
                exclusion = Some(DayProfitExclusion::MismatchedBase);
            }
        } else {
            exclusion = Some(
                if snapshot.estimate.is_none() || snapshot.estimate_available == Some(false) {
                    DayProfitExclusion::MissingEstimate
                } else {
                    DayProfitExclusion::StaleEstimate
                },
            );
        }

        Self {
            value: Some(value),
            rate,
            profit,
            estimated_day_profit: estimated,
            published_day_profit: published,
            day_profit_exclusion: exclusion,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Portfolio {
    pub day: String,
    pub value: Option<Decimal>,
    pub estimated_day_profit: Option<Decimal>,
    pub published_day_profit: Option<Decimal>,
    pub estimated_day_count: usize,
    pub published_day_count: usize,
    pub holding_count: usize,
    pub day_profit_exclusions: HashMap<DayProfitExclusion, usize>,
    pub profit: Option<Decimal>,
    pub estimated_coverage: Option<Decimal>,
    pub missing_valuation_count: usize,
}

impl Portfolio {
    pub fn new(board: &Board, now: DateTime<Utc>) -> Self {
        let mut portfolio = Self {
            day: day(now),
            ..Self::default()
        };
        let mut estimated_value = Decimal::ZERO;
        for holding in board
            .holdings
            .iter()
            .filter(|holding| holding.shares.unwrap_or_default() > Decimal::ZERO)
        {
            portfolio.holding_count += 1;
            let snapshot = board
                .snapshots
                .get(holding.id())
                .cloned()
                .unwrap_or_default();
            let metrics = FundMetrics::new(holding, &snapshot, now);
            match metrics.value {
                Some(value) => {
                    portfolio.value = Some(portfolio.value.unwrap_or_default() + value);
                    if metrics.estimated_day_profit.is_some() {
                        estimated_value += value;
                    }
                }
                None => portfolio.missing_valuation_count += 1,
            }
            if let Some(profit) = metrics.published_day_profit {
                portfolio.published_day_profit =
                    Some(portfolio.published_day_profit.unwrap_or_default() + profit);
                portfolio.published_day_count += 1;
            } else if let Some(profit) = metrics.estimated_day_profit {
                portfolio.estimated_day_profit =
                    Some(portfolio.estimated_day_profit.unwrap_or_default() + profit);
                portfolio.estimated_day_count += 1;
            } else if let Some(exclusion) = metrics.day_profit_exclusion {
                *portfolio
                    .day_profit_exclusions
                    .entry(exclusion)
                    .or_default() += 1;
            }
            if let Some(profit) = metrics.profit {
                portfolio.profit = Some(portfolio.profit.unwrap_or_default() + profit);
            }
        }
        if let Some(value) = portfolio.value {
            if value > Decimal::ZERO && portfolio.missing_valuation_count == 0 {
                portfolio.estimated_coverage = Some(estimated_value / value * Decimal::ONE_HUNDRED);
            }
        }
        portfolio
    }

    pub fn day_profit(&self) -> Option<Decimal> {
        match (&self.published_day_profit, &self.estimated_day_profit) {
            (None, None) => None,
            (published, estimated) => {
                Some(published.unwrap_or_default() + estimated.unwrap_or_default())
            }
        }
    }

    pub fn covered_day_count(&self) -> usize {
        self.estimated_day_count + self.published_day_count
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct EstimateHealth {
    pub fresh_count: usize,
    pub stale_count: usize,
    pub failed_count: usize,
    pub missing_count: usize,
}

impl EstimateHealth {
    pub fn new(
        board: &Board,
        failures: &std::collections::HashSet<String>,
        now: DateTime<Utc>,
    ) -> Self {
        let mut health = Self::default();
        for holding in board
            .holdings
            .iter()
            .filter(|holding| !holding.fund.is_money())
        {
            if failures.contains(holding.id()) {
                health.failed_count += 1;
                continue;
            }
            let snapshot = board
                .snapshots
                .get(holding.id())
                .cloned()
                .unwrap_or_default();
            if snapshot.effective_estimate(now).is_some() {
                health.fresh_count += 1;
            } else if snapshot.estimate.is_some() {
                health.stale_count += 1;
            } else {
                health.missing_count += 1;
            }
        }
        health
    }

    pub fn issue_count(&self) -> usize {
        self.stale_count + self.failed_count
    }

    pub fn has_issue(&self) -> bool {
        self.issue_count() > 0
    }
}
