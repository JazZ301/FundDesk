import { ReactNode, useEffect, useMemo, useRef, useState } from "react";
import {
  api,
  formatChinaDateTime,
  formatMoney,
  formatSigned,
  indexTitle,
  IndexTrend,
  MarketCenter as MarketCenterData,
  swiftDate
} from "./api";
import { IndexSessionChart, TrendChart } from "./chart";

type Category = "overview" | "industry" | "style" | "concept" | "region";
type Period = "today" | "five" | "ten";
type FlowKind = "main" | "huge" | "large" | "medium" | "small";

const CATEGORIES: { id: Category; label: string; api: string }[] = [
  { id: "overview", label: "大盘资金", api: "overview" },
  { id: "industry", label: "行业板块", api: "industry" },
  { id: "style", label: "风格板块", api: "style" },
  { id: "concept", label: "概念板块", api: "concept" },
  { id: "region", label: "地域板块", api: "region" }
];

const PERIODS: { id: Period; label: string }[] = [
  { id: "today", label: "今日" },
  { id: "five", label: "近 5 日" },
  { id: "ten", label: "近 10 日" }
];

const FLOWS: { id: FlowKind; label: string }[] = [
  { id: "main", label: "主力" },
  { id: "huge", label: "超大单" },
  { id: "large", label: "大单" },
  { id: "medium", label: "中单" },
  { id: "small", label: "小单" }
];

function IndexDetail({ code, refreshTick }: { code: string; refreshTick: number }) {
  const [trend, setTrend] = useState<IndexTrend | null>(null);
  const [checkedAt, setCheckedAt] = useState("");
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let current = true;
    setLoading(true);
    api.indexTrend(code).then((value) => {
      if (!current) return;
      setTrend(value);
      setCheckedAt(new Intl.DateTimeFormat("sv-SE", {
        timeZone: value.session.time_zone, dateStyle: "short", timeStyle: "short"
      }).format(new Date()));
      setError("");
    }).catch((reason) => {
      if (current) setError(String(reason));
    }).finally(() => {
      if (current) setLoading(false);
    });
    return () => { current = false; };
  }, [code, refreshTick, attempt]);

  const latest = trend?.points.at(-1);
  const session = trend?.session;
  return (
    <section className="panel market-panel">
      <div className="section-head">
        <div>
          <h3>{indexTitle(code)}分时</h3>
          {latest && session && <p className="hint">
            {new Intl.DateTimeFormat("sv-SE", { timeZone: session.time_zone, dateStyle: "short", timeStyle: "short" }).format(swiftDate(latest.time))}
            {" · "}{session.time_zone_label} · {trend.source} · 指数点位
          </p>}
        </div>
        <div className="section-actions">
          {checkedAt && <span className="hint">获取于 {checkedAt}</span>}
          <button className="ghost" onClick={() => setAttempt((value) => value + 1)} disabled={loading}>
            {loading ? "获取中…" : "刷新"}
          </button>
        </div>
      </div>
      {error && <p className="error">{error}</p>}
      {trend ? <IndexSessionChart trend={trend} />
        : loading && <div className="empty">正在获取分时…</div>}
    </section>
  );
}

