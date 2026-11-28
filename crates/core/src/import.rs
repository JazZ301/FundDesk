use crate::backup::{BackupError, BoardBackup};
use crate::csv;
use crate::model::{Fund, FundGroup, FundObservation, Holding, PositionRecord};
use rust_decimal::Decimal;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    #[error("无法识别配置文件。请选择 JSON 备份、原插件配置或含基金代码列的 CSV。")]
    Invalid,
    #[error("无法读取自选基金助手配置，请选择或粘贴插件导出的 JSON。")]
    InvalidPlugin,
    #[error("配置中没有可导入的基金。")]
    EmptyPlugin,
    #[error("{0}")]
    Backup(#[from] BackupError),
}

#[derive(Clone, Debug, Default)]
pub struct ImportPreview {
    pub holdings: Vec<Holding>,
    pub duplicates: usize,
    pub invalid: usize,
    pub journals: HashMap<String, Vec<PositionRecord>>,
    pub observations: HashMap<String, FundObservation>,
}

impl ImportPreview {
    pub fn parse(data: &[u8], existing: &[Holding], catalog: &[Fund]) -> Result<Self, ImportError> {
        let by_code = catalog
            .iter()
            .cloned()
            .map(|fund| (fund.code.clone(), fund))
            .collect::<HashMap<_, _>>();
        let mut invalid = 0;
        let mut journals = HashMap::new();
        let mut observations = HashMap::new();

        let incoming = if let Some(backup) = BoardBackup::recognized(data)? {
            journals = backup.board.journals.clone().unwrap_or_default();
            observations = backup.board.observations.clone().unwrap_or_default();
            backup.board.holdings
        } else if let Ok(json) = serde_json::from_slice::<Value>(data) {
            if json.get("fundListGroup").is_some()
                || json.get("fundListM").is_some()
                || json.get("fundList").is_some()
            {
                plugin_rows(&json, &by_code, &mut invalid)
            } else {
                return Err(ImportError::Invalid);
            }
        } else {
            let (holdings, invalid_count) =
                csv::parse(data, &by_code).map_err(|_| ImportError::Invalid)?;
            invalid += invalid_count;
            holdings
        };

        let mut seen = existing
            .iter()
            .map(|holding| holding.id().to_string())
            .collect::<HashSet<_>>();
        let mut duplicates = 0;
        let mut holdings = Vec::new();
        for holding in incoming {
            if !crate::backup::valid_holdings(std::slice::from_ref(&holding)) {
                invalid += 1;
                continue;
            }
            if !seen.insert(holding.id().to_string()) {
                duplicates += 1;
                continue;
            }
            holdings.push(holding);
        }
        let imported = holdings
            .iter()
            .map(|holding| holding.id().to_string())
            .collect::<HashSet<_>>();
        journals.retain(|code, _| imported.contains(code));
        observations.retain(|code, _| imported.contains(code));

        Ok(Self {
            holdings,
            duplicates,
            invalid,
            journals,
            observations,
        })
    }
}

#[derive(Debug)]
pub struct PluginImport {
    holdings: Vec<Holding>,
    report: PluginImportReport,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginImportReport {
    added: usize,
    updated: usize,
    unchanged: usize,
    invalid: usize,
    conflicts: usize,
}

impl PluginImport {
    pub fn parse(text: &str) -> Result<Self, ImportError> {
        let json: Value = serde_json::from_str(text.trim_start_matches('\u{feff}').trim())
            .map_err(|_| ImportError::InvalidPlugin)?;
        if !["fundListGroup", "fundListM", "fundList"]
            .iter()
            .any(|key| json.get(key).is_some_and(Value::is_array))
        {
            return Err(ImportError::InvalidPlugin);
        }

        let mut report = PluginImportReport::default();
        let rows = plugin_rows(&json, &HashMap::new(), &mut report.invalid);
        let mut holdings: Vec<Holding> = Vec::new();
        let mut indices = HashMap::new();
        let mut conflicts = HashSet::new();
        for row in rows {
            let index = indices.entry(row.id().to_owned()).or_insert(holdings.len());
            if let Some(previous) = holdings.get_mut(*index) {
                let conflict = merge_duplicate(&mut previous.shares, row.shares)
                    | merge_duplicate(&mut previous.cost_per_share, row.cost_per_share);
                if conflict {
                    conflicts.insert(row.id().to_owned());
                }
                merge_groups(previous, &row);
                if previous.fund.name == previous.fund.code {
                    previous.fund.name = row.fund.name;
                }
            } else {
                holdings.push(row);
            }
        }
        if holdings.is_empty() {
            return Err(ImportError::EmptyPlugin);
        }
        report.conflicts = conflicts.len();
        Ok(Self { holdings, report })
    }

    pub fn needs_catalog(&self, existing: &[Holding]) -> bool {
        self.holdings
            .iter()
            .any(|row| !existing.iter().any(|holding| holding.id() == row.id()))
    }

