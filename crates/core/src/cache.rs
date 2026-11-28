use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Cached<T> {
    pub saved_at: f64,
    pub payload: T,
}

impl<T> Cached<T> {
    pub fn age_seconds(&self, now: f64) -> f64 {
        (now - self.saved_at).max(0.0)
    }
}

pub struct ResearchCache {
    root: PathBuf,
}

impl ResearchCache {
    pub fn new(directory: impl AsRef<Path>) -> Self {
        Self {
            root: directory.as_ref().join("research-v1"),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn path(&self, key: &str) -> PathBuf {
        self.root.join(format!("{}.json", sanitize(key)))
    }

    pub fn read<T: DeserializeOwned>(&self, key: &str) -> Option<Cached<T>> {
        let data = fs::read(self.path(key)).ok()?;
        serde_json::from_slice(&data).ok()
    }

    pub fn write<T: Serialize>(&self, key: &str, payload: &T) -> std::io::Result<()> {
        fs::create_dir_all(&self.root)?;
        let cached = Cached {
            saved_at: now_seconds(),
            payload,
        };
        let bytes = serde_json::to_vec(&cached)?;
        let path = self.path(key);
        let temp = path.with_extension("json.tmp");
        fs::write(&temp, bytes)?;
        fs::rename(&temp, path)
    }

    pub fn remove(&self, key: &str) -> std::io::Result<()> {
        let path = self.path(key);
        if path.exists() {
            fs::remove_file(path)?;
        }
        Ok(())
    }
}

pub fn now_seconds() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

fn sanitize(key: &str) -> String {
    key.chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_reads_and_sanitizes_keys() {
        let directory =
            std::env::temp_dir().join(format!("funddesk-cache-{}", uuid::Uuid::new_v4()));
        let cache = ResearchCache::new(&directory);
        cache
            .write("market-trend-v3/sh000001", &vec![1, 2, 3])
            .unwrap();
        assert!(cache.path("market-trend-v3/sh000001").exists());
        let cached: Cached<Vec<i32>> = cache.read("market-trend-v3/sh000001").unwrap();
        assert_eq!(cached.payload, vec![1, 2, 3]);
        assert!(cached.age_seconds(now_seconds()) < 5.0);
        cache.remove("market-trend-v3/sh000001").unwrap();
        assert!(cache.read::<Vec<i32>>("market-trend-v3/sh000001").is_none());
    }
}
