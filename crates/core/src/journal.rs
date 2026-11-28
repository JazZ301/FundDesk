use crate::clock::{timestamp, today};
use crate::model::{Board, Holding, PositionAction, PositionRecord};
use rust_decimal::{Decimal, RoundingStrategy};
use std::fmt;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PositionError {
    Invalid,
    CostMissing,
    TooManyShares,
    PositionMissing,
    RecordMissing,
    JournalBaseUnavailable,
}

impl PositionError {
    pub fn message(self) -> &'static str {
        match self {
            Self::Invalid => "请核对日期、份额、成交净值和费用。",
            Self::CostMissing => "已有持仓缺少单位成本。请先填写成本，再记录加仓。",
            Self::TooManyShares => "赎回份额超过目前的持有份额。",
            Self::PositionMissing => "该基金已不在本地自选中。",
            Self::RecordMissing => "这条流水记录已不存在，请重新打开持仓流水。",
            Self::JournalBaseUnavailable => "无法还原这条流水记录之前的持仓，暂时不能修改或删除。",
        }
    }
}

impl fmt::Display for PositionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.message())
    }
}

impl std::error::Error for PositionError {}

#[derive(Clone, Debug)]
pub struct PositionChange {
    pub action: PositionAction,
    pub day: String,
    pub shares: Option<Decimal>,
    pub price: Option<Decimal>,
    pub fee: Decimal,
    pub distribution: Option<Decimal>,
}

impl PositionChange {
    pub fn new(action: PositionAction, day: impl Into<String>) -> Self {
        Self {
            action,
            day: day.into(),
            shares: None,
            price: None,
            fee: Decimal::ZERO,
            distribution: None,
        }
    }

    pub fn apply(
        &self,
        holding: &Holding,
        current_day: &str,
    ) -> Result<(Holding, PositionRecord), PositionError> {
        if timestamp(&self.day, "00:00").is_none()
            || self.day.as_str() > current_day
            || self.fee < Decimal::ZERO
        {
            return Err(PositionError::Invalid);
        }
        let mut updated = holding.clone();
        let balance = holding.shares.unwrap_or_default();
        let (cash, realized) = match self.action {
            PositionAction::Distribution => {
                let distribution = self
                    .distribution
                    .filter(|value| *value > Decimal::ZERO)
                    .ok_or(PositionError::Invalid)?;
                (distribution, Some(distribution))
            }
            PositionAction::Buy => {
                let shares = self
                    .shares
                    .filter(|value| *value > Decimal::ZERO)
                    .ok_or(PositionError::Invalid)?;
                let price = self
                    .price
                    .filter(|value| *value > Decimal::ZERO)
                    .ok_or(PositionError::Invalid)?;
                if balance > Decimal::ZERO
                    && holding.cost_per_share.is_none()
                    && !holding.fund.is_money()
                {
                    return Err(PositionError::CostMissing);
                }
                let paid = shares * price + self.fee;
                updated.shares = Some(balance + shares);
                updated.cost_per_share = if holding.fund.is_money() {
                    None
                } else {
                    Some(
                        (holding.cost_per_share.unwrap_or_default() * balance + paid)
                            / (balance + shares),
                    )
                };
                (-paid, None)
            }
            PositionAction::Sell => {
                let shares = self
                    .shares
                    .filter(|value| *value > Decimal::ZERO)
                    .ok_or(PositionError::Invalid)?;
                let price = self
                    .price
                    .filter(|value| *value > Decimal::ZERO)
                    .ok_or(PositionError::Invalid)?;
                if self.fee > shares * price {
                    return Err(PositionError::Invalid);
                }
                if shares > balance {
                    return Err(PositionError::TooManyShares);
                }
                updated.shares = Some(balance - shares);
                if balance == shares {
                    updated.cost_per_share = None;
                }
                let cash = shares * price - self.fee;
                let realized = holding.cost_per_share.map(|cost| cash - cost * shares);
                (cash, realized)
            }
        };
        Ok((
            updated,
            PositionRecord {
                id: Uuid::new_v4().hyphenated().to_string().to_uppercase(),
                action: self.action,
                day: self.day.clone(),
                shares: self.shares,
                price: self.price,
                fee: self.fee,
                cash,
                realized,
            },
        ))
    }
}