    pub fn merge(
        mut self,
        holdings: &mut Vec<Holding>,
        catalog: &[Fund],
        overwrite: bool,
    ) -> PluginImportReport {
        let catalog: HashMap<_, _> = catalog
            .iter()
            .map(|fund| (fund.code.as_str(), fund))
            .collect();
        let indices: HashMap<_, _> = holdings
            .iter()
            .enumerate()
            .map(|(index, holding)| (holding.id().to_owned(), index))
            .collect();
        for mut row in self.holdings {
            if let Some(&index) = indices.get(row.id()) {
                let existing = &mut holdings[index];
                let old = existing.clone();
                if row.shares.is_some() && (overwrite || existing.shares.is_none()) {
                    existing.shares = row.shares;
                }
                if row.cost_per_share.is_some() && (overwrite || existing.cost_per_share.is_none())
                {
                    existing.cost_per_share = row.cost_per_share;
                }
                merge_groups(existing, &row);
                if *existing == old {
                    self.report.unchanged += 1;
                } else {
                    self.report.updated += 1;
                }
            } else {
                if let Some(fund) = catalog.get(row.id()) {
                    row.fund = (*fund).clone();
                }
                holdings.push(row);
                self.report.added += 1;
            }
        }
        self.report
    }
}

fn merge_groups(existing: &mut Holding, incoming: &Holding) {
    for group in incoming.group_values() {
        let groups = existing.groups.get_or_insert_with(Vec::new);
        if !groups.contains(group) {
            groups.push(*group);
        }
    }
}

fn merge_duplicate(existing: &mut Option<Decimal>, incoming: Option<Decimal>) -> bool {
    match (*existing, incoming) {
        (_, None) => false,
        (None, Some(value)) => {
            *existing = Some(value);
            false
        }
        (Some(old), Some(value)) if old.is_zero() && !value.is_zero() => {
            *existing = Some(value);
            false
        }
        (Some(old), Some(value)) => !value.is_zero() && old != value,
    }
}

pub fn export_plugin(holdings: &[Holding]) -> Result<String, serde_json::Error> {
    let rows = |group: Option<FundGroup>| {
        holdings.iter().filter(|holding| {
            Fund::valid_code(holding.id())
                && group.is_none_or(|group| holding.group_values().contains(&group))
        }).map(|holding| json!({
            "code": holding.id(),
            "name": &holding.fund.name,
            "num": holding.shares.map(|value| value.to_string()).unwrap_or_default(),
            "cost": holding.cost_per_share.map(|value| value.to_string()).unwrap_or_default(),
        })).collect::<Vec<_>>()
    };
    let mut groups = vec![json!({ "name": "默认分组", "funds": rows(None) })];
    for group in [FundGroup::Macd, FundGroup::Red] {
        let funds = rows(Some(group));
        if !funds.is_empty() {
            groups.push(json!({ "name": group.title(), "funds": funds }));
        }
    }
    serde_json::to_string_pretty(&json!({
        "openGroup": true,
        "currentGroupIndex": 0,
        "RealtimeGroupIndex": 0,
        "fundListGroup": groups,
        "fundListM": [],
        "fundList": [],
    }))
}

fn plugin_rows(json: &Value, catalog: &HashMap<String, Fund>, invalid: &mut usize) -> Vec<Holding> {
    let lists = |key| {
        json.get(key)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
    };
    let grouped = lists("fundListGroup").flat_map(|group| {
        let group_kind = [FundGroup::Macd, FundGroup::Red]
            .into_iter()
            .find(|kind| group.get("name").and_then(Value::as_str) == Some(kind.title()));
        group
            .get("funds")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(move |row| (row, group_kind))
    });
    let flat = lists("fundListM")
        .chain(lists("fundList"))
        .map(|row| (row, None));

    grouped
        .chain(flat)
        .filter_map(|(item, group)| {
            let raw_code = item
                .get("code")
                .or_else(|| item.get("fundcode"))
                .or_else(|| item.get("fundCode"))
                .unwrap_or(item);
            let Some(code) = plugin_code(raw_code) else {
                *invalid += 1;
                return None;
            };
            let shares = plugin_number(item.get("num").or_else(|| item.get("shares")));
            let cost = plugin_number(item.get("cost").or_else(|| item.get("costPerShare")));
            if shares.is_err() || cost.is_err() {
                *invalid += 1;
                return None;
            }
            let supplied_name = item
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty());
            let fund = catalog.get(&code).cloned().unwrap_or_else(|| Fund {
                code: code.clone(),
                name: supplied_name.unwrap_or(&code).to_string(),
                kind: String::new(),
                initials: String::new(),
                pinyin: String::new(),
            });
            Some(Holding {
                fund,
                shares: shares.unwrap_or_default(),
                cost_per_share: cost.unwrap_or_default().filter(|value| !value.is_zero()),
                groups: group.map(|group| vec![group]),
            })
        })
        .collect()
}