export default function MarketCenter({
  indexStrip, selectedIndex, onSelect, onBack, onRefreshIndices, indicesRefreshing
}: {
  indexStrip: ReactNode;
  onBack: () => void;
  onRefreshIndices: () => Promise<void>;
  indicesRefreshing: boolean;
  selectedIndex: string | null;
  onSelect: (code: string | null) => void;
}) {
  const [category, setCategory] = useState<Category>("overview");
  const [period, setPeriod] = useState<Period>("today");
  const [flow, setFlow] = useState<FlowKind>("main");
  const [order, setOrder] = useState<"inflow" | "outflow">("inflow");
  const focusIndex = selectedIndex;
  const shownQuery = useRef("");
  const [data, setData] = useState<MarketCenterData | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [refreshTick, setRefreshTick] = useState(0);
  const [checkedAt, setCheckedAt] = useState("");

  useEffect(() => {
    const item = CATEGORIES.find((entry) => entry.id === category);
    if (!item || focusIndex) {
      setLoading(false);
      return;
    }
    let cancelled = false;
    const query = `${category}:${period}`;
    if (shownQuery.current !== query) {
      setData(null);
      setError("");
    }
    setLoading(true);
    api
      .marketCenter(item.api, period)
      .then((value) => {
        if (!cancelled) {
          shownQuery.current = query;
          setData(value);
          setCheckedAt(formatChinaDateTime(Date.now() / 1000 - 978_307_200));
          setError("");
        }
      })
      .catch((reason) => {
        if (!cancelled) setError(String(reason));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [category, period, refreshTick, focusIndex]);

  const latestFlow = data?.flows?.points.at(-1);
  const backupFlow = data?.flows?.source?.includes("备用") ?? false;
  useEffect(() => {
    if (backupFlow && flow !== "main") setFlow("main");
  }, [backupFlow, flow]);
  const orderedSectors = useMemo(() => {
    const rows = data?.sectors ?? [];
    return order === "inflow" ? rows : [...rows].reverse();
  }, [data, order]);
  const maxSector = useMemo(
    () => Math.max(...(data?.sectors ?? []).map((row) => Math.abs(row.amount)), 1),
    [data]
  );
  const flowLabels = (data?.flows?.points ?? []).map((point) =>
    data?.flows?.intraday
      ? swiftDate(point.time).toLocaleTimeString("zh-CN", {
          timeZone: "Asia/Shanghai",
          hour: "2-digit",
          minute: "2-digit",
          hour12: false
        })
      : swiftDate(point.time).toLocaleDateString("zh-CN", {
          timeZone: "Asia/Shanghai",
          month: "2-digit",
          day: "2-digit"
        })
  );
  const flowValues = (data?.flows?.points ?? []).map((point) => point[flow] / 100_000_000);
  const breadth = data?.breadth;
  const currentLabel = CATEGORIES.find((item) => item.id === category)?.label ?? "行情中心";
  const visibleErrors = (data?.errors ?? []).filter((message) => {
    if (focusIndex) return false;
    if (category === "overview") return !message.startsWith("板块");
    return !message.startsWith("资金流") && !message.startsWith("两市统计");
  });

  return (
    <div className="market-center">
      <header className="topbar">
        <h1>行情中心</h1>
        <div className="section-actions">
          <button className="ghost" onClick={() => {
            setRefreshTick((value) => value + 1);
            void onRefreshIndices();
          }} disabled={loading || indicesRefreshing}>
            {loading || indicesRefreshing ? "刷新中…" : "刷新本页"}
          </button>
          <button className="ghost" onClick={onBack}>返回基金列表</button>
        </div>
      </header>
      {indexStrip}
      <div className="tabs page-tabs" aria-label="行情分类">
        {CATEGORIES.map((item) => (
          <button key={item.id} className={category === item.id ? "active" : ""}
            aria-pressed={category === item.id} onClick={() => {
              setCategory(item.id);
              onSelect(null);
            }}>{item.label}</button>
        ))}
      </div>

      {error && <div className="banner error">{error}</div>}
      {!focusIndex &&
        visibleErrors.map((message) => (
          <div className="banner soft-warning" key={message} title={message}>
            {message
              .replace(/error sending request for url \([^)]*\)/g, "网络暂不可用")
              .replace(/https?:\/\/\S+/g, "数据源暂不可用")}
          </div>
        ))}

      {focusIndex ? (
        <>
          <button className="ghost market-back" onClick={() => onSelect(null)}>‹ 返回行情分类</button>
          <IndexDetail key={focusIndex} code={focusIndex} refreshTick={refreshTick} />
        </>
      ) : (
        <>
          {category === "overview" ? (
            <>
              <section className="panel market-panel">
                <div className="section-head">
                  <h3>沪深两市</h3>
                  <div className="section-actions">
                    {checkedAt && <span className="hint">获取于 {checkedAt}</span>}
                    <button className="ghost small" disabled={loading} onClick={() => setRefreshTick((value) => value + 1)}>
                      {loading ? "刷新中…" : "⟳ 刷新"}
                    </button>
                  </div>
                </div>
                <div className="market-stats">
                  <div className="market-stat">
                    <span>成交额</span>
                    <strong>{breadth ? `${formatMoney(breadth.turnover / 100_000_000)} 亿元` : "—"}</strong>
                  </div>
                  <div className="market-stat">
                    <span>上涨</span>
                    <strong className="up">{breadth?.advancing?.toLocaleString("zh-CN") ?? "—"}</strong>
                  </div>
                  <div className="market-stat">
                    <span>平盘</span>
                    <strong>{breadth?.flat?.toLocaleString("zh-CN") ?? "—"}</strong>
                  </div>
                  <div className="market-stat">
                    <span>下跌</span>
                    <strong className="down">{breadth?.declining?.toLocaleString("zh-CN") ?? "—"}</strong>
                  </div>
                </div>
                {breadth && (
                  <div className="market-meta-row">
                    <span>
                      成交额 · {breadth.asOf ? formatChinaDateTime(breadth.asOf) : "行情时间未提供"} · {breadth.source}
                    </span>
                    <span>
                      涨跌家数 · {breadth.asOf ? formatChinaDateTime(breadth.asOf) : "行情时间未提供"}
                    </span>
                  </div>
                )}
                {breadth?.advancing == null && !loading && (
                  <p className="note">涨跌家数暂缺；成交额由可用来源补充。</p>
                )}
              </section>

              <section className="panel market-panel">
                <div className="section-head">
                  <h3>两市资金流向</h3>
                  <div className="section-actions">
                    {checkedAt && <span className="hint">获取于 {checkedAt}</span>}
                    <button className="ghost small" disabled={loading} onClick={() => setRefreshTick((value) => value + 1)}>
                      {loading ? "刷新中…" : "⟳ 刷新"}
                    </button>
                  </div>
                </div>
                <div className="flow-switch">
                  {FLOWS.map((item) => {
                    const amount = latestFlow?.[item.id];
                    return (
                      <button
                        key={item.id}
                        className={flow === item.id ? "active" : ""}
                        onClick={() => setFlow(item.id)}
                        disabled={backupFlow && item.id !== "main"}
                        title={backupFlow && item.id !== "main" ? "备用源仅提供主力口径" : undefined}
                      >
                        <span>{item.label}</span>
                        <b className={(amount ?? 0) >= 0 ? "up" : "down"}>
                          {amount != null ? `${formatSigned(amount / 100_000_000)} 亿` : "—"}
                        </b>
                      </button>
                    );
                  })}
                </div>
                {latestFlow && (
                  <p className="hint market-flow-caption">
                    行情 {formatChinaDateTime(latestFlow.time)} · {data?.flows?.intraday ? "分时" : "日线"} ·{" "}
                    {data?.flows?.source ?? "东方财富"} · {FLOWS.find((item) => item.id === flow)?.label}净流入
                  </p>
                )}
                <TrendChart
                  labels={flowLabels}
                  values={flowValues}
                  height={260}
                  digits={2}
                  area={false}
                  emptyText={loading ? "正在获取资金流…" : "暂无资金流数据"}
                />
                {backupFlow && <p className="hint">新浪行业汇总备用口径</p>}
              </section>
            </>
          ) : (
            <div className="sector-page">
              <div className="sector-controls">
                <div className="segmented small">
                  {PERIODS.map((item) => (
                    <button
                      key={item.id}
                      className={period === item.id ? "active" : ""}
                      onClick={() => setPeriod(item.id)}
                    >
                      {item.label}
                    </button>
                  ))}
                </div>
                <select
                  className="select"
                  value={order}
                  onChange={(event) => setOrder(event.target.value as "inflow" | "outflow")}
                >
                  <option value="inflow">净流入优先</option>
                  <option value="outflow">净流出优先</option>
                </select>
              </div>
              <section className="panel market-panel">
                <div className="section-head">
                  <div>
                    <h3>{currentLabel}资金排行</h3>
                    <p className="hint">
                      {data?.sectors?.length ?? 0} 个板块 · 东方财富 · 主力净流入（亿元） · 行情时间由数据源提供
                    </p>
                  </div>
                  <div className="section-actions">
                    {checkedAt && <span className="hint">获取于 {checkedAt}</span>}
                    <button className="ghost small" disabled={loading} onClick={() => setRefreshTick((value) => value + 1)}>
                      {loading ? "刷新中…" : "⟳ 刷新"}
                    </button>
                  </div>
                </div>
                <div className="sector-list">
                  {orderedSectors.map((row, index) => (
                    <div className="sector-row" key={row.code}>
                      <span className="sector-rank">{index + 1}</span>
                      <span className="sector-name">{row.name}</span>
                      <span className="sector-track">
                        <i
                          className={row.amount >= 0 ? "up-bg" : "down-bg"}
                          style={{ width: `${Math.min(100, (Math.abs(row.amount) / maxSector) * 100)}%` }}
                        />
                      </span>
                      <strong className={row.amount >= 0 ? "up" : "down"}>
                        {formatSigned(row.amount / 100_000_000)}
                      </strong>
                    </div>
                  ))}
                  {orderedSectors.length === 0 && (
                    <div className="empty">{loading ? "板块数据加载中…" : "暂无板块数据"}</div>
                  )}
                </div>
              </section>
            </div>
          )}
        </>
      )}
    </div>
  );
}
