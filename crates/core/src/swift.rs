//! Codecs that match Foundation's JSON encoding used by the Swift app.
//!
//! - `Date` is encoded as seconds since 2001-01-01T00:00:00Z.
//! - `Decimal` is encoded as a bare JSON number, so it is written through
//!   `RawValue` to avoid a trip through `f64`.

use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{de::Error as _, Deserialize, Deserializer, Serialize, Serializer};
use serde_json::value::RawValue;
use std::str::FromStr;

pub const SWIFT_EPOCH_OFFSET: i64 = 978_307_200;

#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct SwiftDate(pub f64);

impl SwiftDate {
    pub fn now() -> Self {
        Self(Utc::now().timestamp_millis() as f64 / 1000.0 - SWIFT_EPOCH_OFFSET as f64)
    }

    pub fn to_utc(self) -> Option<DateTime<Utc>> {
        let millis = ((self.0 + SWIFT_EPOCH_OFFSET as f64) * 1000.0).round();
        if !millis.is_finite() {
            return None;
        }
        DateTime::<Utc>::from_timestamp_millis(millis as i64)
    }

    pub fn from_utc(date: DateTime<Utc>) -> Self {
        Self(date.timestamp_millis() as f64 / 1000.0 - SWIFT_EPOCH_OFFSET as f64)
    }
}

impl Serialize for SwiftDate {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        if self.0.fract() == 0.0 && self.0.abs() < 9_007_199_254_740_992.0 {
            serializer.serialize_i64(self.0 as i64)
        } else {
            serializer.serialize_f64(self.0)
        }
    }
}

impl<'de> Deserialize<'de> for SwiftDate {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = f64::deserialize(deserializer)?;
        if value.is_finite() {
            Ok(Self(value))
        } else {
            Err(D::Error::custom("日期不是有限数值"))
        }
    }
}

pub mod decimal {
    use super::*;

    pub fn serialize<S: Serializer>(value: &Decimal, serializer: S) -> Result<S::Ok, S::Error> {
        let raw = RawValue::from_string(value.to_string()).map_err(serde::ser::Error::custom)?;
        raw.serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Decimal, D::Error> {
        let raw = Box::<RawValue>::deserialize(deserializer)?;
        Decimal::from_str(raw.get().trim_matches('"')).map_err(D::Error::custom)
    }

    pub mod option {
        use super::*;

        pub fn serialize<S: Serializer>(
            value: &Option<Decimal>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match value {
                Some(value) => super::serialize(value, serializer),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<Decimal>, D::Error> {
            let raw = Option::<Box<RawValue>>::deserialize(deserializer)?;
            raw.map(|raw| Decimal::from_str(raw.get().trim_matches('"')).map_err(D::Error::custom))
                .transpose()
        }
    }
}

pub mod date {
    use super::*;

    pub fn serialize<S: Serializer>(
        value: &Option<SwiftDate>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        match value {
            Some(value) => value.serialize(serializer),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<SwiftDate>, D::Error> {
        Option::<SwiftDate>::deserialize(deserializer)
    }
}
