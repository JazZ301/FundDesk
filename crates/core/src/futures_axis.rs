use chrono::{DateTime, Timelike, Utc};
use chrono_tz::Asia::Shanghai;

/// Mirrors `FuturesAxis.tickIndices(times:visible:)`: one label per 1/2/4 hours
/// depending on the visible span, with a minimum pixel-free gap in samples.
pub fn tick_indices(
    times: &[DateTime<Utc>],
    visible: std::ops::RangeInclusive<usize>,
) -> Vec<usize> {
    let lower = *visible.start();
    let upper = *visible.end();
    let count = upper.saturating_sub(lower) + 1;
    if times.is_empty() || upper >= times.len() || count <= 1 {
        return Vec::new();
    }
    let start = times[lower];
    let end = times[upper];
    if end <= start {
        return vec![lower, upper];
    }
    let span = (end - start).num_seconds() as f64;
    let interval = if span <= 6.0 * 3600.0 {
        3600
    } else if span <= 12.0 * 3600.0 {
        7200
    } else {
        14400
    };
    let local = start.with_timezone(&Shanghai);
    let hour_start = local
        .with_minute(0)
        .and_then(|value| value.with_second(0))
        .and_then(|value| value.with_nanosecond(0))
        .unwrap_or(local)
        .with_timezone(&Utc);
    let mut target = hour_start + chrono::Duration::seconds(interval);
    let mut indices = vec![lower];
    for index in visible.clone() {
        let time = times[index];
        if time >= target && target < end {
            if indices.last() != Some(&index) {
                indices.push(index);
            }
            while target <= time {
                target += chrono::Duration::seconds(interval);
            }
        }
    }
    if indices.last() != Some(&upper) {
        indices.push(upper);
    }
    let min_gap = ((count as f64) * 0.08).ceil().max(2.0) as usize;
    let mut spaced = Vec::new();
    for (position, index) in indices.iter().enumerate() {
        if position > 0 && position < indices.len() - 1 && indices[position + 1] - index < min_gap {
            continue;
        }
        spaced.push(*index);
    }
    spaced
}
