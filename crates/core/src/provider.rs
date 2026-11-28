use crate::sources::{join_url, Sources};
use crate::swift::decimal;
use chrono::{FixedOffset, Utc};
use encoding_rs::GBK;
use rust_decimal::prelude::FromPrimitive;
use rust_decimal::{Decimal, RoundingStrategy};
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use std::sync::{Arc, RwLock};
use std::time::Duration;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ProviderError {
    #[error("网络请求失败: {0}")]
    Request(#[from] reqwest::Error),
    #[error("行情响应无法解析: {0}")]
    Parse(String),
    #[error("行情字段缺失: {0}")]
    Missing(&'static str),
    #[error("数据源未配置: {0}")]
    MissingSource(String),
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexQuote {
    pub name: String,
    #[serde(with = "decimal")]
    pub price: Decimal,
    #[serde(with = "decimal")]
    pub prev_close: Decimal,
    #[serde(with = "decimal")]
    pub change: Decimal,
    #[serde(with = "decimal")]
    pub percent: Decimal,
    pub day: String,
    pub time: String,
    pub fetched_at: String,
    pub source: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendPoint {
    pub time: String,
    #[serde(with = "decimal")]
    pub price: Decimal,
    pub volume: i64,
    #[serde(with = "decimal")]
    pub amount: Decimal,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexTrend {
    pub code: String,
    #[serde(with = "decimal")]
    pub prev_close: Decimal,
    pub day: String,
    pub points: Vec<TrendPoint>,
    pub source: String,
}

#[derive(Clone)]
pub struct MarketClient {
    client: reqwest::Client,
    sources: Arc<RwLock<Sources>>,
}

impl MarketClient {
    pub fn new() -> Result<Self, ProviderError> {
        Self::with_sources(Sources::default())
    }

    pub fn with_sources(sources: Sources) -> Result<Self, ProviderError> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(12))
            .gzip(true)
            .brotli(true)
            .deflate(true)
            .build()?;
        Ok(Self {
            client,
            sources: Arc::new(RwLock::new(sources)),
        })
    }

    pub(crate) fn http(&self) -> &reqwest::Client {
        &self.client
    }

    pub fn sources(&self) -> Sources {
        self.sources
            .read()
            .map(|sources| sources.clone())
            .unwrap_or_default()
    }

    pub fn set_sources(&self, sources: Sources) {
        if let Ok(mut current) = self.sources.write() {
            *current = sources;
        }
    }

    pub(crate) fn user_agent(&self) -> String {
        let sources = self.sources();
        if sources.http.user_agent.trim().is_empty() {
            "FundDeskDesktop/1.0".to_string()
        } else {
            sources.http.user_agent
        }
    }

    pub(crate) fn endpoint(
        &self,
        base: &str,
        name: &str,
        path: &str,
    ) -> Result<String, ProviderError> {
        if base.trim().is_empty() {
            return Err(ProviderError::MissingSource(name.to_string()));
        }
        Ok(join_url(base.trim(), path))
    }

    pub async fn shanghai_quote(&self) -> Result<IndexQuote, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(&sources.sina.hq, "sina.hq", "/list=sh000001")?;
        let referer = if sources.sina.finance.trim().is_empty() {
            None
        } else {
            Some(sources.sina.finance.as_str())
        };
        let mut request = self
            .client
            .get(url)
            .header(reqwest::header::USER_AGENT, self.user_agent());
        if let Some(referer) = referer {
            request = request.header(reqwest::header::REFERER, referer);
        }
        let bytes = request.send().await?.error_for_status()?.bytes().await?;
        let (text, _, _) = GBK.decode(&bytes);
        parse_sina_index(&text)
    }

    pub async fn shanghai_trend(&self) -> Result<IndexTrend, ProviderError> {
        let sources = self.sources();
        let url = self.endpoint(
            &sources.tencent.ifzq,
            "tencent.ifzq",
            "/appstock/app/minute/query?code=sh000001",
        )?;
        let mut request = self
            .client
            .get(url)
            .header(reqwest::header::USER_AGENT, self.user_agent());
        if !sources.tencent.portal.trim().is_empty() {
            request = request.header(reqwest::header::REFERER, sources.tencent.portal.as_str());
        }
        let value: serde_json::Value = request.send().await?.error_for_status()?.json().await?;
        parse_tencent_trend(&value, "sh000001")
    }
}

pub fn parse_sina_index(text: &str) -> Result<IndexQuote, ProviderError> {
    let payload = text
        .split_once("=\"")
        .and_then(|(_, rest)| rest.split_once("\";"))
        .map(|(payload, _)| payload)
        .ok_or_else(|| ProviderError::Parse("缺少 hq_str 字符串".to_string()))?;
    let fields = payload.split(',').collect::<Vec<_>>();
    if fields.len() < 32 {
        return Err(ProviderError::Parse(format!(
            "新浪字段数量为 {}，少于 32",
            fields.len()
        )));
    }
    let price = decimal_field(fields[3], "最新价")?;
    let prev_close = decimal_field(fields[2], "昨收")?;
    if prev_close.is_zero() {
        return Err(ProviderError::Parse("昨收为零，无法计算涨跌幅".to_string()));
    }
    let change = price - prev_close;
    let percent = (change / prev_close * Decimal::from(100))
        .round_dp_with_strategy(4, RoundingStrategy::MidpointAwayFromZero);
    let day = fields[30].trim().to_string();
    let time = fields[31].trim().to_string();
    if !is_day(&day) || !is_time(&time) {
        return Err(ProviderError::Parse(format!(
            "新浪行情时间异常: {day} {time}"
        )));
    }
    Ok(IndexQuote {
        name: fields[0].trim().to_string(),
        price,
        prev_close,
        change,
        percent,
        day,
        time,
        fetched_at: now_text(),
        source: "新浪财经".to_string(),
    })
}

pub fn parse_tencent_trend(
    value: &serde_json::Value,
    code: &str,
) -> Result<IndexTrend, ProviderError> {
    let node = value
        .get("data")
        .and_then(|data| data.get(code))
        .ok_or(ProviderError::Missing("data.sh000001"))?;
    let quote = node
        .get("qt")
        .and_then(|qt| qt.get(code))
        .and_then(|quote| quote.as_array())
        .ok_or(ProviderError::Missing("qt.sh000001"))?;
    let prev_close = quote
        .get(4)
        .and_then(|value| value.as_str())
        .ok_or(ProviderError::Missing("昨收"))
        .and_then(|value| decimal_field(value, "昨收"))?;
    let day = quote
        .get(30)
        .and_then(|value| value.as_str())
        .unwrap_or_default()
        .to_string();
    let rows = node
        .get("data")
        .and_then(|data| data.get("data"))
        .and_then(|data| data.as_array())
        .ok_or(ProviderError::Missing("分时数据"))?;

    let mut points = Vec::with_capacity(rows.len());
    let mut previous_volume = 0_i64;
    for row in rows {
        let Some(row) = row.as_str() else { continue };
        let fields = row.split_whitespace().collect::<Vec<_>>();
        if fields.len() < 3 || fields[0].len() != 4 {
            continue;
        }
        let time = format!("{}:{}", &fields[0][0..2], &fields[0][2..4]);
        let Ok(price) = Decimal::from_str(fields[1]) else {
            continue;
        };
        let cumulative = fields[2].parse::<i64>().unwrap_or(previous_volume);
        let volume = (cumulative - previous_volume).max(0);
        previous_volume = cumulative;
        let amount = fields
            .get(3)
            .and_then(|value| Decimal::from_str(value).ok())
            .unwrap_or_default();
        points.push(TrendPoint {
            time,
            price,
            volume,
            amount,
        });
    }
    if points.is_empty() {
        return Err(ProviderError::Parse("分时数据为空".to_string()));
    }
    Ok(IndexTrend {
        code: code.to_string(),
        prev_close,
        day,
        points,
        source: "腾讯行情".to_string(),
    })
}

fn decimal_field(value: &str, name: &'static str) -> Result<Decimal, ProviderError> {
    let trimmed = value.trim();
    if let Ok(value) = Decimal::from_str(trimmed) {
        return Ok(value);
    }
    if let Some(value) = trimmed.parse::<f64>().ok().and_then(Decimal::from_f64) {
        return Ok(value);
    }
    Err(ProviderError::Parse(format!("{name} 不是数值: {trimmed}")))
}

fn is_day(value: &str) -> bool {
    chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d").is_ok()
}

fn is_time(value: &str) -> bool {
    value.len() == 8 && value.split(':').count() == 3
}

pub fn now_text() -> String {
    let offset = FixedOffset::east_opt(8 * 3600).expect("UTC+8");
    Utc::now()
        .with_timezone(&offset)
        .format("%Y-%m-%d %H:%M:%S")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_sina_index_payload() {
        let text = "var hq_str_sh000001=\"上证指数,3490.1446,3476.4697,3476.8816,3497.8092,3455.0360,0,0,454062959,613332810453,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2026-11-26,15:43:57,00,\";";
        let quote = parse_sina_index(text).unwrap();
        assert_eq!(quote.name, "上证指数");
        assert_eq!(quote.price, Decimal::from_str("3476.8816").unwrap());
        assert_eq!(quote.prev_close, Decimal::from_str("3476.4697").unwrap());
        assert_eq!(quote.day, "2026-11-26");
        assert_eq!(quote.time, "15:43:57");
        assert!(quote.percent > Decimal::ZERO);
    }

    #[test]
    fn parses_tencent_trend_payload() {
        let value: serde_json::Value = serde_json::from_str(
            r#"{"data":{"sh000001":{"data":{"data":["0930 3490.14 4730979 5408591854.20","0931 3485.92 22438250 27623180891.90"]},"qt":{"sh000001":["1","上证指数","000001","3476.88","3476.47","3490.14","454062959","0"]}}}}"#,
        )
        .unwrap();
        let trend = parse_tencent_trend(&value, "sh000001").unwrap();
        assert_eq!(trend.points.len(), 2);
        assert_eq!(trend.points[0].time, "09:30");
        assert_eq!(trend.points[1].volume, 22_438_250 - 4_730_979);
        assert_eq!(trend.prev_close, Decimal::from_str("3476.47").unwrap());
    }
}
