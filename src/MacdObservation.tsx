import { useMemo, useState } from "react";
import type { FundObservation, ObservationPoint } from "./api";
import { ObservationChart } from "./chart";

const EMPTY_SERIES: ObservationPoint[] = [];
const RANGES = [[60, "近 60 日"], [120, "近 120 日"], [0, "全部"]] as const;

function macd(values: number[]): {
  dif: number[];
  dea: number[];
  histogram: number[];
  crossing: number[];
  signal: string;
  bullish: boolean;
} | null {
  if (values.length < 35) return null;
  const ema = (source: number[], period: number) => {
    const multiplier = 2 / (period + 1);
    const result: number[] = [];
    for (const value of source) {
      result.push(result.length ? value * multiplier + result[result.length - 1] * (1 - multiplier) : value);
    }
    return result;
  };
  const fast = ema(values, 12);
  const slow = ema(values, 26);
  const dif = fast.map((value, index) => value - slow[index]);
  const dea = ema(dif, 9);
  const histogram = dif.map((value, index) => (value - dea[index]) * 2);
  let direction = 0;
  const directions = histogram.map((value) => {
    direction = Math.sign(value) || direction;
    return direction;
  });
  const crossing = directions.map((value, index) => value === (directions[index - 1] ?? 0) ? 0 : value);
  const bullish = direction > 0;
  const lastCross = crossing.at(-1) ?? 0;
  if (direction === 0) return { dif, dea, histogram, crossing, signal: "零轴 · 无信号", bullish };
  if (lastCross > 0) return { dif, dea, histogram, crossing, signal: "最新净值金叉", bullish };
  if (lastCross < 0) return { dif, dea, histogram, crossing, signal: "最新净值死叉", bullish };
  let run = 1;
  for (let index = histogram.length - 2; index >= 0; index -= 1) {
    if (directions[index] !== direction) break;
    run += 1;
  }
  return {
    dif,
    dea,
    histogram,
    crossing,
    signal: bullish ? `红柱第 ${run} 日 · 多头` : `绿柱第 ${run} 日 · 空头`,
    bullish
  };
}

export function MacdObservation({ observation }: { observation: FundObservation }) {
  const [range, setRange] = useState<number>(60);
  const series = observation.series ?? EMPTY_SERIES;
  const analysis = useMemo(() => macd(series.map((point) => point.value)), [series]);
  const first = range === 0 ? 0 : Math.max(0, series.length - range);
  const visible = series.slice(first);
  const rating = observation.macd;
  const currentVersion = Boolean(rating?.scoreParts?.length);
  const metrics = new Map(observation.metrics.map((metric) => [metric.key, metric.value]));
  const latest = series.at(-1);
  const latestCross = analysis ? Math.max(analysis.crossing.lastIndexOf(1), analysis.crossing.lastIndexOf(-1)) : -1;
  const latestCrossDay = series[latestCross]?.day;

  return (
    <>
      <div className="observation-head">
        <div>
          <h3>MACD 战法适配</h3>
          <p>{observation.source} · 净值截至 {latest?.day ?? observation.updatedDay}</p>
        </div>
        {analysis && (
          <span className={`observation-signal ${analysis.bullish ? "up" : "down"}`}>
            {analysis.signal}
          </span>
        )}
      </div>
      {rating && (
        <section className="macd-rating-panel" aria-label="MACD 适配度与回测表现">
          <div className="observation-score">
            <div className={`score-box grade-${rating.grade}`}>
              <strong>{rating.score != null ? rating.score.toFixed(1) : "—"}</strong>
              <span>适配度 / 100</span>
            </div>
            <div className="score-copy">
              <div>
                <span className="grade-badge">{rating.grade}</span>
                <strong>{rating.recommendation}</strong>
              </div>
              <p>{currentVersion ? `近 ${series.length} 个交易日 · 金叉或死叉后下一交易日按净值成交` : "评分沿用此记录的原口径"}</p>
              {rating.fee8 != null && <p>持有满 8 个自然日赎回费 {rating.fee8.toFixed(2)}%</p>}
              {rating.reasons.length > 0 && <p>{rating.reasons.join("。")}</p>}
            </div>
          </div>
          {currentVersion && (
            <div className="macd-return-comparison" aria-label="回测对比">
              <span>区间收益 <b>{metrics.get("strat")}</b><small>持有 {metrics.get("hold")}</small></span>
              <span>最大回撤 <b>{metrics.get("backtest_mdd")}</b><small>持有 {metrics.get("mdd")}</small></span>
              <span>已平仓胜率 <b>{metrics.get("win")}</b><small>{metrics.get("trades")}</small></span>
            </div>
          )}
        </section>
      )}
      {analysis && latest && (
        <section className="observation-chart-card macd-observation-chart">
          <div className="observation-chart-head">
            <h3>净值与 MACD</h3>
            <div className="macd-chart-ranges" role="group" aria-label="图表显示区间">
              {RANGES.map(([days, label]) => (
                <button type="button" key={days} aria-pressed={range === days} onClick={() => setRange(days)}>{label}</button>
              ))}
            </div>
          </div>
          <div className="macd-chart-context">
            <span>{visible[0]?.day} 至 {latest.day}</span>
            {latestCrossDay && (
              <span>最近{analysis.crossing[latestCross] > 0 ? "金叉" : "死叉"} {latestCrossDay}</span>
            )}
          </div>
          <div className="macd-chart-key">
            <div className="observation-legend">
              <span><i className="legend-dot nav" />净值</span>
              <span><i className="macd-triangle buy" />金叉</span>
              <span><i className="macd-triangle sell" />死叉</span>
              <span><i className="legend-dot dif" />DIF</span>
              <span><i className="legend-dot dea" />DEA</span>
              <span><i className="macd-color-bars" />MACD 柱</span>
            </div>
            <span className="macd-indicator-values">
              DIF {analysis.dif.at(-1)?.toFixed(4)} · DEA {analysis.dea.at(-1)?.toFixed(4)} · 柱 {analysis.histogram.at(-1)?.toFixed(4)}
            </span>
          </div>
          <ObservationChart
            labels={visible.map((point) => point.day)}
            nav={visible.map((point) => point.value)}
            histogram={analysis.histogram.slice(first)}
            dif={analysis.dif.slice(first)}
            dea={analysis.dea.slice(first)}
            crossing={analysis.crossing.slice(first)}
            height={360}
          />
        </section>
      )}
      {!!rating?.scoreParts?.length && (
        <details className="macd-method">
          <summary>评分构成与回测口径</summary>
          <div className="macd-score-parts">
            {rating.scoreParts.map((part) => (
              <div key={part.label}>
                <span>{part.label}</span>
                <meter min={0} max={part.maximum} value={part.points} aria-label={part.label} />
                <b>{part.points.toFixed(1)} / {part.maximum}</b>
              </div>
            ))}
          </div>
          <p>MACD 参数为 12、26、9。策略和持有收益按净值变动估算，优先使用累计净值。收益未扣交易费用，胜率只统计已平仓交易。切换图表区间只影响显示。</p>
        </details>
      )}
    </>
  );
}
