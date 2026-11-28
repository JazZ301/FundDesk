use crate::model::Estimate;
use crate::swift::SwiftDate;
use chrono::{DateTime, Datelike, NaiveDate, NaiveTime, TimeZone, Timelike, Utc};
use chrono_tz::Asia::Shanghai;

pub fn shanghai() -> chrono_tz::Tz {
    Shanghai
}

pub fn day(date: DateTime<Utc>) -> String {
    date.with_timezone(&Shanghai).format("%Y-%m-%d").to_string()
}

pub fn today() -> String {
    day(Utc::now())
}

/// Parses `YYYY-MM-DD` + `HH:MM[:SS]` in Asia/Shanghai, rejecting impossible dates.
pub fn timestamp(day_text: &str, time: &str) -> Option<DateTime<Utc>> {
    let date = NaiveDate::parse_from_str(day_text, "%Y-%m-%d").ok()?;
    let mut parts = time.split(':');
    let hour: u32 = parts.next()?.parse().ok()?;
    let minute: u32 = parts.next()?.parse().ok()?;
    let second: u32 = parts.next().unwrap_or("0").parse().ok()?;
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let local = date.and_time(NaiveTime::from_hms_opt(hour, minute, second)?);
    let instant = Shanghai.from_local_datetime(&local).single()?;
    let utc = instant.with_timezone(&Utc);
    (day(utc) == day_text).then_some(utc)
}

pub fn minutes_of_day(date: DateTime<Utc>) -> i64 {
    let local = date.with_timezone(&Shanghai);
    i64::from(local.hour()) * 60 + i64::from(local.minute())
}

pub fn estimate_market_closure(date: DateTime<Utc>) -> Option<&'static str> {
    let local = date.with_timezone(&Shanghai);
    if local.weekday().num_days_from_monday() >= 5 {
        return Some("weekend");
    }
    // SSE 2026 calendar: https://www.sse.com.cn/disclosure/dealinstruc/closed/c/c_20251222_10802510.shtml
    if local.year() == 2026
        && matches!(
            (local.month(), local.day()),
            (1, 1..=3)
                | (2, 15..=23)
                | (4, 4..=6)
                | (5, 1..=5)
                | (6, 19..=21)
                | (9, 25..=27)
                | (10, 1..=7)
        )
    {
        return Some("holiday");
    }
    None
}

pub fn can_poll_estimates(date: DateTime<Utc>) -> bool {
    let local = date.with_timezone(&Shanghai);
    let weekday = local.weekday().num_days_from_monday();
    let minute = minutes_of_day(date);
    weekday < 5 && ((550..=705).contains(&minute) || (775..=975).contains(&minute))
}

/// Mirrors `Snapshot.effectiveEstimate(now:)` in the Swift app.
pub fn is_fresh_estimate(quote: &Estimate, now: DateTime<Utc>) -> bool {
    if quote.market_day != day(now) {
        return false;
    }
    let Some(timestamp) = quote.timestamp.to_utc() else {
        return false;
    };
    if timestamp > now + chrono::Duration::seconds(120) {
        return false;
    }
    let minute = minutes_of_day(now);
    let moving_market = (570..=690).contains(&minute) || (780..=900).contains(&minute);
    let max_age = if moving_market {
        chrono::Duration::minutes(25)
    } else {
        chrono::Duration::hours(9)
    };
    now.signed_duration_since(timestamp) <= max_age
}

pub fn swift_now() -> SwiftDate {
    SwiftDate::now()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Estimate;
    use chrono::TimeZone;
    use rust_decimal::Decimal;
    use std::str::FromStr;

    fn at(day_text: &str, time_text: &str) -> DateTime<Utc> {
        timestamp(day_text, time_text).unwrap()
    }

    #[test]
    fn shanghai_day_crosses_utc_midnight() {
        let utc = Utc.with_ymd_and_hms(2026, 11, 25, 16, 30, 0).unwrap();
        assert_eq!(day(utc), "2026-11-26");
    }

    #[test]
    fn rejects_invalid_calendar_days() {
        assert!(timestamp("2026-02-30", "00:00").is_none());
        assert!(timestamp("2026-11-26", "24:00").is_none());
        assert!(timestamp("2026-11-26", "15:43:57").is_some());
    }

    #[test]
    fn poll_window_matches_swift() {
        assert!(can_poll_estimates(at("2026-11-26", "09:10")));
        assert!(can_poll_estimates(at("2026-11-26", "16:15")));
        assert!(!can_poll_estimates(at("2026-11-26", "09:09")));
        assert!(!can_poll_estimates(at("2026-11-28", "10:00")));
    }

    #[test]
    fn estimate_market_closure_distinguishes_non_trading_days() {
        assert_eq!(
            estimate_market_closure(at("2026-11-28", "10:00")),
            Some("weekend")
        );
        assert_eq!(
            estimate_market_closure(at("2026-10-07", "10:00")),
            Some("holiday")
        );
        assert_eq!(estimate_market_closure(at("2026-10-08", "08:00")), None);
    }

    #[test]
    fn estimate_freshness_uses_market_hours() {
        let now = at("2026-11-26", "10:00");
        let fresh = Estimate {
            timestamp: SwiftDate::from_utc(now - chrono::Duration::minutes(10)),
            market_day: "2026-11-26".to_string(),
            base_day: Some("2026-11-25".to_string()),
            value: Decimal::from_str("1.6").unwrap(),
            percent: Decimal::from_str("-0.5").unwrap(),
        };
        assert!(is_fresh_estimate(&fresh, now));
        let stale = Estimate {
            timestamp: SwiftDate::from_utc(now - chrono::Duration::minutes(30)),
            ..fresh.clone()
        };
        assert!(!is_fresh_estimate(&stale, now));
    }
}
