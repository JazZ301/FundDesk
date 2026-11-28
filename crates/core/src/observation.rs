use crate::model::{
    FundGroup, FundObservation, MacdRating, MacdScorePart, Nav, ObservationMetric,
    ObservationPoint, RedValuation, ValuationAnchor,
};
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;

pub struct ObservationInput<'a> {
    pub groups: &'a [FundGroup],
    pub history: &'a [Nav],
    pub accumulated: &'a [ObservationPoint],
    pub benchmark: Option<&'a [Nav]>,
    pub fund_size: Option<Decimal>,
    pub purchase_fee: Option<Decimal>,
}

/// Build the observation tab locally from the fund's published NAV history.
/// Imported observations remain useful as an offline fallback, but are not
/// required for newly added funds.
pub fn build(input: &ObservationInput<'_>) -> Option<FundObservation> {
    let mut series = if input.accumulated.is_empty() {
        input
            .history
            .iter()
            .map(|nav| ObservationPoint {
                day: nav.day.clone(),
                value: nav.cumulative_value.unwrap_or(nav.value),
            })
            .collect::<Vec<_>>()
    } else {
        input.accumulated.to_vec()
    };
    series.retain(|point| point.value > Decimal::ZERO);
    series.sort_by(|left, right| left.day.cmp(&right.day));
    series.dedup_by(|right, left| left.day == right.day);
    if series.len() > 600 {
        series = series.split_off(series.len() - 600);
    }
    let updated_day = series
        .last()
        .map(|point| point.day.clone())
        .or_else(|| input.history.last().map(|nav| nav.day.clone()))?;

    let mut metrics = Vec::new();
    let macd = if input.groups.contains(&FundGroup::Macd) {
        let rating = macd_observation(&series, input.fund_size, input.purchase_fee, &mut metrics);
        Some(rating)
    } else {
        None
    };
    let valuation = if input.groups.contains(&FundGroup::Red) {
        red_observation(&series, input.benchmark, &mut metrics)
    } else {
        None
    };

    Some(FundObservation {
        updated_day,
        source: "自动计算 · 历史净值".to_string(),
        metrics: dedupe_metrics(metrics),
        series: Some(series),
        macd,
        valuation,
    })
}

