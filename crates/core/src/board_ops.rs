use crate::model::{Board, Fund, FundGroup, Holding};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::str::FromStr;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FundTableColumn {
    Name,
    EstimateRate,
    DayProfit,
    Value,
    Profit,
    ProfitRate,
    EstimateTime,
    Code,
    Nav,
    NavDate,
    NavRate,
    Estimate,
}

impl FundTableColumn {
    pub const ALL: [Self; 12] = [
        Self::Code,
        Self::Name,
        Self::Value,
        Self::Profit,
        Self::ProfitRate,
        Self::EstimateRate,
        Self::DayProfit,
        Self::NavRate,
        Self::EstimateTime,
        Self::Nav,
        Self::NavDate,
        Self::Estimate,
    ];

    const OPTIONAL: [Self; 3] = [Self::Nav, Self::NavDate, Self::Estimate];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Name => "name",
            Self::EstimateRate => "estimateRate",
            Self::DayProfit => "dayProfit",
            Self::Value => "value",
            Self::Profit => "profit",
            Self::ProfitRate => "profitRate",
            Self::EstimateTime => "estimateTime",
            Self::Code => "code",
            Self::Nav => "nav",
            Self::NavDate => "navDate",
            Self::NavRate => "navRate",
            Self::Estimate => "estimate",
        }
    }
}

impl FromStr for FundTableColumn {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|column| column.raw() == value)
            .ok_or(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FundDetailTab {
    Estimate,
    History,
    Returns,
    Holdings,
    Profile,
    Observation,
}

impl FundDetailTab {
    pub const ALL: [Self; 6] = [
        Self::Estimate,
        Self::History,
        Self::Returns,
        Self::Holdings,
        Self::Profile,
        Self::Observation,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Estimate => "estimate",
            Self::History => "history",
            Self::Returns => "returns",
            Self::Holdings => "holdings",
            Self::Profile => "profile",
            Self::Observation => "observation",
        }
    }
}

