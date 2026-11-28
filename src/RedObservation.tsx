import { formatPercent, formatSigned, RedValuation } from "./api";

type Tone = "high" | "warm" | "neutral" | "cool" | "low";
type Band = { end: number; tone: Tone; label?: string; range?: string };
type Tick = { value: number; label: string };

const SCORE_ZONES: { label: string; end?: number; tone: Tone }[] = [
  { label: "减仓区", end: -4.5, tone: "high" },
  { label: "观察区", end: -1.5, tone: "warm" },
  { label: "持有区", end: 1.5, tone: "neutral" },
  { label: "定投区", end: 4.5, tone: "cool" },
  { label: "加仓区", tone: "low" }
];

const RELATIVE_BANDS: Band[] = [
  { end: -10, tone: "low", label: "明显弱于大盘" },
  { end: -1, tone: "cool", label: "略弱于大盘" },
  { end: 3, tone: "neutral", label: "持平" },
  { end: 10, tone: "warm", label: "略强于大盘" },
  { end: 20, tone: "high", label: "跑赢过多" }
];

const RELATIVE_TICKS = [
  { value: -20, label: "跑输 ≤−20" },
  { value: -10, label: "−10" },
  { value: -1, label: "−1" },
  { value: 3, label: "+3" },
  { value: 10, label: "+10" },
  { value: 20, label: "≥+20 跑赢" }
];

const PERCENTILE_BANDS: Band[] = [
  { end: 20, tone: "low" },
  { end: 40, tone: "cool" },
  { end: 60, tone: "neutral" },
  { end: 80, tone: "warm" },
  { end: 100, tone: "high" }
];

const ANCHOR_SCORES = [-2, -1, 0, 1, 2];
const SCORE_TONES: Tone[] = ["high", "warm", "neutral", "cool", "low"];