impl PositionRecord {
    pub fn applying(&self, holding: &Holding) -> Result<Holding, PositionError> {
        if self.fee < Decimal::ZERO {
            return Err(PositionError::Invalid);
        }
        let mut updated = holding.clone();
        let balance = holding.shares.unwrap_or_default();
        match self.action {
            PositionAction::Distribution => Ok(updated),
            PositionAction::Buy => {
                let shares = self
                    .shares
                    .filter(|value| *value > Decimal::ZERO)
                    .ok_or(PositionError::Invalid)?;
                let price = self
                    .price
                    .filter(|value| *value > Decimal::ZERO)
                    .ok_or(PositionError::Invalid)?;
                if balance > Decimal::ZERO
                    && holding.cost_per_share.is_none()
                    && !holding.fund.is_money()
                {
                    return Err(PositionError::CostMissing);
                }
                let paid = shares * price + self.fee;
                updated.shares = Some(balance + shares);
                updated.cost_per_share = if holding.fund.is_money() {
                    None
                } else {
                    Some(
                        (holding.cost_per_share.unwrap_or_default() * balance + paid)
                            / (balance + shares),
                    )
                };
                Ok(updated)
            }
            PositionAction::Sell => {
                let shares = self
                    .shares
                    .filter(|value| *value > Decimal::ZERO)
                    .ok_or(PositionError::Invalid)?;
                let price = self
                    .price
                    .filter(|value| *value > Decimal::ZERO)
                    .ok_or(PositionError::Invalid)?;
                if self.fee > shares * price {
                    return Err(PositionError::Invalid);
                }
                if shares > balance {
                    return Err(PositionError::TooManyShares);
                }
                updated.shares = Some(balance - shares);
                if balance == shares {
                    updated.cost_per_share = None;
                }
                Ok(updated)
            }
        }
    }
}

pub struct PositionJournalReplay;

impl PositionJournalReplay {
    pub fn replay(base: &Holding, records: &[PositionRecord]) -> Result<Holding, PositionError> {
        let mut holding = base.clone();
        for record in records {
            holding = record.applying(&holding)?;
        }
        Ok(holding)
    }

    fn replay_changed_records(
        mut holding: Holding,
        records: &mut [PositionRecord],
    ) -> Result<Holding, PositionError> {
        for record in records {
            let updated = record.applying(&holding)?;
            if record.action == PositionAction::Sell {
                record.realized = holding
                    .cost_per_share
                    .zip(record.shares)
                    .map(|(cost, shares)| record.cash - cost * shares);
            }
            holding = updated;
        }
        Ok(holding)
    }

    pub fn infer_base(current: &Holding, records: &[PositionRecord]) -> Option<Holding> {
        let mut holding = current.clone();
        for record in records.iter().rev() {
            let after = holding.shares.unwrap_or_default();
            match record.action {
                PositionAction::Distribution => continue,
                PositionAction::Buy => {
                    let shares = record.shares.filter(|value| *value > Decimal::ZERO)?;
                    let price = record.price.filter(|value| *value > Decimal::ZERO)?;
                    if record.fee < Decimal::ZERO || after < shares {
                        return None;
                    }
                    let before = after - shares;
                    if before == Decimal::ZERO {
                        holding.shares = Some(Decimal::ZERO);
                        holding.cost_per_share = None;
                    } else if holding.fund.is_money() {
                        holding.shares = Some(before);
                    } else {
                        let cost_after = holding.cost_per_share?;
                        let paid = shares * price + record.fee;
                        let cost_before = normalized_cost((cost_after * after - paid) / before);
                        if cost_before <= Decimal::ZERO {
                            return None;
                        }
                        holding.shares = Some(before);
                        holding.cost_per_share = Some(cost_before);
                    }
                }
                PositionAction::Sell => {
                    let shares = record.shares.filter(|value| *value > Decimal::ZERO)?;
                    let before = after + shares;
                    if after == Decimal::ZERO && !holding.fund.is_money() {
                        let realized = record.realized?;
                        let cost_before = normalized_cost((record.cash - realized) / shares);
                        if cost_before <= Decimal::ZERO {
                            return None;
                        }
                        holding.cost_per_share = Some(cost_before);
                    }
                    holding.shares = Some(before);
                }
            }
        }
        Some(holding)
    }
}

fn normalized_cost(value: Decimal) -> Decimal {
    value.round_dp_with_strategy(8, RoundingStrategy::MidpointNearestEven)
}

fn record_index(records: &[PositionRecord], id: &str) -> Option<usize> {
    records
        .iter()
        .position(|record| record.id.eq_ignore_ascii_case(id))
}

impl Board {
    pub fn delete_journal_record(
        &mut self,
        code: &str,
        record_id: &str,
    ) -> Result<(), PositionError> {
        let index = self
            .holdings
            .iter()
            .position(|holding| holding.id() == code)
            .ok_or(PositionError::PositionMissing)?;
        let records = self
            .journals
            .as_ref()
            .and_then(|journals| journals.get(code))
            .ok_or(PositionError::RecordMissing)?;
        let record_index = record_index(records, record_id).ok_or(PositionError::RecordMissing)?;
        let base = PositionJournalReplay::infer_base(&self.holdings[index], records)
            .ok_or(PositionError::JournalBaseUnavailable)?;
        let before = PositionJournalReplay::replay(&base, &records[..record_index])?;
        let mut updated_records = records.clone();
        updated_records.remove(record_index);
        self.holdings[index] = PositionJournalReplay::replay_changed_records(
            before,
            &mut updated_records[record_index..],
        )?;
        let mut journals = self.journals.clone().unwrap_or_default();
        if updated_records.is_empty() {
            journals.remove(code);
        } else {
            journals.insert(code.to_string(), updated_records);
        }
        self.journals = Some(journals);
        Ok(())
    }