impl FromStr for FundDetailTab {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|tab| tab.raw() == value)
            .ok_or(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HoldingPlacement {
    Before,
    After,
}

impl Board {
    /// Adds a fund to the board. Existing funds are kept in place and only
    /// joined to the requested observation group. Returns whether the board
    /// changed.
    pub fn add_holding(&mut self, fund: Fund, group: Option<FundGroup>) -> bool {
        if let Some(existing) = self
            .holdings
            .iter_mut()
            .find(|holding| holding.id() == fund.code)
        {
            return group.is_some_and(|group| existing.join_group(group));
        }
        self.holdings.push(Holding {
            fund,
            shares: None,
            cost_per_share: None,
            groups: group.map(|group| vec![group]),
        });
        true
    }

    pub fn fund_columns(&self) -> Vec<FundTableColumn> {
        let saved = self
            .fund_column_order
            .as_ref()
            .map(|order| {
                order
                    .iter()
                    .filter_map(|raw| raw.parse::<FundTableColumn>().ok())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        dedupe(saved, FundTableColumn::ALL)
    }

    pub fn visible_fund_columns(&self) -> Vec<FundTableColumn> {
        let defaults = self.fund_column_order.is_none() && self.hidden_fund_column_ids.is_none();
        let hidden = self
            .hidden_fund_column_ids
            .as_ref()
            .map(|ids| ids.iter().cloned().collect::<HashSet<_>>())
            .unwrap_or_default();
        self.fund_columns()
            .into_iter()
            .filter(|column| {
                *column == FundTableColumn::Name
                    || (!hidden.contains(column.raw())
                        && !(defaults && FundTableColumn::OPTIONAL.contains(column)))
            })
            .collect()
    }

    pub fn set_visible_fund_columns(&mut self, columns: &HashSet<FundTableColumn>) {
        let hidden = FundTableColumn::ALL
            .into_iter()
            .filter(|column| *column != FundTableColumn::Name && !columns.contains(column))
            .map(|column| column.raw().to_string())
            .collect::<Vec<_>>();
        self.hidden_fund_column_ids = Some(hidden);
    }

    pub fn reorder_visible_fund_columns(&mut self, columns: &[FundTableColumn]) -> bool {
        let visible = self.visible_fund_columns();
        if columns == visible.as_slice()
            || columns.len() != visible.len()
            || columns.iter().copied().collect::<HashSet<_>>()
                != visible.iter().copied().collect::<HashSet<_>>()
        {
            return false;
        }
        let visible_set = visible.iter().copied().collect::<HashSet<_>>();
        let mut ordered = self.fund_columns();
        let slots = ordered
            .iter()
            .enumerate()
            .filter(|(_, column)| visible_set.contains(column))
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        for (slot, column) in slots.into_iter().zip(columns) {
            ordered[slot] = *column;
        }
        if self.fund_column_order.is_none() && self.hidden_fund_column_ids.is_none() {
            self.set_visible_fund_columns(&visible_set);
        }
        self.fund_column_order = Some(
            ordered
                .iter()
                .map(|column| column.raw().to_string())
                .collect(),
        );
        true
    }

    pub fn fund_detail_tabs(&self) -> Vec<FundDetailTab> {
        let saved = self
            .fund_detail_tab_order
            .as_ref()
            .map(|order| {
                order
                    .iter()
                    .filter_map(|raw| raw.parse::<FundDetailTab>().ok())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        dedupe(saved, FundDetailTab::ALL)
    }

    pub fn visible_fund_detail_tabs(&self, shows_observation: bool) -> Vec<FundDetailTab> {
        self.fund_detail_tabs()
            .into_iter()
            .filter(|tab| shows_observation || *tab != FundDetailTab::Observation)
            .collect()
    }

    pub fn move_fund_detail_tab(
        &mut self,
        source: FundDetailTab,
        target: FundDetailTab,
        shows_observation: bool,
    ) -> bool {
        let mut ordered = self.fund_detail_tabs();
        let slots = ordered
            .iter()
            .enumerate()
            .filter(|(_, tab)| shows_observation || **tab != FundDetailTab::Observation)
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        let mut visible = slots
            .iter()
            .map(|index| ordered[*index])
            .collect::<Vec<_>>();
        if source == target {
            return false;
        }
        let (Some(from), Some(to)) = (
            visible.iter().position(|tab| *tab == source),
            visible.iter().position(|tab| *tab == target),
        ) else {
            return false;
        };
        let tab = visible.remove(from);
        visible.insert(to, tab);
        for (slot, tab) in slots.into_iter().zip(visible) {
            ordered[slot] = tab;
        }
        self.fund_detail_tab_order =
            Some(ordered.iter().map(|tab| tab.raw().to_string()).collect());
        true
    }

    pub fn move_holding(
        &mut self,
        code: &str,
        target: &str,
        placement: HoldingPlacement,
        visible_codes: &HashSet<String>,
    ) -> bool {
        if code == target {
            return false;
        }
        let slots = self
            .holdings
            .iter()
            .enumerate()
            .filter(|(_, holding)| visible_codes.contains(holding.id()))
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        let visible = slots
            .iter()
            .map(|index| self.holdings[*index].clone())
            .collect::<Vec<_>>();
        let (Some(source), Some(destination)) = (
            visible.iter().position(|holding| holding.id() == code),
            visible.iter().position(|holding| holding.id() == target),
        ) else {
            return false;
        };
        let insertion = destination as isize
            + if placement == HoldingPlacement::After {
                1
            } else {
                0
            }
            - if source < destination { 1 } else { 0 };
        if source as isize == insertion {
            return false;
        }
        let mut reordered = visible;
        let holding = reordered.remove(source);
        reordered.insert(insertion as usize, holding);
        for (slot, holding) in slots.into_iter().zip(reordered) {
            self.holdings[slot] = holding;
        }
        true
    }
}

fn dedupe<T: Copy + PartialEq + Eq + std::hash::Hash, const N: usize>(
    saved: Vec<T>,
    all: [T; N],
) -> Vec<T> {
    let mut seen = HashSet::new();
    saved
        .into_iter()
        .chain(all)
        .filter(|value| seen.insert(*value))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Fund, Holding};

    fn fund(code: &str) -> Fund {
        Fund {
            code: code.to_string(),
            name: code.to_string(),
            kind: String::new(),
            initials: String::new(),
            pinyin: String::new(),
        }
    }

    fn holding(code: &str) -> Holding {
        Holding {
            fund: fund(code),
            shares: None,
            cost_per_share: None,
            groups: None,
        }
    }

    #[test]
    fn defaults_to_compact_columns_and_hides_by_id() {
        let mut board = Board::default();
        assert_eq!(board.fund_columns(), FundTableColumn::ALL);
        assert_eq!(board.visible_fund_columns(), FundTableColumn::ALL[..9]);
        let mut reordered = board.visible_fund_columns();
        reordered.swap(0, 1);
        assert!(board.reorder_visible_fund_columns(&reordered));
        assert_eq!(board.visible_fund_columns(), reordered);
        board = Board::default();
        board.set_visible_fund_columns(&FundTableColumn::ALL.into_iter().collect());
        assert_eq!(board.visible_fund_columns(), FundTableColumn::ALL);
        board.set_visible_fund_columns(
            &[FundTableColumn::Name, FundTableColumn::Code]
                .into_iter()
                .collect(),
        );
        assert_eq!(
            board.visible_fund_columns(),
            vec![FundTableColumn::Code, FundTableColumn::Name]
        );
        assert!(board
            .hidden_fund_column_ids
            .as_ref()
            .unwrap()
            .contains(&"estimateTime".to_string()));
    }

    #[test]
    fn reorders_only_visible_slots_and_keeps_hidden_positions() {
        let mut board = Board::default();
        board.set_visible_fund_columns(
            &[FundTableColumn::Name, FundTableColumn::Code]
                .into_iter()
                .collect(),
        );
        assert!(board.reorder_visible_fund_columns(&[FundTableColumn::Name, FundTableColumn::Code]));
        assert_eq!(
            board.visible_fund_columns(),
            vec![FundTableColumn::Name, FundTableColumn::Code]
        );
        let full = board.fund_columns();
        assert_eq!(full[0], FundTableColumn::Name);
        assert_eq!(full[1], FundTableColumn::Code);
        assert_eq!(full[2], FundTableColumn::Value);
        assert!(!board.reorder_visible_fund_columns(&[FundTableColumn::Name]));
    }

    #[test]
    fn detail_tabs_keep_hidden_position_when_observation_is_off() {
        let mut board = Board {
            fund_detail_tab_order: Some(vec![
                "observation".to_string(),
                "estimate".to_string(),
                "history".to_string(),
                "returns".to_string(),
                "holdings".to_string(),
                "profile".to_string(),
            ]),
            ..Board::default()
        };
        let visible = board.visible_fund_detail_tabs(false);
        assert!(!visible.contains(&FundDetailTab::Observation));
        assert!(board.move_fund_detail_tab(FundDetailTab::Profile, FundDetailTab::Estimate, false));
        let tabs = board.fund_detail_tabs();
        assert_eq!(tabs[0], FundDetailTab::Observation);
        assert_eq!(tabs[1], FundDetailTab::Profile);
        assert_eq!(tabs[2], FundDetailTab::Estimate);
    }

    #[test]
    fn moves_holding_within_visible_subset() {
        let mut board = Board::default();
        for code in ["A00001", "A00002", "A00003", "A00004"] {
            board.holdings.push(holding(code));
        }
        let visible = ["A00001", "A00003", "A00004"]
            .into_iter()
            .map(str::to_string)
            .collect::<HashSet<_>>();
        assert!(board.move_holding("A00004", "A00001", HoldingPlacement::Before, &visible));
        let order = board
            .holdings
            .iter()
            .map(|holding| holding.id().to_string())
            .collect::<Vec<_>>();
        assert_eq!(order, ["A00004", "A00002", "A00001", "A00003"]);
        assert!(!board.move_holding("A00002", "A00001", HoldingPlacement::Before, &visible));
    }

    #[test]
    fn adds_a_new_fund_directly_to_red_group() {
        let mut board = Board::default();
        assert!(board.add_holding(fund("008163"), Some(FundGroup::Red)));
        let holding = &board.holdings[0];
        assert_eq!(holding.id(), "008163");
        assert_eq!(holding.group_values(), &[FundGroup::Red]);
    }

    #[test]
    fn adding_an_existing_fund_joins_the_requested_group() {
        let mut board = Board::default();
        assert!(board.add_holding(fund("008163"), None));
        assert!(board.holdings[0].group_values().is_empty());
        assert!(board.add_holding(fund("008163"), Some(FundGroup::Red)));
        assert_eq!(board.holdings.len(), 1);
        assert_eq!(board.holdings[0].group_values(), &[FundGroup::Red]);
    }

    #[test]
    fn joining_a_group_is_idempotent_and_keeps_existing_membership() {
        let mut board = Board::default();
        assert!(board.add_holding(fund("008163"), Some(FundGroup::Macd)));
        assert!(board.add_holding(fund("008163"), Some(FundGroup::Red)));
        assert!(!board.add_holding(fund("008163"), Some(FundGroup::Red)));
        assert_eq!(
            board.holdings[0].group_values(),
            &[FundGroup::Macd, FundGroup::Red]
        );
    }

    #[test]
    fn adding_existing_fund_without_group_does_not_duplicate_it() {
        let mut board = Board::default();
        assert!(board.add_holding(fund("008163"), None));
        assert!(!board.add_holding(fund("008163"), None));
        assert_eq!(board.holdings.len(), 1);
        assert!(board.holdings[0].group_values().is_empty());
    }
}