fn plugin_code(value: &Value) -> Option<String> {
    if let Some(text) = value.as_str() {
        if Fund::valid_code(text) {
            return Some(text.to_string());
        }
        return None;
    }
    let number = value.as_f64()?;
    if (0.0..1_000_000.0).contains(&number) && number.fract() == 0.0 {
        return Some(format!("{:06}", number as u32));
    }
    None
}

fn plugin_number(value: Option<&Value>) -> Result<Option<Decimal>, ()> {
    let text = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::String(text)) if text.trim().is_empty() => return Ok(None),
        Some(Value::String(text)) => text.clone(),
        Some(Value::Number(number)) => number.to_string(),
        _ => return Err(()),
    };
    csv::decimal(&text)
        .or_else(|| Decimal::from_scientific(&text).ok())
        .filter(|value| *value >= Decimal::ZERO)
        .map(Some)
        .ok_or(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imports_plugin_json_and_pads_codes() {
        let json = r#"{"fundListM":[{"code":7339,"num":"10000","cost":"1.5","name":"易方达"}],"fundList":["050025"]}"#;
        let preview = ImportPreview::parse(json.as_bytes(), &[], &[]).unwrap();
        assert_eq!(preview.holdings.len(), 2);
        assert_eq!(preview.holdings[0].id(), "007339");
        assert_eq!(preview.holdings[1].id(), "050025");
        assert_eq!(preview.invalid, 0);
    }

    #[test]
    fn roundtrips_stock_plugin_groups_and_exact_decimal_strings() {
        let config = r#"{
            "fundListGroup": [
                {"name":"默认分组","funds":[{"code":"007339","num":0,"cost":""},{"code":"050025","num":"","cost":""}]},
                {"name":"MACD 观察","funds":[{"code":"007339","num":"123.4567890123456789","cost":1.2345}]},
                {"name":"另一组","funds":[{"code":"007339","num":"4","cost":"2"},{"code":"bad","num":5}]}
            ],
            "fundListM":[{"code":1618,"num":12,"cost":"0.75"}],
            "userId":"ignored"
        }"#;
        let mut holdings = Vec::new();
        let report = PluginImport::parse(&format!("\u{feff}{config}"))
            .unwrap()
            .merge(&mut holdings, &[], false);
        assert_eq!((report.added, report.invalid, report.conflicts), (3, 1, 1));
        assert_eq!(
            holdings[0].shares.unwrap().to_string(),
            "123.4567890123456789"
        );
        assert_eq!(holdings[0].group_values(), &[FundGroup::Macd]);
        assert_eq!(holdings[2].id(), "001618");

        let exported = export_plugin(&holdings).unwrap();
        let json: Value = serde_json::from_str(&exported).unwrap();
        assert_eq!(json["fundListM"], json!([]));
        assert_eq!(
            json["fundListGroup"][0]["funds"].as_array().unwrap().len(),
            3
        );
        assert!(json.get("userId").is_none());
        let mut restored = Vec::new();
        PluginImport::parse(&exported)
            .unwrap()
            .merge(&mut restored, &[], false);
        assert_eq!(restored, holdings);
    }

    #[test]
    fn keeps_existing_fields_without_overwrite_and_preserves_blanks_on_overwrite() {
        let mut holdings = Vec::new();
        PluginImport::parse(r#"{"fundListM":[{"code":"000001","num":"8","cost":"1.2"}]}"#)
            .unwrap()
            .merge(&mut holdings, &[], false);
        let config =
            r#"{"fundListM":[{"code":"000001","num":0,"cost":""},{"code":"000002","num":"-1"}]}"#;

        let report = PluginImport::parse(config)
            .unwrap()
            .merge(&mut holdings, &[], false);
        assert_eq!(
            (report.updated, report.unchanged, report.invalid),
            (0, 1, 1)
        );
        assert_eq!(holdings[0].shares, Some(Decimal::new(8, 0)));

        let report = PluginImport::parse(config)
            .unwrap()
            .merge(&mut holdings, &[], true);
        assert_eq!(report.updated, 1);
        assert_eq!(holdings[0].shares, Some(Decimal::ZERO));
        assert_eq!(holdings[0].cost_per_share, Some(Decimal::new(12, 1)));
        assert!(PluginImport::parse(r#"{"showAmount":true}"#).is_err());
    }

    #[test]
    fn skips_existing_and_counts_duplicates() {
        let existing = vec![Holding {
            fund: Fund {
                code: "007339".to_string(),
                name: "已有".to_string(),
                kind: String::new(),
                initials: String::new(),
                pinyin: String::new(),
            },
            shares: None,
            cost_per_share: None,
            groups: None,
        }];
        let csv_text = "基金代码,持有份额\n007339,100\n050025,20\n050025,30\n";
        let preview = ImportPreview::parse(csv_text.as_bytes(), &existing, &[]).unwrap();
        assert_eq!(preview.holdings.len(), 1);
        assert_eq!(preview.duplicates, 2);
    }
}