#[derive(Clone, Debug, PartialEq)]
pub struct MacdPoint {
    pub day: String,
    pub nav: f64,
    pub dif: f64,
    pub dea: f64,
    pub histogram: f64,
    pub crossing: i32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MacdAnalysis {
    pub points: Vec<MacdPoint>,
    pub current_signal: String,
    pub is_bullish: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct BandPoint {
    pub day: String,
    pub nav: f64,
    pub percentile: f64,
    pub moving_average: Option<f64>,
    pub bollinger_upper: Option<f64>,
    pub bollinger_lower: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct BandHistory {
    pub points: Vec<BandPoint>,
    pub box_high: f64,
    pub box_low: f64,
}

pub fn macd(series: &[ObservationPoint]) -> Option<MacdAnalysis> {
    let mut sorted = series.to_vec();
    sorted.sort_by(|left, right| left.day.cmp(&right.day));
    if sorted.len() < 35 {
        return None;
    }
    let values = sorted
        .iter()
        .map(|point| point.value.to_f64().unwrap_or_default())
        .collect::<Vec<_>>();
    let indicators = macd_indicators(&values);
    let mut points = Vec::with_capacity(values.len());
    let mut direction = 0;
    for (index, &(_, _, histogram)) in indicators.iter().enumerate() {
        let next_direction = if histogram > 0.0 {
            1
        } else if histogram < 0.0 {
            -1
        } else {
            direction
        };
        let crossing = if next_direction != direction {
            next_direction
        } else {
            0
        };
        direction = next_direction;
        points.push(MacdPoint {
            day: sorted[index].day.clone(),
            nav: values[index],
            dif: indicators[index].0,
            dea: indicators[index].1,
            histogram: indicators[index].2,
            crossing,
        });
    }
    let latest = points.last()?;
    let is_bullish = direction > 0;
    let current_signal = match latest.crossing {
        1 => "今日金叉 · 买入".to_string(),
        -1 => "今日死叉 · 卖出".to_string(),
        _ if direction == 0 => "零轴 · 无信号".to_string(),
        _ => {
            let run = points.len() - points.iter().rposition(|point| point.crossing != 0)?;
            if is_bullish {
                format!("红柱第 {run} 日 · 持有")
            } else {
                format!("绿柱第 {run} 日 · 空仓")
            }
        }
    };
    Some(MacdAnalysis {
        points,
        current_signal,
        is_bullish,
    })
}

pub fn bands(series: &[ObservationPoint], display_limit: usize) -> Option<BandHistory> {
    let mut sorted = series.to_vec();
    sorted.sort_by(|left, right| left.day.cmp(&right.day));
    if sorted.len() < 60 {
        return None;
    }
    let values = sorted
        .iter()
        .map(|point| point.value.to_f64().unwrap_or_default())
        .collect::<Vec<_>>();
    let mut points = Vec::with_capacity(values.len());
    for index in 0..values.len() {
        let percentile = if index >= 249 {
            let window = &values[index - 249..=index];
            let low = window.iter().copied().fold(f64::INFINITY, f64::min);
            let high = window.iter().copied().fold(f64::NEG_INFINITY, f64::max);
            if high > low {
                (((values[index] - low) / (high - low)) * 100.0).clamp(0.0, 100.0)
            } else {
                50.0
            }
        } else {
            50.0
        };
        let moving_average = (index >= 59).then(|| average(&values[index - 59..=index]));
        let bollinger = if index >= 19 {
            let window = &values[index - 19..=index];
            let mean = average(window);
            let variance = window
                .iter()
                .map(|value| (value - mean).powi(2))
                .sum::<f64>()
                / window.len() as f64;
            let deviation = variance.sqrt();
            Some((mean + deviation * 2.0, mean - deviation * 2.0))
        } else {
            None
        };
        points.push(BandPoint {
            day: sorted[index].day.clone(),
            nav: values[index],
            percentile,
            moving_average,
            bollinger_upper: bollinger.map(|pair| pair.0),
            bollinger_lower: bollinger.map(|pair| pair.1),
        });
    }
    let keep = display_limit.max(60);
    let visible = points[points.len().saturating_sub(keep)..].to_vec();
    let box_window = &values[values.len().saturating_sub(250)..];
    let box_high = box_window.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let box_low = box_window.iter().copied().fold(f64::INFINITY, f64::min);
    Some(BandHistory {
        points: visible,
        box_high,
        box_low,
    })
}

pub fn macd_indicators(values: &[f64]) -> Vec<(f64, f64, f64)> {
    let fast = ema(values, 12);
    let slow = ema(values, 26);
    let dif = fast
        .iter()
        .zip(&slow)
        .map(|(fast, slow)| fast - slow)
        .collect::<Vec<_>>();
    let dea = ema(&dif, 9);
    dif.iter()
        .zip(&dea)
        .map(|(dif, dea)| (*dif, *dea, 2.0 * (dif - dea)))
        .collect()
}

fn ema(values: &[f64], period: usize) -> Vec<f64> {
    let multiplier = 2.0 / (period as f64 + 1.0);
    let mut result: Vec<f64> = Vec::with_capacity(values.len());
    for value in values {
        let next = match result.last() {
            Some(prior) => value * multiplier + prior * (1.0 - multiplier),
            None => *value,
        };
        result.push(next);
    }
    result
}

fn average(values: &[f64]) -> f64 {
    values.iter().sum::<f64>() / values.len().max(1) as f64
}

fn decimal_of(value: f64) -> Option<Decimal> {
    if value.is_finite() {
        Decimal::from_f64_retain(value)
    } else {
        None
    }
}

fn metric(
    metrics: &mut Vec<ObservationMetric>,
    key: &str,
    label: &str,
    value: String,
    note: Option<&str>,
) {
    if value.trim().is_empty() {
        return;
    }
    metrics.push(ObservationMetric {
        key: key.to_string(),
        label: label.to_string(),
        value,
        note: note.map(str::to_string),
    });
}

fn dedupe_metrics(metrics: Vec<ObservationMetric>) -> Vec<ObservationMetric> {
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::new();
    for metric in metrics.into_iter().rev() {
        if seen.insert(metric.key.clone()) {
            result.push(metric);
        }
    }
    result.reverse();
    result
}

fn values_of(series: &[ObservationPoint]) -> Vec<f64> {
    series
        .iter()
        .filter_map(|point| point.value.to_f64())
        .filter(|value| value.is_finite() && *value > 0.0)
        .collect()
}

fn last_return(values: &[f64], window: usize) -> Option<f64> {
    if values.len() < 2 {
        return None;
    }
    let window = window.max(2).min(values.len());
    let start = values[values.len() - window];
    let end = *values.last()?;
    (start > 0.0).then_some(end / start - 1.0)
}

fn daily_returns(values: &[f64], window: usize) -> Vec<f64> {
    if values.len() < 2 {
        return Vec::new();
    }
    let start = values.len().saturating_sub(window.max(2)).saturating_sub(1);
    let mut returns = Vec::new();
    for pair in values[start..].windows(2) {
        if pair[0] > 0.0 {
            returns.push(pair[1] / pair[0] - 1.0);
        }
    }
    returns
}

fn annualized_volatility(values: &[f64], window: usize) -> Option<f64> {
    let returns = daily_returns(values, window);
    if returns.len() < 20 {
        return None;
    }
    let mean = average(&returns);
    let variance = returns
        .iter()
        .map(|value| (value - mean).powi(2))
        .sum::<f64>()
        / returns.len() as f64;
    Some(variance.sqrt() * 252_f64.sqrt())
}

fn max_drawdown(values: &[f64]) -> f64 {
    let mut peak = f64::NEG_INFINITY;
    let mut worst = 0.0_f64;
    for value in values {
        peak = peak.max(*value);
        if peak > 0.0 {
            worst = worst.min(value / peak - 1.0);
        }
    }
    worst
}

fn trend_fit(values: &[f64]) -> Option<f64> {
    if values.len() < 20 {
        return None;
    }
    let ys = values.iter().map(|value| value.ln()).collect::<Vec<_>>();
    let n = ys.len() as f64;
    let mean_x = (n - 1.0) / 2.0;
    let mean_y = average(&ys);
    let mut covariance = 0.0;
    let mut variance = 0.0;
    let mut total = 0.0;
    for (index, value) in ys.iter().enumerate() {
        let x = index as f64;
        covariance += (x - mean_x) * (value - mean_y);
        variance += (x - mean_x).powi(2);
        total += (value - mean_y).powi(2);
    }
    if variance <= 0.0 || total <= 0.0 {
        return Some(0.0);
    }
    let slope = covariance / variance;
    let intercept = mean_y - slope * mean_x;
    let residual = ys
        .iter()
        .enumerate()
        .map(|(index, value)| (value - (slope * index as f64 + intercept)).powi(2))
        .sum::<f64>();
    Some((1.0 - residual / total).clamp(0.0, 1.0))
}

fn efficiency_ratio(values: &[f64], window: usize) -> Option<f64> {
    if values.len() < 2 {
        return None;
    }
    let start = values.len().saturating_sub(window.max(2));
    let window = &values[start..];
    let net = (window[window.len() - 1] - window[0]).abs();
    let path = window
        .windows(2)
        .map(|pair| (pair[1] - pair[0]).abs())
        .sum::<f64>();
    (path > 0.0).then_some((net / path).clamp(0.0, 1.0))
}

fn percentile(values: &[f64], value: f64) -> f64 {
    if values.is_empty() {
        return 50.0;
    }
    let below = values
        .iter()
        .filter(|candidate| **candidate <= value)
        .count();
    below as f64 / values.len() as f64 * 100.0
}

fn percentile_score(value: f64) -> (i32, &'static str) {
    if value <= 20.0 {
        (2, "低位区")
    } else if value <= 40.0 {
        (1, "偏低区")
    } else if value <= 60.0 {
        (0, "中性")
    } else if value <= 80.0 {
        (-1, "偏高区")
    } else {
        (-2, "高位区")
    }
}

fn drawdown_score(value: f64) -> (i32, &'static str) {
    if value <= -20.0 {
        (2, "深度回撤")
    } else if value <= -10.0 {
        (1, "明显回撤")
    } else if value <= -3.0 {
        (0, "正常波动")
    } else {
        (-1, "接近高点")
    }
}

fn relative_score(value: f64) -> (i32, &'static str) {
    if value <= -10.0 {
        (2, "明显弱于基准")
    } else if value <= -3.0 {
        (1, "弱于基准")
    } else if value < 3.0 {
        (0, "接近基准")
    } else if value < 10.0 {
        (-1, "强于基准")
    } else {
        (-2, "明显强于基准")
    }
}

fn zigzag(values: &[f64], threshold: f64) -> (usize, Option<f64>, Option<f64>) {
    if values.len() < 5 {
        return (0, None, None);
    }
    let mut pivots = vec![0_usize];
    let mut direction = 0_i32;
    let mut high = values[0];
    let mut high_index = 0_usize;
    let mut low = values[0];
    let mut low_index = 0_usize;
    for (index, value) in values.iter().enumerate().skip(1) {
        if direction >= 0 && *value > high {
            high = *value;
            high_index = index;
        }
        if direction <= 0 && *value < low {
            low = *value;
            low_index = index;
        }
        if direction == 0 {
            if *value >= low * (1.0 + threshold) {
                direction = 1;
                pivots.push(low_index);
                high = *value;
                high_index = index;
            } else if *value <= high * (1.0 - threshold) {
                direction = -1;
                pivots.push(high_index);
                low = *value;
                low_index = index;
            }
        } else if direction > 0 {
            if *value <= high * (1.0 - threshold) {
                direction = -1;
                pivots.push(high_index);
                low = *value;
                low_index = index;
            }
        } else if *value >= low * (1.0 + threshold) {
            direction = 1;
            pivots.push(low_index);
            high = *value;
            high_index = index;
        }
    }
    if direction > 0 {
        pivots.push(high_index);
    } else if direction < 0 {
        pivots.push(low_index);
    }
    pivots.sort_unstable();
    pivots.dedup();
    if pivots.len() < 2 {
        return (0, None, None);
    }
    let amplitudes = pivots
        .windows(2)
        .filter_map(|pair| {
            let from = values[pair[0]];
            let to = values[pair[1]];
            (from > 0.0).then_some((to / from - 1.0).abs())
        })
        .collect::<Vec<_>>();
    let mut durations = pivots
        .windows(2)
        .map(|pair| pair[1].saturating_sub(pair[0]) as f64)
        .collect::<Vec<_>>();
    durations.sort_by(|left, right| left.partial_cmp(right).unwrap());
    (
        pivots.len() - 1,
        Some(average(&durations)),
        Some(average(&amplitudes)),
    )
}

struct Backtest {
    strategy_return: f64,
    holding_return: f64,
    strategy_drawdown: f64,
    closed_trades: usize,
    wins: usize,
    profit_factor: f64,
}

fn backtest(points: &[MacdPoint]) -> Option<Backtest> {
    if points.len() < 2 {
        return None;
    }
    let mut equity = 1.0_f64;
    let mut peak = 1.0_f64;
    let mut drawdown = 0.0_f64;
    let mut entry_equity = None;
    let mut closed_trades = 0;
    let mut wins = 0;
    let mut gross_profit = 0.0;
    let mut gross_loss = 0.0;
    for (prior, current) in points.iter().zip(&points[1..]) {
        // The prior day's signal is known before today's order cutoff.
        // Trades execute at today's NAV, after marking any existing position to market.
        if entry_equity.is_some() {
            equity *= current.nav / prior.nav;
        }
        peak = peak.max(equity);
        drawdown = drawdown.min(equity / peak - 1.0);
        if prior.crossing == 1 {
            entry_equity.get_or_insert(equity);
        } else if let Some(entry) = entry_equity.take_if(|_| prior.crossing == -1) {
            let profit = equity / entry - 1.0;
            closed_trades += 1;
            if profit > 0.0 {
                wins += 1;
                gross_profit += profit;
            } else {
                gross_loss -= profit;
            }
        }
    }
    let profit_factor = if gross_loss <= 1e-9 {
        if gross_profit > 0.0 {
            5.0
        } else {
            0.0
        }
    } else {
        (gross_profit / gross_loss).clamp(0.0, 5.0)
    };
    let first = points.first()?.nav;
    let last = points.last()?.nav;
    let holding_return = (first > 0.0).then_some(last / first - 1.0)?;
    Some(Backtest {
        strategy_return: equity - 1.0,
        holding_return,
        strategy_drawdown: drawdown,
        closed_trades,
        wins,
        profit_factor,
    })
}

fn macd_observation(
    series: &[ObservationPoint],
    fund_size: Option<Decimal>,
    purchase_fee: Option<Decimal>,
    metrics: &mut Vec<ObservationMetric>,
) -> MacdRating {
    let values = values_of(series);
    let analysis = macd(series);
    if values.len() < 35 || analysis.is_none() {
        metric(
            metrics,
            "sample",
            "历史样本",
            format!("{} 个交易日", values.len()),
            Some("不足 35 个交易日，暂无法计算 MACD"),
        );
        return MacdRating {
            score: None,
            grade: "—".to_string(),
            recommendation: "样本不足".to_string(),
            fee8: None,
            score_parts: Vec::new(),
            reasons: vec!["历史净值不足 35 个交易日，观察数据会随净值披露自动补齐".to_string()],
        };
    }
    let analysis = analysis.unwrap();
    let last_250 = values.len().min(250);
    let one_year = last_return(&values, 250).unwrap_or_default();
    let volatility = annualized_volatility(&values, 250);
    let nav_drawdown = max_drawdown(&values);
    let backtest = backtest(&analysis.points);
    let (legs, duration, amplitude) = zigzag(&values, 0.05);
    let pattern = if one_year > 0.08 {
        "区间整体上移"
    } else if one_year < -0.08 {
        "区间整体下移"
    } else {
        "区间反复（箱体最纯）"
    };
    metric(metrics, "pattern", "适配形态", pattern.to_string(), None);
    metric(
        metrics,
        "ret1y",
        if last_250 >= 250 {
            "近一年"
        } else {
            "区间涨幅"
        },
        format!("{:.2}%", one_year * 100.0),
        None,
    );
    if let Some(volatility) = volatility {
        metric(
            metrics,
            "vol",
            "年化波动",
            format!("{:.2}%", volatility * 100.0),
            None,
        );
    }
    metric(
        metrics,
        "mdd",
        "净值最大回撤",
        format!("{:.2}%", nav_drawdown * 100.0),
        None,
    );
    metric(
        metrics,
        "pos",
        "当前历史位置",
        format!(
            "{:.1}%",
            percentile(&values, *values.last().unwrap_or(&0.0))
        ),
        None,
    );
    if let Some(r2) = trend_fit(&values[values.len().saturating_sub(250)..]) {
        metric(metrics, "r2", "趋势拟合 R²", format!("{r2:.3}"), None);
    }
    if let Some(er) = efficiency_ratio(&values, 250) {
        metric(metrics, "er1", "效率比 ER(1Y)", format!("{er:.3}"), None);
    }
    if legs > 0 {
        metric(metrics, "legs", "有效波段", format!("{legs} 段"), None);
        if let Some(duration) = duration {
            metric(
                metrics,
                "duration",
                "波段中位天数",
                format!("{duration:.0} 天"),
                None,
            );
        }
        if let Some(amplitude) = amplitude {
            metric(
                metrics,
                "amp_med",
                "波段平均振幅",
                format!("{:.2}%", amplitude * 100.0),
                None,
            );
        }
    }
    let (excess, drawdown_improvement, win_rate) = if let Some(backtest) = &backtest {
        let win_rate = if backtest.closed_trades > 0 {
            backtest.wins as f64 / backtest.closed_trades as f64
        } else {
            0.0
        };
        metric(
            metrics,
            "strat",
            "策略累计收益",
            format!("{:.2}%", backtest.strategy_return * 100.0),
            None,
        );
        metric(
            metrics,
            "hold",
            "买入持有收益",
            format!("{:.2}%", backtest.holding_return * 100.0),
            None,
        );
        metric(
            metrics,
            "trades",
            "已平仓交易",
            format!("{} 次", backtest.closed_trades),
            None,
        );
        metric(
            metrics,
            "win",
            "盈利交易占比",
            format!("{:.2}%", win_rate * 100.0),
            None,
        );
        metric(
            metrics,
            "profit_factor",
            "盈亏比",
            format!("{:.2}", backtest.profit_factor),
            None,
        );
        metric(
            metrics,
            "backtest_mdd",
            "策略最大回撤",
            format!("{:.2}%", backtest.strategy_drawdown * 100.0),
            None,
        );
        (
            backtest.strategy_return - backtest.holding_return,
            backtest.strategy_drawdown - nav_drawdown,
            win_rate,
        )
    } else {
        (0.0, 0.0, 0.0)
    };
    if let Some(size) = fund_size.and_then(|value| value.to_f64()) {
        metric(
            metrics,
            "scale",
            "基金规模",
            format!("{:.2} 亿元", size / 100_000_000.0),
            None,
        );
    }
    if let Some(fee) = purchase_fee {
        metric(metrics, "fee", "申购费率", format!("{fee:.2}%"), None);
    }

    let space = (volatility.unwrap_or(0.0) / 0.35).clamp(0.0, 1.0);
    let excess_score = ((excess + 0.25) / 0.5).clamp(0.0, 1.0);
    let drawdown_score = ((drawdown_improvement + 0.10) / 0.30).clamp(0.0, 1.0);
    let consistency = win_rate.clamp(0.0, 1.0);
    let fee_score = purchase_fee
        .and_then(|fee| fee.to_f64())
        .map(|fee| 1.0 - (fee / 1.0).clamp(0.0, 1.0))
        .unwrap_or(0.75);
    let contributions = [
        ("回测超额", excess_score, 35),
        ("回撤改善", drawdown_score, 25),
        ("已平仓胜率", consistency, 20),
        ("波动空间", space, 15),
        ("申购费率", fee_score, 5),
    ];
    let score = (contributions
        .iter()
        .map(|(_, fraction, maximum)| fraction * f64::from(*maximum))
        .sum::<f64>()
        * 10.0)
        .round()
        / 10.0;
    let mut reasons = Vec::new();
    if values.len() < 250 {
        reasons.push("成立时间较短，样本不足 250 个交易日".to_string());
    }
    if fund_size
        .and_then(|value| value.to_f64())
        .is_some_and(|size| size < 200_000_000.0)
    {
        reasons.push("规模低于 2 亿元，流动性与清盘风险较高".to_string());
    }
    if excess.abs() >= 0.03 {
        reasons.push(format!(
            "回测{}买入持有 {:.2} 个百分点",
            if excess > 0.0 { "跑赢" } else { "落后" },
            excess.abs() * 100.0
        ));
    }
    if drawdown_improvement.abs() >= 0.03 {
        reasons.push(format!(
            "最大回撤较买入持有{} {:.2} 个百分点",
            if drawdown_improvement > 0.0 {
                "改善"
            } else {
                "扩大"
            },
            drawdown_improvement.abs() * 100.0
        ));
    }
    let insufficient = values.len() < 250
        || fund_size
            .and_then(|value| value.to_f64())
            .is_some_and(|size| size < 200_000_000.0);
    if insufficient {
        return MacdRating {
            score: None,
            grade: "—".to_string(),
            recommendation: "样本或规模不满足".to_string(),
            fee8: None,
            score_parts: Vec::new(),
            reasons,
        };
    }
    let (grade, recommendation) = if score >= 75.0 {
        ("S", "优先适配")
    } else if score >= 60.0 {
        ("A", "适配")
    } else if score >= 45.0 {
        ("B", "有条件适配")
    } else {
        ("C", "不推荐")
    };
    MacdRating {
        score: decimal_of(score).map(|value| value.round_dp(1)),
        grade: grade.to_string(),
        recommendation: recommendation.to_string(),
        fee8: None,
        reasons,
        score_parts: contributions
            .into_iter()
            .map(|(label, fraction, maximum)| MacdScorePart {
                label: label.to_string(),
                points: (fraction * f64::from(maximum) * 10.0).round() / 10.0,
                maximum,
            })
            .collect(),
    }
}

fn relative_40d(series: &[ObservationPoint], benchmark: &[Nav]) -> Option<f64> {
    let mut benchmark_by_day = std::collections::BTreeMap::new();
    for nav in benchmark {
        if let Some(value) = nav.value.to_f64().filter(|value| *value > 0.0) {
            benchmark_by_day.insert(nav.day.clone(), value);
        }
    }
    let pairs = series
        .iter()
        .filter_map(|point| {
            let fund = point.value.to_f64().filter(|value| *value > 0.0)?;
            let bench = *benchmark_by_day.get(&point.day)?;
            Some((fund, bench))
        })
        .collect::<Vec<_>>();
    let pairs = &pairs[pairs.len().saturating_sub(41)..];
    if pairs.len() < 2 {
        return None;
    }
    let (fund_first, bench_first) = pairs[0];
    let (fund_last, bench_last) = *pairs.last()?;
    let fund_return = fund_last / fund_first - 1.0;
    let bench_return = bench_last / bench_first - 1.0;
    Some((fund_return - bench_return) * 100.0)
}

fn red_observation(
    series: &[ObservationPoint],
    benchmark: Option<&[Nav]>,
    metrics: &mut Vec<ObservationMetric>,
) -> Option<RedValuation> {
    let values = values_of(series);
    if values.len() < 2 {
        return None;
    }
    let current = *values.last()?;
    let year = &values[values.len().saturating_sub(250)..];
    let high = year.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let low = year.iter().copied().fold(f64::INFINITY, f64::min);
    let one_year_percentile = if high > low {
        ((current - low) / (high - low) * 100.0).clamp(0.0, 100.0)
    } else {
        50.0
    };
    let one_year_return = (current / year[0] - 1.0) * 100.0;
    let from_high = (current / high - 1.0) * 100.0;
    let long = &values[values.len().saturating_sub(750)..];
    let long_percentile = percentile(long, current);
    let relative = benchmark.and_then(|rows| relative_40d(series, rows));

    let (year_score, year_label) = percentile_score(one_year_percentile);
    let (long_score, long_label) = percentile_score(long_percentile);
    let (drawdown_score, drawdown_label) = drawdown_score(from_high);
    let (relative_score, relative_label) = relative.map(relative_score).unwrap_or((0, "基准不足"));
    let anchors = vec![
        ValuationAnchor {
            key: "one_year".to_string(),
            name: "一年分位锚".to_string(),
            value: format!("{one_year_percentile:.1}%"),
            score: year_score,
            label: year_label.to_string(),
            rule: Some(
                "<20% 低位 / 20-40% 偏低 / 40-60% 中性 / 60-80% 偏高 / >80% 高位".to_string(),
            ),
        },
        ValuationAnchor {
            key: "drawdown".to_string(),
            name: "回撤锚".to_string(),
            value: format!("{from_high:.1}%"),
            score: drawdown_score,
            label: drawdown_label.to_string(),
            rule: Some("距一年高点 ≤-20% 加 2 分 / ≤-10% 加 1 分 / ≤-3% 中性".to_string()),
        },
        ValuationAnchor {
            key: "relative".to_string(),
            name: "相对强弱锚".to_string(),
            value: relative
                .map(|value| format!("{value:+.1}pp"))
                .unwrap_or_else(|| "—".to_string()),
            score: relative_score,
            label: relative_label.to_string(),
            rule: Some("近 40 个交易日相对沪深300；弱于基准加分，强于基准减分".to_string()),
        },
        ValuationAnchor {
            key: "long".to_string(),
            name: "长期分位锚".to_string(),
            value: format!("{long_percentile:.1}%"),
            score: long_score,
            label: long_label.to_string(),
            rule: Some("按可用历史区间计算分位（最多 600 个交易日）".to_string()),
        },
    ];
    let total = anchors.iter().map(|anchor| anchor.score).sum::<i32>();
    let (level, level_description, advice) = if total >= 5 {
        ("加仓区", "估值偏低", "多个估值锚处于低位，可分批关注。")
    } else if total >= 2 {
        (
            "定投区",
            "估值偏低",
            "估值偏低，适合分批定投，避免一次性重仓。",
        )
    } else if total >= -1 {
        ("持有区", "估值中性", "估值中性，以持有为主，暂不新增仓位。")
    } else if total >= -4 {
        ("观察区", "估值偏高", "估值偏高，保持观察，暂缓加仓。")
    } else {
        (
            "减仓区",
            "估值高位",
            "多个估值锚处于高位，注意回撤风险，可逐步止盈。",
        )
    };
    let (relative_text, relative_advice) = match relative {
        Some(value) if value > 10.0 => (
            "🔴 红灯 · 跑赢过多",
            "红利短期跑赢大盘过多 → 警惕阶段回踩，可逐步止盈。",
        ),
        Some(value) if value > 3.0 => (
            "🟡 黄灯 · 略强于大盘",
            "红利阶段性强于大盘，继续观察持续性。",
        ),
        Some(value) if value > -1.0 => ("持平", "与沪深300基本同步。"),
        Some(value) if value > -10.0 => (
            "🟢 绿灯 · 略弱于大盘",
            "红利阶段性弱于大盘，可等待估值修复。",
        ),
        Some(_) => (
            "🟢 深绿 · 明显弱于大盘",
            "红利明显弱于大盘，关注低位配置机会。",
        ),
        None => ("基准数据不足", "等待沪深300历史数据后自动更新。"),
    };

    metric(metrics, "level", "估值结论", level.to_string(), None);
    metric(
        metrics,
        "advice",
        "操作提示",
        advice.to_string(),
        Some("自动估值模型"),
    );
    metric(
        metrics,
        "stats_1y",
        "近一年涨幅",
        format!("{one_year_return:.2}%"),
        None,
    );
    metric(
        metrics,
        "from_high",
        "距一年高点",
        format!("{from_high:.2}%"),
        None,
    );
    metric(
        metrics,
        "long_pct",
        "长期分位",
        format!("{long_percentile:.1}%"),
        None,
    );
    if let Some(value) = relative {
        metric(
            metrics,
            "relative",
            "相对强弱",
            relative_text.to_string(),
            Some("与沪深300比较"),
        );
        metric(
            metrics,
            "relative_diff",
            "超额收益",
            format!("{value:.2} 个百分点"),
            None,
        );
    }
    Some(RedValuation {
        total,
        maximum: 8,
        level: level.to_string(),
        level_description: Some(level_description.to_string()),
        advice: advice.to_string(),
        anchors,
        one_year_percentile: decimal_of(one_year_percentile).map(|value| value.round_dp(1)),
        one_year_high: decimal_of(high).map(|value| value.round_dp(4)),
        one_year_low: decimal_of(low).map(|value| value.round_dp(4)),
        one_year_return: decimal_of(one_year_return).map(|value| value.round_dp(2)),
        from_high: decimal_of(from_high).map(|value| value.round_dp(2)),
        relative_difference: relative.and_then(decimal_of).map(|value| value.round_dp(2)),
        relative_label: Some(relative_text.to_string()),
        relative_advice: Some(relative_advice.to_string()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, NaiveDate};

    fn history(days: usize) -> Vec<Nav> {
        let start = NaiveDate::from_ymd_opt(2025, 1, 1).unwrap();
        (0..days)
            .map(|index| {
                let wave = (index as f64 * 0.12).sin() * 0.08;
                let drift = index as f64 * 0.0008;
                Nav {
                    day: (start + Duration::days(index as i64))
                        .format("%Y-%m-%d")
                        .to_string(),
                    value: decimal_of(1.0 + drift + wave).unwrap(),
                    rate: None,
                    annualized_rate: None,
                    cumulative_value: None,
                    source: "测试".to_string(),
                }
            })
            .collect()
    }

    #[test]
    fn backtest_executes_at_next_nav_and_excludes_open_trade_from_win_rate() {
        let points = [
            (100.0, 0),
            (101.0, 1),
            (150.0, 0),
            (170.0, -1),
            (165.0, 0),
            (105.0, 1),
            (75.0, 0),
            (80.0, 0),
        ]
        .into_iter()
        .map(|(nav, crossing)| MacdPoint {
            day: String::new(),
            nav,
            dif: 0.0,
            dea: 0.0,
            histogram: 0.0,
            crossing,
        })
        .collect::<Vec<_>>();

        let result = backtest(&points).unwrap();
        assert_eq!(result.closed_trades, 1);
        assert_eq!(result.wins, 1);
        assert!((result.strategy_return - (165.0 / 150.0 * 80.0 / 75.0 - 1.0)).abs() < 1e-10);
        assert!((result.strategy_drawdown - (165.0 / 170.0 - 1.0)).abs() < 1e-10);
    }

    #[test]
    fn builds_macd_observation_without_imported_data() {
        let history = history(320);
        let observation = build(&ObservationInput {
            groups: &[FundGroup::Macd],
            history: &history,
            accumulated: &[],
            benchmark: None,
            fund_size: Some(Decimal::from(5_000_000_000_i64)),
            purchase_fee: Some(Decimal::new(10, 2)),
        })
        .unwrap();
        assert_eq!(observation.source, "自动计算 · 历史净值");
        assert_eq!(observation.series.as_ref().unwrap().len(), 320);
        let rating = observation.macd.unwrap();
        assert!(rating.score.is_some());
        assert!(!rating.reasons.is_empty());
        assert!(observation
            .metrics
            .iter()
            .any(|metric| metric.key == "strat"));
        assert!(observation.valuation.is_none());
    }

    #[test]
    fn builds_four_anchor_red_valuation() {
        let history = history(320);
        let observation = build(&ObservationInput {
            groups: &[FundGroup::Red],
            history: &history,
            accumulated: &[],
            benchmark: None,
            fund_size: None,
            purchase_fee: None,
        })
        .unwrap();
        let valuation = observation.valuation.unwrap();
        assert_eq!(valuation.maximum, 8);
        assert_eq!(valuation.anchors.len(), 4);
        assert!(valuation.one_year_percentile.is_some());
        assert!(valuation.one_year_high.is_some());
        assert!(observation.macd.is_none());
    }

    #[test]
    fn keeps_partial_series_for_new_funds() {
        let history = history(10);
        let observation = build(&ObservationInput {
            groups: &[FundGroup::Macd],
            history: &history,
            accumulated: &[],
            benchmark: None,
            fund_size: None,
            purchase_fee: None,
        })
        .unwrap();
        assert_eq!(observation.series.as_ref().unwrap().len(), 10);
        let rating = observation.macd.unwrap();
        assert_eq!(rating.grade, "—");
        assert!(rating.score.is_none());
    }
}
