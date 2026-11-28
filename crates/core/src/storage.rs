use crate::model::{Board, BoardBackup, Fund};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

pub const DATA_DIR_NAME: &str = "FundDeskDesktop";
pub const LEGACY_DATA_DIR_NAME: &str = "FundDesk";

#[derive(Clone, Debug)]
pub struct OpenResult {
    pub board: Board,
    pub recovered: bool,
    pub source: &'static str,
    pub bytes: usize,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RoundTripReport {
    pub ok: bool,
    pub path: String,
    pub bytes_in: usize,
    pub bytes_out: usize,
    pub holdings: usize,
    pub snapshots: usize,
    pub journals: usize,
    pub observations: usize,
    pub notes: Vec<String>,
}

pub struct BoardStorage {
    directory: PathBuf,
}

impl BoardStorage {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
        }
    }

    /// Mirrors `FUND_DESK_DATA_DIR` from the Swift app.
    pub fn from_env() -> Self {
        if let Some(directory) = std::env::var_os("FUND_DESK_DATA_DIR") {
            return Self::new(PathBuf::from(directory));
        }
        let directory = default_data_dir();
        if let Err(error) = migrate_legacy_data(&directory) {
            let _ = fs::create_dir_all(&directory);
            let _ = fs::write(
                directory.join("migration-error.txt"),
                format!("从旧版数据目录迁移失败: {error}\n"),
            );
        }
        Self::new(directory)
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    pub fn board_path(&self) -> PathBuf {
        self.directory.join("board.json")
    }

    pub fn backup_path(&self) -> PathBuf {
        self.directory.join("board.backup.json")
    }

    pub fn restore_directory(&self) -> PathBuf {
        self.directory.join("restore-points")
    }

    pub fn catalog_path(&self) -> PathBuf {
        self.directory.join("catalog.json")
    }

    /// Optional data-source configuration. `FUND_DESK_SOURCES_FILE` can point
    /// at a shared or test configuration without touching the main data dir.
    pub fn sources_path(&self) -> PathBuf {
        if let Some(path) = std::env::var_os("FUND_DESK_SOURCES_FILE") {
            return PathBuf::from(path);
        }
        self.directory.join("data-sources.json")
    }

    pub fn open(&self) -> OpenResult {
        for (path, source, recovered) in [
            (self.board_path(), "board.json", false),
            (self.backup_path(), "board.backup.json", true),
        ] {
            if let Ok(data) = fs::read(&path) {
                if let Ok(board) = serde_json::from_slice::<Board>(&data) {
                    return OpenResult {
                        board,
                        recovered,
                        source,
                        bytes: data.len(),
                    };
                }
            }
        }
        OpenResult {
            board: Board::default(),
            recovered: self.board_path().exists(),
            source: "empty",
            bytes: 0,
        }
    }

    pub fn save(&self, board: &Board) -> std::io::Result<()> {
        fs::create_dir_all(&self.directory)?;
        let encoded = serde_json::to_vec(board)?;
        let path = self.board_path();

        if let Ok(previous) = fs::read(&path) {
            if serde_json::from_slice::<Board>(&previous).is_ok() {
                let temp = self.backup_path().with_extension("json.tmp");
                write_durable(&temp, &previous)?;
                fs::rename(&temp, self.backup_path())?;
            }
        }

        let temp = path.with_extension("json.tmp");
        write_durable(&temp, &encoded)?;
        fs::rename(&temp, &path)?;
        Ok(())
    }

    pub fn save_backup(&self, board: &Board) -> std::io::Result<Vec<u8>> {
        fs::create_dir_all(&self.directory)?;
        let backup = BoardBackup {
            version: 4,
            board: board.clone(),
        };
        let mut encoded = serde_json::to_vec_pretty(&backup)?;
        encoded.push(b'\n');
        Ok(encoded)
    }

    pub fn load_catalog(&self) -> Vec<Fund> {
        fs::read(self.catalog_path())
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }

    pub fn save_catalog(&self, funds: &[Fund]) -> std::io::Result<()> {
        fs::create_dir_all(&self.directory)?;
        let data = serde_json::to_vec(funds)?;
        let path = self.catalog_path();
        let temp = path.with_extension("json.tmp");
        fs::write(&temp, data)?;
        fs::rename(&temp, path)
    }
}

pub fn roundtrip_file(path: &Path) -> Result<RoundTripReport, String> {
    let data = fs::read(path).map_err(|error| format!("读取失败: {error}"))?;
    let board: Board =
        serde_json::from_slice(&data).map_err(|error| format!("Swift 字段解码失败: {error}"))?;
    let encoded = serde_json::to_vec(&board).map_err(|error| format!("重新编码失败: {error}"))?;
    let second: Board =
        serde_json::from_slice(&encoded).map_err(|error| format!("二次解码失败: {error}"))?;

    let mut notes = Vec::new();
    let dropped = dropped_top_level_keys(&data, &encoded);
    let ok = board == second && dropped.is_none();
    if !ok {
        notes.push("重新编码后的看板与原始数据不等价".to_string());
    }
    if let Some(dropped) = dropped {
        notes.push(format!("重新编码后丢失字段: {}", dropped.join(", ")));
    }
    let unique = board
        .holdings
        .iter()
        .map(|holding| holding.id())
        .collect::<std::collections::HashSet<_>>()
        .len();
    if unique != board.holdings.len() {
        notes.push(format!("发现 {} 只重复基金", board.holdings.len() - unique));
    }
    if let Some(unknown) = unknown_top_level_keys(&data) {
        notes.push(format!("顶层存在未建模字段: {}", unknown.join(", ")));
    }

    Ok(RoundTripReport {
        ok,
        path: path.display().to_string(),
        bytes_in: data.len(),
        bytes_out: encoded.len(),
        holdings: board.holdings.len(),
        snapshots: board.snapshots.len(),
        journals: board.journal_count(),
        observations: board
            .observations
            .as_ref()
            .map_or(0, std::collections::HashMap::len),
        notes,
    })
}