    pub fn replace_journal_record(
        &mut self,
        code: &str,
        record_id: &str,
        change: &PositionChange,
        current_day: &str,
    ) -> Result<(), PositionError> {
        let index = self
            .holdings
            .iter()
            .position(|holding| holding.id() == code)
            .ok_or(PositionError::PositionMissing)?;
        let records = self
            .journals
            .as_ref()
            .and_then(|journals| journals.get(code))
            .ok_or(PositionError::RecordMissing)?;
        let record_index = record_index(records, record_id).ok_or(PositionError::RecordMissing)?;
        let base = PositionJournalReplay::infer_base(&self.holdings[index], records)
            .ok_or(PositionError::JournalBaseUnavailable)?;

        let before = PositionJournalReplay::replay(&base, &records[..record_index])?;
        let (after, mut replacement) = change.apply(&before, current_day)?;
        replacement.id = records[record_index].id.clone();
        let mut updated_records = records.clone();
        updated_records[record_index] = replacement;
        self.holdings[index] = PositionJournalReplay::replay_changed_records(
            after,
            &mut updated_records[record_index + 1..],
        )?;
        let mut journals = self.journals.clone().unwrap_or_default();
        journals.insert(code.to_string(), updated_records);
        self.journals = Some(journals);
        Ok(())
    }
}

pub fn current_day() -> String {
    today()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Fund;

    const CODE: &str = "123456";
    const DAY: &str = "2026-01-01";

    fn board(kind: &str) -> Board {
        Board {
            holdings: vec![Holding {
                fund: Fund {
                    code: CODE.into(),
                    name: "虚构基金".into(),
                    kind: kind.into(),
                    initials: String::new(),
                    pinyin: String::new(),
                },
                shares: None,
                cost_per_share: None,
                groups: None,
            }],
            ..Board::default()
        }
    }

    fn trade(action: PositionAction, shares: i64, price: i64) -> PositionChange {
        let mut trade = PositionChange::new(action, DAY);
        trade.shares = Some(shares.into());
        trade.price = Some(price.into());
        trade
    }

    fn append(board: &mut Board, change: PositionChange) -> String {
        let (holding, record) = change.apply(&board.holdings[0], DAY).unwrap();
        let id = record.id.clone();
        board.holdings[0] = holding;
        board
            .journals
            .get_or_insert_with(Default::default)
            .entry(CODE.into())
            .or_default()
            .push(record);
        id
    }

    #[test]
    fn edit_and_delete_recompute_later_redemption_profit() {
        let mut board = board("股票");
        let first = append(&mut board, trade(PositionAction::Buy, 100, 1));
        let second = append(&mut board, trade(PositionAction::Buy, 100, 3));
        let mut sell = trade(PositionAction::Sell, 50, 4);
        sell.fee = 5.into();
        let redemption = append(&mut board, sell);
        board
            .replace_journal_record(&CODE, &second, &trade(PositionAction::Buy, 100, 5), DAY)
            .unwrap();
        let records = &board.journals.as_ref().unwrap()[CODE];
        assert_eq!(records[0].id, first);
        assert_eq!(records[1].id, second);
        assert_eq!(records[2].id, redemption);
        assert_eq!(records[2].realized, Some(45.into()));
        assert_eq!(board.holdings[0].cost_per_share, Some(3.into()));

        board.delete_journal_record(CODE, &second).unwrap();
        assert_eq!(
            board.journals.as_ref().unwrap()[CODE][1].realized,
            Some(145.into())
        );
        assert_eq!(board.holdings[0].shares, Some(50.into()));
        assert_eq!(board.holdings[0].cost_per_share, Some(1.into()));

        let previous = board.clone();
        assert_eq!(
            board.delete_journal_record(CODE, &first),
            Err(PositionError::TooManyShares)
        );
        assert_eq!(board, previous);
    }

    #[test]
    fn money_fund_allows_edit_and_delete_after_full_redemption() {
        let mut board = board("货币");
        append(&mut board, trade(PositionAction::Buy, 100, 1));
        let redemption = append(&mut board, trade(PositionAction::Sell, 100, 1));
        board
            .replace_journal_record(CODE, &redemption, &trade(PositionAction::Sell, 75, 1), DAY)
            .unwrap();
        assert_eq!(board.holdings[0].shares, Some(25.into()));
        assert_eq!(board.journals.as_ref().unwrap()[CODE][1].realized, None);
        board
            .replace_journal_record(CODE, &redemption, &trade(PositionAction::Sell, 100, 1), DAY)
            .unwrap();
        board.delete_journal_record(CODE, &redemption).unwrap();
        assert_eq!(board.holdings[0].shares, Some(100.into()));
        assert_eq!(board.holdings[0].cost_per_share, None);
    }
}
