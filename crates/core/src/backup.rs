use crate::model::{Board, Holding};
use crate::storage::BoardStorage;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, thiserror::Error)]
pub enum BackupError {
    #[error("无法读取基金看板备份。请选择本应用导出的 JSON 备份文件。")]
    Unsupported,
    #[error("备份含有重复基金或无效的基金代码、份额或成本。")]
    InvalidHoldings,
    #[error("JSON 解析失败: {0}")]
    Json(#[from] serde_json::Error),
    #[error("文件操作失败: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Clone, Debug)]
pub struct BoardBackup {
    pub board: Board,
    pub version: i32,
}

#[derive(Serialize)]
struct Complete<'a> {
    version: i32,
    board: &'a Board,
}

#[derive(Deserialize)]
struct Header {
    version: i32,
}

#[derive(Deserialize)]
struct Legacy {
    version: i32,
    holdings: Vec<Holding>,
    #[serde(default)]
    observations: Option<HashMap<String, crate::model::FundObservation>>,
}

impl BoardBackup {
    pub fn includes_settings(&self) -> bool {
        self.version >= 2
    }

    pub fn includes_snapshots(&self) -> bool {
        self.version == 2 || self.version == 4
    }

    pub fn export(board: &Board) -> Result<Vec<u8>, BackupError> {
        Self::encode(board, 4)
    }

    pub fn export_portable(board: &Board) -> Result<Vec<u8>, BackupError> {
        let mut portable = board.clone();
        portable.snapshots.clear();
        if let Some(observations) = &mut portable.observations {
            for observation in observations.values_mut() {
                observation.series = None;
            }
        }
        Self::encode(&portable, 3)
    }

    pub fn export_restore_point(board: &Board) -> Result<Vec<u8>, BackupError> {
        Self::encode(board, 2)
    }

    fn encode(board: &Board, version: i32) -> Result<Vec<u8>, BackupError> {
        let value = serde_json::to_value(Complete { version, board })?;
        Ok(serde_json::to_vec(&value)?)
    }

    pub fn decode(data: &[u8]) -> Result<Self, BackupError> {
        Self::recognized(data)?.ok_or(BackupError::Unsupported)
    }

    pub fn recognized(data: &[u8]) -> Result<Option<Self>, BackupError> {
        let Ok(header) = serde_json::from_slice::<Header>(data) else {
            return Ok(None);
        };
        let backup = match header.version {
            1 => {
                let legacy: Legacy = serde_json::from_slice(data)?;
                let board = Board {
                    holdings: legacy.holdings,
                    observations: legacy.observations,
                    ..Board::default()
                };
                Self {
                    board,
                    version: legacy.version,
                }
            }
            2..=4 => {
                let value: Value = serde_json::from_slice(data)?;
                let Some(board) = value.get("board") else {
                    return Err(BackupError::Unsupported);
                };
                let board: Board =
                    serde_json::from_value(board.clone()).map_err(|_| BackupError::Unsupported)?;
                Self {
                    board,
                    version: header.version,
                }
            }
            _ => return Ok(None),
        };
        if !valid_holdings(&backup.board.holdings) {
            return Err(BackupError::InvalidHoldings);
        }
        Ok(Some(backup))
    }

    pub fn restored_board(&self, current: &Board) -> Board {
        if self.includes_settings() {
            return self.board.clone();
        }
        let mut restored = current.clone();
        restored.holdings = self.board.holdings.clone();
        let codes = self
            .board
            .holdings
            .iter()
            .map(|holding| holding.id().to_string())
            .collect::<HashSet<_>>();
        restored.snapshots.retain(|code, _| codes.contains(code));
        restored.observations = self.board.observations.clone();
        restored
    }
}

pub fn valid_holdings(holdings: &[Holding]) -> bool {
    let unique = holdings
        .iter()
        .map(|holding| holding.id())
        .collect::<HashSet<_>>();
    unique.len() == holdings.len()
        && holdings.iter().all(|holding| {
            Holding::valid_code(holding.id())
                && holding
                    .shares
                    .map(|value| value >= rust_decimal::Decimal::ZERO)
                    != Some(false)
                && holding
                    .cost_per_share
                    .map(|value| value > rust_decimal::Decimal::ZERO)
                    != Some(false)
        })
}

impl Holding {
    fn valid_code(code: &str) -> bool {
        crate::model::Fund::valid_code(code)
    }
}

pub fn save_restore_point(storage: &BoardStorage, current: &Board) -> std::io::Result<PathBuf> {
    fs::create_dir_all(storage.restore_directory())?;
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    let point = storage.restore_directory().join(format!(
        "{:020.6}-{}.json",
        seconds,
        uuid::Uuid::new_v4()
    ));
    let data = BoardBackup::export_restore_point(current)
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    let temp = point.with_extension("json.tmp");
    fs::write(&temp, data)?;
    fs::rename(&temp, &point)?;
    Ok(point)
}

pub fn latest_restore_point(storage: &BoardStorage) -> Option<PathBuf> {
    let entries = fs::read_dir(storage.restore_directory()).ok()?;
    entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        })
        .max_by(|left, right| left.file_name().cmp(&right.file_name()))
}