fn unknown_top_level_keys(data: &[u8]) -> Option<Vec<String>> {
    let value: serde_json::Value = serde_json::from_slice(data).ok()?;
    let object = value.as_object()?;
    let known = [
        "holdings",
        "snapshots",
        "observations",
        "journals",
        "refreshInterval",
        "appearanceTheme",
        "fundColumnOrder",
        "hiddenFundColumnIDs",
        "fundDetailTabOrder",
    ];
    let unknown = object
        .keys()
        .filter(|key| !known.contains(&key.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    (!unknown.is_empty()).then_some(unknown)
}

fn dropped_top_level_keys(original: &[u8], encoded: &[u8]) -> Option<Vec<String>> {
    let before: serde_json::Value = serde_json::from_slice(original).ok()?;
    let after: serde_json::Value = serde_json::from_slice(encoded).ok()?;
    let before = before.as_object()?;
    let after = after.as_object()?;
    let dropped = before
        .keys()
        .filter(|key| !after.contains_key(*key))
        .cloned()
        .collect::<Vec<_>>();
    (!dropped.is_empty()).then_some(dropped)
}

fn write_durable(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let mut file = fs::File::create(path)?;
    file.write_all(data)?;
    file.sync_all()?;
    Ok(())
}

pub fn default_data_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home)
                .join("Library")
                .join("Application Support")
                .join(DATA_DIR_NAME);
        }
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(app_data) = std::env::var_os("APPDATA") {
            return PathBuf::from(app_data).join(DATA_DIR_NAME);
        }
    }
    std::env::temp_dir().join(DATA_DIR_NAME)
}

pub fn legacy_data_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            return Some(
                PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join(LEGACY_DATA_DIR_NAME),
            );
        }
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(app_data) = std::env::var_os("APPDATA") {
            return Some(PathBuf::from(app_data).join(LEGACY_DATA_DIR_NAME));
        }
    }
    None
}

pub fn migrate_legacy_data(target: &Path) -> std::io::Result<bool> {
    let Some(legacy) = legacy_data_dir() else {
        return Ok(false);
    };
    migrate_data(&legacy, target)
}

fn migrate_data(legacy: &Path, target: &Path) -> std::io::Result<bool> {
    if legacy == target
        || !legacy.is_dir()
        || target.join("board.json").is_file()
        || target.join("board.backup.json").is_file()
    {
        return Ok(false);
    }
    fs::create_dir_all(target)?;
    copy_contents(legacy, target)?;
    for sentinel in ["board.backup.json", "board.json"] {
        let source = legacy.join(sentinel);
        if source.is_file() {
            fs::copy(&source, target.join(sentinel))?;
        }
    }
    Ok(true)
}

fn copy_contents(source: &Path, target: &Path) -> std::io::Result<()> {
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let name = entry.file_name();
        if matches!(
            name.to_string_lossy().as_ref(),
            "trace.log" | "migration-error.txt" | "board.json" | "board.backup.json"
        ) {
            continue;
        }
        let from = entry.path();
        let to = target.join(&name);
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            fs::create_dir_all(&to)?;
            copy_contents(&from, &to)?;
        } else if file_type.is_file() {
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("funddesk-{name}-{}-{stamp}", std::process::id()))
    }

    #[test]
    fn migrates_legacy_data_once_without_overwriting_new_board() {
        let root = temp_root("migration");
        let legacy = root.join("legacy");
        let target = root.join("target");
        fs::create_dir_all(legacy.join("research-v1")).unwrap();
        fs::write(legacy.join("board.json"), br#"{"holdings":[]}"#).unwrap();
        fs::write(legacy.join("board.backup.json"), br#"{"holdings":[]}"#).unwrap();
        fs::write(legacy.join("catalog.json"), b"[]").unwrap();
        fs::write(legacy.join("research-v1").join("fund.json"), b"{}").unwrap();
        fs::write(legacy.join("trace.log"), b"old trace").unwrap();

        assert!(migrate_data(&legacy, &target).unwrap());
        assert!(target.join("board.json").is_file());
        assert!(target.join("catalog.json").is_file());
        assert!(target.join("research-v1").join("fund.json").is_file());
        assert!(!target.join("trace.log").exists());

        fs::write(
            target.join("board.json"),
            br#"{"holdings":[{"code":"new"}]}"#,
        )
        .unwrap();
        assert!(!migrate_data(&legacy, &target).unwrap());
        assert_eq!(
            fs::read_to_string(target.join("board.json")).unwrap(),
            r#"{"holdings":[{"code":"new"}]}"#
        );
        fs::remove_dir_all(root).unwrap();
    }
}
