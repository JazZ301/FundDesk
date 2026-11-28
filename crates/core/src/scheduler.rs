use chrono::{DateTime, Duration, Utc};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RefreshPolicy {
    pub estimate_interval_seconds: i64,
}

impl RefreshPolicy {
    pub fn nav_next_check(&self, now: DateTime<Utc>, failed: bool) -> DateTime<Utc> {
        now + Duration::minutes(if failed { 4 } else { 20 })
    }

    pub fn estimate_retry_delay(&self, failures: u32) -> i64 {
        if failures == 0 {
            return self.estimate_interval_seconds.max(5);
        }
        (self.estimate_interval_seconds * 4).max(30)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskSchedule {
    pub interval_seconds: i64,
    pub failures: u32,
    pub next_at: DateTime<Utc>,
}

impl TaskSchedule {
    pub fn new(interval_seconds: i64, now: DateTime<Utc>) -> Self {
        Self {
            interval_seconds: interval_seconds.max(5),
            failures: 0,
            next_at: now,
        }
    }

    pub fn is_due(&self, now: DateTime<Utc>) -> bool {
        now >= self.next_at
    }

    pub fn mark_success(&mut self, now: DateTime<Utc>) {
        self.failures = 0;
        self.next_at = now + Duration::seconds(self.interval_seconds);
    }

    pub fn mark_failure(&mut self, now: DateTime<Utc>, policy: RefreshPolicy) {
        self.failures = self.failures.saturating_add(1);
        self.next_at = now + Duration::seconds(policy.estimate_retry_delay(self.failures));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(hour: u32, minute: u32) -> DateTime<Utc> {
        use chrono::TimeZone;
        Utc.with_ymd_and_hms(2026, 11, 26, hour, minute, 0).unwrap()
    }

    #[test]
    fn nav_checks_every_twenty_minutes_or_four_after_failure() {
        let policy = RefreshPolicy {
            estimate_interval_seconds: 10,
        };
        let now = at(2, 0);
        assert_eq!(
            policy.nav_next_check(now, false),
            now + Duration::minutes(20)
        );
        assert_eq!(policy.nav_next_check(now, true), now + Duration::minutes(4));
    }

    #[test]
    fn estimate_backoff_is_at_least_thirty_seconds() {
        let policy = RefreshPolicy {
            estimate_interval_seconds: 5,
        };
        assert_eq!(policy.estimate_retry_delay(0), 5);
        assert_eq!(policy.estimate_retry_delay(1), 30);
        let policy = RefreshPolicy {
            estimate_interval_seconds: 60,
        };
        assert_eq!(policy.estimate_retry_delay(2), 240);
    }

    #[test]
    fn schedule_advances_on_success_and_backs_off_on_failure() {
        let now = at(2, 0);
        let mut schedule = TaskSchedule::new(10, now);
        assert!(schedule.is_due(now));
        schedule.mark_success(now);
        assert!(!schedule.is_due(now + Duration::seconds(9)));
        assert!(schedule.is_due(now + Duration::seconds(10)));
        schedule.mark_failure(
            now,
            RefreshPolicy {
                estimate_interval_seconds: 10,
            },
        );
        assert_eq!(schedule.next_at, now + Duration::seconds(40));
        assert_eq!(schedule.failures, 1);
    }
}