function ObservationScale({
  min, bands, value, activeTone, activeLabel, ticks, zeroLine = false, description
}: {
  min: number;
  bands: Band[];
  value?: number;
  activeTone?: Tone;
  activeLabel?: string;
  ticks?: Tick[];
  zeroLine?: boolean;
  description: string;
}) {
  const max = bands[bands.length - 1].end;
  const position = (point: number) => (Math.min(max, Math.max(min, point)) - min) / (max - min) * 100;

  return (
    <div className="red-scale" role="img" aria-label={description}>
      {zeroLine && <div className="red-scale-zero-label" aria-hidden="true">0</div>}
      <div className="red-scale-track" aria-hidden="true">
        {bands.map((band, index) => (
          <span
            key={band.end}
            className={`red-scale-band tone-${band.tone}${index === bands.length - 1 ? " last" : ""}`}
            style={{ width: `${position(band.end) - position(bands[index - 1]?.end ?? min)}%` }}
          />
        ))}
        {zeroLine && <span className="red-scale-zero-line" />}
        {value != null && (
          <span
            className={"red-scale-marker tone-" + (activeTone ?? "neutral")}
            style={{ left: `${position(value)}%` }}
          />
        )}
      </div>
      {ticks && (
        <div className="red-scale-ticks" aria-hidden="true">
          {ticks.map((tick) => (
            <span key={tick.value} style={{ left: `${position(tick.value)}%` }}>{tick.label}</span>
          ))}
        </div>
      )}
      {bands[0].range && (
        <div className="red-scale-zones" aria-hidden="true">
          {bands.map((band, index) => (
            <div
              key={band.end}
              className={"tone-" + band.tone + (band.label === activeLabel ? " current" : "")}
              style={{ width: `${position(band.end) - position(bands[index - 1]?.end ?? min)}%` }}
            >
              <strong>{band.label}</strong>
              <span>{band.range}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export function RedObservation({
  valuation, source, updatedDay
}: {
  valuation: RedValuation;
  source: string;
  updatedDay: string;
}) {
  const bands: Band[] = SCORE_ZONES.map((zone, index) => {
    const firstScore = index === 0 ? -valuation.maximum : Math.ceil(SCORE_ZONES[index - 1].end ?? 0);
    const end = zone.end ?? valuation.maximum + 0.5;
    return {
      ...zone,
      end,
      range: `${formatSigned(firstScore, 0)} 至 ${formatSigned(Math.floor(end), 0)}`
    };
  });
  const scoreTone = bands.find((band) => band.label === valuation.level)?.tone ?? "neutral";
  const relative = valuation.relativeDifference;
  const relativeLabel = valuation.relativeLabel?.split(" · ").pop();
  const relativeTone = RELATIVE_BANDS.find((band) => band.label === relativeLabel)?.tone ?? "neutral";
  const relativeValue = relative == null ? "—" : `${formatSigned(relative)} pp`;
  const percentile = valuation.oneYearPercentile;
  const yearRange = valuation.oneYearLow != null && valuation.oneYearHigh != null
    ? `${valuation.oneYearLow.toFixed(4)} ～ ${valuation.oneYearHigh.toFixed(4)}`
    : "区间暂未提供";

  return (
    <>
      <div className="observation-head">
        <div>
          <h3>红利估值锚</h3>
          <p>{source} · 更新至 {updatedDay}</p>
        </div>
      </div>
      <div className="red-hero">
        <div className="red-hero-line">
          <b>综合得分 {formatSigned(valuation.total, 0)} <small>分</small></b>
          <strong className={`red-zone-badge tone-${scoreTone}`}>{valuation.level}</strong>
          <span className={valuation.oneYearReturn == null ? "muted" : valuation.oneYearReturn > 0 ? "up" : valuation.oneYearReturn < 0 ? "down" : "flat"}>
            近一年 {formatPercent(valuation.oneYearReturn)}
          </span>
        </div>
        <ObservationScale
          min={-valuation.maximum - 0.5}
          bands={bands}
          value={valuation.total}
          activeTone={scoreTone}
          activeLabel={valuation.level}
          description={`综合得分 ${formatSigned(valuation.total, 0)} 分，位于${valuation.level}。从左到右：${bands.map((band) => `${band.label} ${band.range} 分`).join("，")}。`}
        />
        <div className="red-hero-advice"><span>{valuation.advice}</span></div>
      </div>
      <div className="red-two-cards">
        <div className="red-mini-card">
          <span>近一年累计净值区间位置</span>
          <strong>{percentile == null ? "—" : `${percentile.toFixed(1)}%`}</strong>
          <ObservationScale
            min={0}
            bands={PERCENTILE_BANDS}
            value={percentile}
            activeTone={PERCENTILE_BANDS.find((band) => percentile != null && percentile <= band.end)?.tone}
            ticks={[
              { value: 0, label: "0% · 低点" },
              { value: 50, label: "50%" },
              { value: 100, label: "100% · 高点" }
            ]}
            description={percentile == null ? "区间位置暂无数据" : `当前净值位于近一年高低点区间的 ${percentile.toFixed(1)}%`}
          />
          <em>{yearRange}</em>
        </div>
        <div className="red-mini-card">
          <span>40 日相对强弱 · 对比沪深300</span>
          <div className="relative-line">
            <strong>{relativeValue}</strong>
            <b className={`tone-${relativeTone}`}>{relativeLabel ?? "基准数据不足"}</b>
          </div>
          <ObservationScale
            min={-20}
            bands={RELATIVE_BANDS}
            value={relative}
            activeTone={relativeTone}
            ticks={RELATIVE_TICKS}
            zeroLine
            description={relative == null ? "基准数据不足，无当前位置" : `相对沪深300 ${relative > 0 ? "跑赢" : relative < 0 ? "跑输" : "差值"} ${Math.abs(relative).toFixed(2)} 个百分点，${relativeLabel ?? ""}。左侧跑输，右侧跑赢，零为基准。`}
          />
          <em>{valuation.relativeAdvice ?? "等待沪深300历史数据后自动更新。"}</em>
        </div>
      </div>
      <div className="red-anchor-card">
        <h3>四锚评分</h3>
        <div className="red-anchor-grid">
          {valuation.anchors.map((anchor) => {
            const missing = anchor.key === "relative" && relative == null;
            return (
              <div className="red-anchor" key={anchor.key} title={anchor.rule}>
                <div>
                  <span>{anchor.name}</span>
                  <b className={`tone-${SCORE_TONES[anchor.score + 2] ?? "neutral"}`}>
                    {missing ? "—" : `${formatSigned(anchor.score, 0)} 分`}
                  </b>
                </div>
                <div>
                  <strong>{anchor.value}</strong>
                  <em>{anchor.label}</em>
                </div>
                <div className="red-anchor-scale" aria-hidden="true">
                  {ANCHOR_SCORES.map((score, index) => (
                    <span
                      key={score}
                      className={`tone-${SCORE_TONES[index]}${!missing && anchor.score === score ? " current" : ""}`}
                    >
                      {formatSigned(score, 0)}
                    </span>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </>
  );
}