/// Saves a restore point of `current`, then writes `board` as the active board.
pub fn restore_board(
    storage: &BoardStorage,
    board: &Board,
    current: &Board,
) -> Result<PathBuf, BackupError> {
    let point = save_restore_point(storage, current)?;
    if let Err(error) = storage.save(board) {
        let _ = fs::remove_file(&point);
        return Err(BackupError::Io(error));
    }
    Ok(point)
}

pub fn restore_point_for(path: &Path) -> Result<Board, BackupError> {
    let data = fs::read(path)?;
    BoardBackup::decode(&data).map(|backup| backup.board)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Fund, FundGroup, Snapshot};
    use rust_decimal::Decimal;
    use std::str::FromStr;

    fn board() -> Board {
        let mut board = Board::default();
        board.holdings.push(Holding {
            fund: Fund {
                code: "007339".to_string(),
                name: "易方达".to_string(),
                kind: "指数型".to_string(),
                initials: String::new(),
                pinyin: String::new(),
            },
            shares: Some(Decimal::from_str("10000").unwrap()),
            cost_per_share: Some(Decimal::from_str("1.5").unwrap()),
            groups: Some(vec![FundGroup::Macd]),
        });
        board
            .snapshots
            .insert("007339".to_string(), Snapshot::default());
        board
    }

    #[test]
    fn v4_roundtrip_and_version_flags() {
        let encoded = BoardBackup::export(&board()).unwrap();
        let backup = BoardBackup::decode(&encoded).unwrap();
        assert_eq!(backup.version, 4);
        assert!(backup.includes_settings());
        assert!(backup.includes_snapshots());
        assert_eq!(backup.board.holdings.len(), 1);
    }

    #[test]
    fn portable_backup_strips_snapshots_and_series() {
        let encoded = BoardBackup::export_portable(&board()).unwrap();
        let backup = BoardBackup::decode(&encoded).unwrap();
        assert_eq!(backup.version, 3);
        assert!(backup.board.snapshots.is_empty());
    }

    #[test]
    fn v1_restore_keeps_current_settings_and_snapshots() {
        let legacy = r#"{"version":1,"holdings":[{"fund":{"code":"050025","name":"博时","kind":"QDII","initials":"BS","pinyin":"boshi"}}]}"#;
        let backup = BoardBackup::decode(legacy.as_bytes()).unwrap();
        let mut current = board();
        current.refresh_interval = Some(30);
        let restored = backup.restored_board(&current);
        assert_eq!(restored.holdings[0].id(), "050025");
        assert_eq!(restored.refresh_interval, Some(30));
        assert!(!restored.snapshots.contains_key("007339"));
    }

    #[test]
    fn rejects_duplicate_and_invalid_holdings() {
        let duplicate = r#"{"version":4,"board":{"holdings":[{"fund":{"code":"007339","name":"A","kind":"","initials":"","pinyin":""}},{"fund":{"code":"007339","name":"B","kind":"","initials":"","pinyin":""}}]}}"#;
        assert!(matches!(
            BoardBackup::decode(duplicate.as_bytes()),
            Err(BackupError::InvalidHoldings)
        ));
        let invalid = r#"{"version":4,"board":{"holdings":[{"fund":{"code":"12345","name":"A","kind":"","initials":"","pinyin":""}}]}}"#;
        assert!(matches!(
            BoardBackup::decode(invalid.as_bytes()),
            Err(BackupError::InvalidHoldings)
        ));
    }
}
