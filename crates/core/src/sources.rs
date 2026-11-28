use serde::{Deserialize, Serialize};
use std::fs;
use std::io::ErrorKind;
use std::path::Path;

const DEFAULT_USER_AGENT: &str = "FundDeskDesktop/1.0";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Sources {
    pub version: u32,
    pub label: String,
    pub eastmoney: EastmoneySources,
    pub sina: SinaSources,
    pub tencent: TencentSources,
    pub yahoo: YahooSources,
    pub http: HttpSources,
}

impl Default for Sources {
    fn default() -> Self {
        Self {
            version: 1,
            label: String::new(),
            eastmoney: EastmoneySources::default(),
            sina: SinaSources::default(),
            tencent: TencentSources::default(),
            yahoo: YahooSources::default(),
            http: HttpSources::default(),
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EastmoneySources {
    pub fund: String,
    pub fund_api: String,
    pub fund_mobile: String,
    pub fund_suggest: String,
    pub fund_f10: String,
    pub data: String,
    pub push2: String,
    pub push2his: String,
    pub push2delay: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SinaSources {
    pub finance: String,
    pub hq: String,
    pub suggest: String,
    pub stock: String,
    pub stock2: String,
    pub vip: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TencentSources {
    pub qt: String,
    pub ifzq: String,
    pub portal: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct YahooSources {
    pub query1: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HttpSources {
    pub user_agent: String,
}

impl Default for HttpSources {
    fn default() -> Self {
        Self {
            user_agent: DEFAULT_USER_AGENT.to_string(),
        }
    }
}

impl Sources {
    pub fn from_json(text: &str) -> Result<Self, String> {
        if text.len() > 64 * 1024 {
            return Err("数据源配置超过 64 KB".to_string());
        }
        let mut sources: Sources = serde_json::from_str(text)
            .map_err(|error| format!("数据源配置不是有效 JSON：{error}"))?;
        if sources.version == 0 {
            sources.version = 1;
        }
        sources.normalize();
        sources.validate()?;
        Ok(sources)
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        match fs::read_to_string(path) {
            Ok(text) => Self::from_json(&text),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(format!("读取数据源配置失败：{error}")),
        }
    }

    /// Load the user's configuration. When the file does not exist yet, copy
    /// the config bundled with the installer into the user data directory so
    /// the app works out of the box. An existing empty file is respected.
    pub fn load_or_seed(path: &Path, builtin: Option<&Path>) -> Result<Self, String> {
        if path.exists() {
            return Self::load(path);
        }
        let Some(builtin_path) = builtin else {
            return Ok(Self::default());
        };
        let defaults =
            Self::load(builtin_path).map_err(|error| format!("内置数据源配置无效：{error}"))?;
        if !defaults.is_configured() {
            return Err("内置数据源配置缺少必要地址".to_string());
        }
        defaults.save(path)?;
        Ok(defaults)
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        self.validate()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| format!("创建数据目录失败：{error}"))?;
        }
        let text = serde_json::to_string_pretty(self)
            .map_err(|error| format!("生成数据源配置失败：{error}"))?;
        let temp = path.with_extension("json.tmp");
        fs::write(&temp, format!("{text}\n")).map_err(|error| format!("写入配置失败：{error}"))?;
        fs::rename(&temp, path).map_err(|error| format!("保存配置失败：{error}"))
    }

    pub fn to_json(&self) -> Result<String, String> {
        serde_json::to_string_pretty(self).map_err(|error| error.to_string())
    }

    pub fn normalized(mut self) -> Self {
        self.normalize();
        self
    }

    fn normalize(&mut self) {
        self.label = self.label.trim().to_string();
        self.http.user_agent = self.http.user_agent.trim().to_string();
        if self.http.user_agent.is_empty() {
            self.http.user_agent = DEFAULT_USER_AGENT.to_string();
        }
        for value in self.urls_mut() {
            *value = value.trim().trim_end_matches('/').to_string();
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.version > 1 {
            return Err(format!("不支持的数据源配置版本：{}", self.version));
        }
        if self.label.chars().count() > 80 {
            return Err("数据源名称最多 80 个字符".to_string());
        }
        if self.http.user_agent.is_empty() || self.http.user_agent.chars().count() > 200 {
            return Err("User-Agent 不能为空且最多 200 个字符".to_string());
        }
        if self
            .http
            .user_agent
            .chars()
            .any(|character| character.is_control())
        {
            return Err("User-Agent 不能包含控制字符".to_string());
        }
        for (name, value) in self.urls() {
            if value.is_empty() {
                continue;
            }
            validate_url(name, value)?;
        }
        Ok(())
    }

    pub fn missing_required(&self) -> Vec<String> {
        self.urls()
            .into_iter()
            .filter(|(name, value)| !matches!(*name, "yahoo.query1") && value.is_empty())
            .map(|(name, _)| name.to_string())
            .collect()
    }

    pub fn is_configured(&self) -> bool {
        self.missing_required().is_empty()
    }

    pub fn has_any(&self) -> bool {
        self.urls().iter().any(|(_, value)| !value.is_empty())
    }

    pub fn urls(&self) -> Vec<(&'static str, &str)> {
        vec![
            ("eastmoney.fund", &self.eastmoney.fund),
            ("eastmoney.fundApi", &self.eastmoney.fund_api),
            ("eastmoney.fundMobile", &self.eastmoney.fund_mobile),
            ("eastmoney.fundSuggest", &self.eastmoney.fund_suggest),
            ("eastmoney.fundF10", &self.eastmoney.fund_f10),
            ("eastmoney.data", &self.eastmoney.data),
            ("eastmoney.push2", &self.eastmoney.push2),
            ("eastmoney.push2his", &self.eastmoney.push2his),
            ("eastmoney.push2delay", &self.eastmoney.push2delay),
            ("sina.finance", &self.sina.finance),
            ("sina.hq", &self.sina.hq),
            ("sina.suggest", &self.sina.suggest),
            ("sina.stock", &self.sina.stock),
            ("sina.stock2", &self.sina.stock2),
            ("sina.vip", &self.sina.vip),
            ("tencent.qt", &self.tencent.qt),
            ("tencent.ifzq", &self.tencent.ifzq),
            ("tencent.portal", &self.tencent.portal),
            ("yahoo.query1", &self.yahoo.query1),
        ]
    }

    fn urls_mut(&mut self) -> Vec<&mut String> {
        vec![
            &mut self.eastmoney.fund,
            &mut self.eastmoney.fund_api,
            &mut self.eastmoney.fund_mobile,
            &mut self.eastmoney.fund_suggest,
            &mut self.eastmoney.fund_f10,
            &mut self.eastmoney.data,
            &mut self.eastmoney.push2,
            &mut self.eastmoney.push2his,
            &mut self.eastmoney.push2delay,
            &mut self.sina.finance,
            &mut self.sina.hq,
            &mut self.sina.suggest,
            &mut self.sina.stock,
            &mut self.sina.stock2,
            &mut self.sina.vip,
            &mut self.tencent.qt,
            &mut self.tencent.ifzq,
            &mut self.tencent.portal,
            &mut self.yahoo.query1,
        ]
    }
}

pub fn join_url(base: &str, path: &str) -> String {
    format!("{}{}", base.trim_end_matches('/'), path)
}

fn validate_url(name: &str, value: &str) -> Result<(), String> {
    let url =
        reqwest::Url::parse(value).map_err(|error| format!("{name} 不是有效 URL：{error}"))?;
    let scheme = url.scheme();
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "::1"));
    if scheme != "https" && !(scheme == "http" && local) {
        return Err(format!("{name} 必须使用 HTTPS（本机 localhost 可用 HTTP）"));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(format!("{name} 不能包含用户名或密码"));
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err(format!("{name} 不能包含查询参数或片段"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_config_is_allowed_but_not_configured() {
        let sources = Sources::from_json("{}").unwrap();
        assert!(!sources.is_configured());
        assert!(!sources.has_any());
    }

    #[test]
    fn rejects_insecure_non_local_urls() {
        let error =
            Sources::from_json(r#"{"eastmoney":{"fund":"http://example.com"}}"#).unwrap_err();
        assert!(error.contains("HTTPS"));
    }

    #[test]
    fn normalizes_trailing_slashes() {
        let sources =
            Sources::from_json(r#"{"eastmoney":{"fund":"https://example.com/fund/"}}"#).unwrap();
        assert_eq!(sources.eastmoney.fund, "https://example.com/fund");
    }

    #[test]
    fn saves_and_loads_config_file() {
        let path = std::env::temp_dir().join(format!(
            "funddesk-sources-{}-{}.json",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let sources = Sources::from_json(
            r#"{"label":"测试","eastmoney":{"fund":"https://example.com/fund"}}"#,
        )
        .unwrap();
        sources.save(&path).unwrap();
        let loaded = Sources::load(&path).unwrap();
        assert_eq!(loaded.label, "测试");
        assert_eq!(loaded.eastmoney.fund, "https://example.com/fund");
        let _ = std::fs::remove_file(path);
    }

    fn temp_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "funddesk-sources-{name}-{}-{}.json",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn complete_config(label: &str) -> String {
        format!(
            r#"{{
                "label": "{label}",
                "eastmoney": {{
                    "fund": "https://example.com/fund",
                    "fundApi": "https://example.com/fund-api",
                    "fundMobile": "https://example.com/fund-mobile",
                    "fundSuggest": "https://example.com/fund-suggest",
                    "fundF10": "https://example.com/fund-f10",
                    "data": "https://example.com/data",
                    "push2": "https://example.com/push2",
                    "push2his": "https://example.com/push2his",
                    "push2delay": "https://example.com/push2delay"
                }},
                "sina": {{
                    "finance": "https://example.com/sina-finance",
                    "hq": "https://example.com/sina-hq",
                    "suggest": "https://example.com/sina-suggest",
                    "stock": "https://example.com/sina-stock",
                    "stock2": "https://example.com/sina-stock2",
                    "vip": "https://example.com/sina-vip"
                }},
                "tencent": {{
                    "qt": "https://example.com/tencent-qt",
                    "ifzq": "https://example.com/tencent-ifzq",
                    "portal": "https://example.com/tencent-portal"
                }},
                "yahoo": {{ "query1": "" }}
            }}"#
        )
    }

    #[test]
    fn seeds_bundled_config_when_user_file_is_missing() {
        let user_path = temp_path("seed-user");
        let builtin_path = temp_path("seed-builtin");
        fs::write(&builtin_path, complete_config("内置默认配置")).unwrap();

        let loaded = Sources::load_or_seed(&user_path, Some(&builtin_path)).unwrap();
        assert!(loaded.is_configured());
        assert_eq!(loaded.label, "内置默认配置");
        assert!(user_path.exists());
        assert_eq!(
            Sources::load(&user_path).unwrap().eastmoney.fund,
            "https://example.com/fund"
        );

        let _ = fs::remove_file(user_path);
        let _ = fs::remove_file(builtin_path);
    }

    #[test]
    fn keeps_existing_empty_user_config() {
        let user_path = temp_path("empty-user");
        let builtin_path = temp_path("empty-builtin");
        fs::write(&user_path, "{}").unwrap();
        fs::write(&builtin_path, complete_config("内置默认配置")).unwrap();

        let loaded = Sources::load_or_seed(&user_path, Some(&builtin_path)).unwrap();
        assert!(!loaded.has_any());

        let _ = fs::remove_file(user_path);
        let _ = fs::remove_file(builtin_path);
    }

    #[test]
    fn reports_invalid_bundled_config() {
        let user_path = temp_path("invalid-user");
        let builtin_path = temp_path("invalid-builtin");
        fs::write(&builtin_path, "not json").unwrap();

        let error = Sources::load_or_seed(&user_path, Some(&builtin_path)).unwrap_err();
        assert!(error.contains("内置数据源配置无效"));
        assert!(!user_path.exists());

        let _ = fs::remove_file(builtin_path);
    }
}
