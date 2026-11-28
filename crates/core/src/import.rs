use crate::backup::{BackupError, BoardBackup};
use crate::csv;
use crate::model::{Fund, FundObservation, Holding, PositionRecord};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    #[error("无法识别配置文件。请选择 JSON 备份或含基金代码列的 CSV。")]
    Invalid,
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

#[derive(Deserialize)]
pub struct HoldingsImportRow {
    code: String,
    name: Option<String>,
    shares: Option<String>,
    cost: Option<String>,
}

#[derive(Debug)]
pub struct HoldingsImport {
    holdings: Vec<Holding>,
}

#[derive(Debug, Default, Serialize)]
pub struct HoldingsImportReport {
    added: usize,
    updated: usize,
    unchanged: usize,
}

impl HoldingsImport {
    pub fn from_rows(rows: Vec<HoldingsImportRow>) -> Result<Self, String> {
        if rows.is_empty() {
            return Err("没有可导入的基金。".to_string());
        }

        let mut seen = HashSet::new();
        let mut holdings = Vec::with_capacity(rows.len());
        for row in rows {
            let code = row.code;
            if !Fund::valid_code(&code) {
                return Err("基金代码须为六位数字。".to_string());
            }
            if !seen.insert(code.clone()) {
                return Err(format!("基金代码 {code} 重复。"));
            }
            let shares = import_decimal(row.shares.as_deref())
                .map_err(|()| format!("基金 {code} 的份额无效。"))?;
            let cost = import_decimal(row.cost.as_deref())
                .map_err(|()| format!("基金 {code} 的每份成本无效。"))?;
            if cost.is_some_and(|value| value.is_zero()) {
                return Err(format!("基金 {code} 的每份成本须大于 0。"));
            }
            if shares.is_none() && cost.is_none() {
                return Err(format!("基金 {code} 缺少份额和每份成本。"));
            }

            holdings.push(Holding {
                fund: Fund {
                    name: row
                        .name
                        .filter(|name| !name.trim().is_empty())
                        .unwrap_or_else(|| code.clone()),
                    code,
                    kind: String::new(),
                    initials: String::new(),
                    pinyin: String::new(),
                },
                shares,
                cost_per_share: cost,
                groups: None,
            });
        }
        Ok(Self { holdings })
    }

    pub fn needs_catalog(&self, existing: &[Holding]) -> bool {
        self.holdings
            .iter()
            .any(|row| !existing.iter().any(|holding| holding.id() == row.id()))
    }

    pub fn merge(
        self,
        holdings: &mut Vec<Holding>,
        catalog: &[Fund],
        overwrite: bool,
    ) -> HoldingsImportReport {
        let mut report = HoldingsImportReport::default();
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
                if *existing == old {
                    report.unchanged += 1;
                } else {
                    report.updated += 1;
                }
            } else {
                if let Some(fund) = catalog.get(row.id()) {
                    row.fund = (*fund).clone();
                }
                holdings.push(row);
                report.added += 1;
            }
        }
        report
    }
}

fn import_decimal(text: Option<&str>) -> Result<Option<Decimal>, ()> {
    text.map(|value| {
        Decimal::from_str_exact(value)
            .ok()
            .filter(|number| *number >= Decimal::ZERO)
            .ok_or(())
    })
    .transpose()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn import_rows(json: &str) -> Result<HoldingsImport, String> {
        HoldingsImport::from_rows(serde_json::from_str(json).unwrap())
    }

    #[test]
    fn keeps_existing_fields_and_preserves_blanks_on_overwrite() {
        let mut holdings = Vec::new();
        import_rows(r#"[{"code":"000001","shares":"8","cost":"1.234567890123456789"}]"#)
            .unwrap()
            .merge(&mut holdings, &[], false);
        let rows = r#"[{"code":"000001","shares":"0"}]"#;

        let report = import_rows(rows).unwrap().merge(&mut holdings, &[], false);
        assert_eq!((report.updated, report.unchanged), (0, 1));
        assert_eq!(holdings[0].shares, Some(Decimal::new(8, 0)));

        let report = import_rows(rows).unwrap().merge(&mut holdings, &[], true);
        assert_eq!(report.updated, 1);
        assert_eq!(holdings[0].id(), "000001");
        assert_eq!(holdings[0].shares, Some(Decimal::ZERO));
        assert_eq!(
            holdings[0].cost_per_share.unwrap().to_string(),
            "1.234567890123456789"
        );
    }

    #[test]
    fn rejects_invalid_or_duplicate_rows() {
        for rows in [
            r#"[]"#,
            r#"[{"code":"1","shares":"1"}]"#,
            r#"[{"code":"000001","shares":"-1"}]"#,
            r#"[{"code":"000001","cost":"0"}]"#,
            r#"[{"code":"000001"}]"#,
            r#"[{"code":"000001","shares":"1"},{"code":"000001","cost":"1"}]"#,
        ] {
            assert!(import_rows(rows).is_err(), "{rows}");
        }
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
