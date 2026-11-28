import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import {
  api,
  formatChinaDateTime,
  formatChinaTime,
  formatMoney,
  formatPercent,
  formatSigned,
  futuresKind,
  futuresTitle,
  FUTURES_ORDER,
  FuturesDetail as FuturesDetailData,
  FuturesIntraday,
  FuturesQuote,
  FuturesSuggestion,
  SWIFT_EPOCH,
  swiftDate
} from "./api";
import { CandleChart, CandlePoint, FuturesIntradayChart, MacdChart, TrendChart } from "./chart";

const intradayCache = new Map<string, { series: FuturesIntraday; fetchedAt: number }>();
const intradayRequests = new Map<string, Promise<FuturesIntraday>>();

function loadIntraday(symbol: string, refreshAt: number): Promise<FuturesIntraday> {
  const pending = intradayRequests.get(symbol);
  if (pending) return pending;
  const cached = intradayCache.get(symbol);
  if (cached && cached.fetchedAt >= refreshAt && Date.now() - cached.fetchedAt < 60_000) {
    return Promise.resolve(cached.series);
  }
  const request = api.futuresIntraday(symbol)
    .then((series) => {
      intradayCache.set(symbol, { series, fetchedAt: Date.now() });
      return series;
    })
    .finally(() => intradayRequests.delete(symbol));
  intradayRequests.set(symbol, request);
  return request;
}
function quoteChange(quote?: FuturesQuote): number | undefined {
  if (!quote?.reference) return undefined;
  return quote.price - quote.reference;
}

function quoteRate(quote?: FuturesQuote): number | undefined {
  if (!quote?.reference) return undefined;
  return ((quote.price - quote.reference) / Math.abs(quote.reference)) * 100;
}

function quoteAmplitude(quote?: FuturesQuote): number | undefined {
  if (!quote?.reference || quote.high == null || quote.low == null) return undefined;
  return ((quote.high - quote.low) / Math.abs(quote.reference)) * 100;
}

function Sparkline({ symbol, refreshAt }: { symbol: string; refreshAt: number }) {
  const [series, setSeries] = useState(() => intradayCache.get(symbol)?.series);
  const [failed, setFailed] = useState(false);
  const gradientId = useId();

  useEffect(() => {
    let active = true;
    setFailed(false);
    loadIntraday(symbol, refreshAt)
      .then((value) => { if (active) setSeries(value); })
      .catch(() => { if (active) setFailed(true); });
    return () => { active = false; };
  }, [symbol, refreshAt]);

  const plot = useMemo(() => {
    const points = series?.points ?? [];
    const first = points[0];
    const last = points.at(-1);
    if (!first || !last) return null;
    const reference = series?.reference;
    const baseline = reference != null && Number.isFinite(reference) && reference !== 0 ? reference : undefined;
    const values = points.map((point) => point.value);
    const low = Math.min(...values, baseline ?? Infinity);
    const high = Math.max(...values, baseline ?? -Infinity);
    const span = high - low;
    const padding = Math.max(span * 0.07, Math.abs(high) * 0.0001, 0.0001);
    const y = (value: number) => 43 - (value - low + padding) / (span + padding * 2) * 42;
    const duration = last.time - first.time;
    const path = points.map((point, index) => {
      const x = duration > 0 ? 1 + (point.time - first.time) / duration * 98 : 50;
      const coord = `${x.toFixed(3)},${y(point.value).toFixed(3)}`;
      // Leave long gaps in the feed visible, including scheduled breaks.
      return index === 0 || point.time - points[index - 1].time > 5 * 60
        ? `M${coord}L${coord}` : `L${coord}`;
    }).join(" ");
    return { first, last, path, baseline, baselineY: baseline === undefined ? undefined : y(baseline),
      endX: duration > 0 ? 99 : 50, endY: y(last.value) };
  }, [series]);

  if (!plot) {
    return <span className="sparkline-placeholder">{failed || series ? "分时暂不可用" : "获取分时…"}</span>;
  }
  const { first, last, path, baseline, baselineY, endX, endY } = plot;
  const firstTime = formatChinaTime(first.time);
  const lastTime = formatChinaTime(last.time);
  const lastDirection = baseline === undefined || last.value === baseline ? "" : last.value > baseline ? "up" : "down";
  const range = `${formatChinaDateTime(first.time)} 至 ${formatChinaDateTime(last.time)} 北京时间`;

  return (
    <span className="futures-sparkline" title={range}>
      <svg className="sparkline" viewBox="0 0 100 44" preserveAspectRatio="none" role="img" aria-label={`分时走势，${range}`}>
        {baselineY !== undefined && <>
          <defs>
            <linearGradient id={gradientId} gradientUnits="userSpaceOnUse" x1="0" x2="0" y1="0" y2="44">
              <stop offset={baselineY / 44} stopColor="var(--up)" />
              <stop offset={baselineY / 44} stopColor="var(--down)" />
            </linearGradient>
          </defs>
          <line className="sparkline-zero" x1="0" y1={baselineY} x2="100" y2={baselineY}
            strokeDasharray="3 3" vectorEffect="non-scaling-stroke" />
        </>}
        <path d={path} fill="none" stroke={baselineY === undefined || (first.value === baseline && series?.points.every(point => point.value === baseline))
          ? "currentColor" : `url(#${gradientId})`}
          strokeWidth="1.5" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
        <circle className={lastDirection} cx={endX} cy={endY} r="1.25" fill="currentColor" />
      </svg>
      <span className="sparkline-times"><span>{firstTime}</span>{last.time !== first.time && <span>{lastTime}</span>}</span>
    </span>
  );
}

function quoteClock(value: number): string {
  const seconds = String(swiftDate(value).getSeconds()).padStart(2, "0");
  const day = new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  }).format(new Date((value + SWIFT_EPOCH) * 1000));
  return `${day}:${seconds}`;
}

const DETAIL_TABS = [
  { id: "intraday", label: "分时" },
  { id: "five", label: "五日" },
  { id: "daily", label: "日K" },
  { id: "weekly", label: "周K" },
  { id: "monthly", label: "月K" }
] as const;

type DetailTab = (typeof DETAIL_TABS)[number]["id"];

function macd(values: number[]): { dif: number[]; dea: number[]; histogram: number[] } {
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
  return { dif, dea, histogram };
}

function FuturesMacd({ labels, values }: { labels: string[]; values: number[] }) {
  const indicators = macd(values);
  const index = indicators.dif.length - 1;
  return (
    <>
      <div className="chart-subhead macd-readout">
        <span>MACD（12, 26, 9）</span>
        <span>DIF <b>{indicators.dif[index]?.toFixed(3) ?? "—"}</b></span>
        <span>DEA <b>{indicators.dea[index]?.toFixed(3) ?? "—"}</b></span>
        <span>柱 <b className={(indicators.histogram[index] ?? 0) >= 0 ? "up" : "down"}>{indicators.histogram[index]?.toFixed(3) ?? "—"}</b></span>
      </div>
      <MacdChart labels={labels} {...indicators} height={170} />
    </>
  );
}

function CandlePanel({ data, tab }: { data: FuturesDetailData; tab: DetailTab }) {
  const bars = tab === "weekly" ? data.weekly : tab === "monthly" ? data.monthly : data.daily;
  const visible = bars.slice(-120);
  const candles: CandlePoint[] = visible.map((bar) => ({
    label: swiftDate(bar.day).toLocaleDateString("zh-CN", {
      timeZone: "Asia/Shanghai",
      year: "2-digit",
      month: "2-digit",
      day: "2-digit"
    }),
    open: bar.open,
    close: bar.close,
    low: bar.low,
    high: bar.high
  }));
  const indicators = useMemo(
    () => macd(visible.map((bar) => bar.close)),
    [visible]
  );
  const index = indicators.dif.length - 1;
  return (
    <>
      <CandleChart candles={candles} height={380} />
      <div className="chart-subhead macd-readout">
        <span>MACD（12, 26, 9）</span>
        <span>DIF <b>{indicators.dif[index]?.toFixed(3) ?? "—"}</b></span>
        <span>DEA <b>{indicators.dea[index]?.toFixed(3) ?? "—"}</b></span>
        <span>柱 <b className={(indicators.histogram[index] ?? 0) >= 0 ? "up" : "down"}>{indicators.histogram[index]?.toFixed(3) ?? "—"}</b></span>
        <span className="hint">最近 {visible.length} 根</span>
      </div>
      <MacdChart
        labels={candles.map((candle) => candle.label)}
        histogram={indicators.histogram}
        dif={indicators.dif}
        dea={indicators.dea}
        height={170}
      />
    </>
  );
}

function FivePanel({ data }: { data: FuturesDetailData }) {
  const five = data.five;
  const points = useMemo(() => {
    if (!five) return [];
    return five.sessions.flatMap((session) =>
      session.prices.map((value) => ({
        label: swiftDate(session.day).toLocaleDateString("zh-CN", {
          timeZone: "Asia/Shanghai",
          month: "2-digit",
          day: "2-digit"
        }),
        value
      }))
    );
  }, [five]);

  return (
    <>
      <p className="hint">
        {five?.isMinuteSeries ? "近五个交易日分钟走势" : "近五个交易日日线 · 分钟数据暂不可用"}
        {!five?.isMinuteSeries && five?.sessions.length ? " · 末点可能为盘中价" : ""}
      </p>
      <TrendChart
        baselineLabel="参考价"
        labels={points.map((point) => point.label)}
        values={points.map((point) => point.value)}
        baseline={five?.reference}
        height={400}
        emptyText={five ? "暂无五日数据" : "五日数据暂不可用"}
      />
      {points.length >= 35 && <FuturesMacd labels={points.map((point) => point.label)}
        values={points.map((point) => point.value)} />}
    </>
  );
}

function FuturesDetailPanel({
  symbol,
  initialQuote,
  onBack
}: {
  symbol: string;
  initialQuote?: FuturesQuote;
  onBack: () => void;
}) {
  const [data, setData] = useState<FuturesDetailData | null>(null);
  const [tab, setTab] = useState<DetailTab>("intraday");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [checkedAt, setCheckedAt] = useState("");

  const load = useCallback(() => {
    setLoading(true);
    api
      .futuresDetail(symbol)
      .then((value) => {
        setData(value);
        setCheckedAt(formatChinaDateTime(Date.now() / 1000 - 978_307_200));
        setError("");
      })
      .catch((reason) => setError(String(reason)))
      .finally(() => setLoading(false));
  }, [symbol]);

  useEffect(() => {
    setData(null);
    setTab("intraday");
    load();
  }, [load]);

  const quote = data?.quote ?? initialQuote;
  const change = quoteChange(quote);
  const changeRate = quoteRate(quote);
  const amplitude = quoteAmplitude(quote);
  const intraday = data?.intraday;
  const intradayPoints = intraday?.points ?? [];
  const labels = intradayPoints.map((point) =>
    swiftDate(point.time).toLocaleTimeString("zh-CN", {
      timeZone: "Asia/Shanghai",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false
    })
  );

  return (
    <div className="futures-detail">
      <header className="topbar futures-detail-header">
        <div className="page-heading page-heading-back">
          <button className="detail-back" onClick={onBack}>‹ 返回期货列表</button>
          <h1>{data?.title ?? futuresTitle(symbol)}</h1>
          <p className="subtitle">{symbol} · {quote?.kind ?? futuresKind(symbol)}</p>
        </div>
        <p className="subtitle futures-detail-source">新浪财经 · 北京时间</p>
      </header>
      <section className="panel futures-detail-panel">
        <div className="futures-detail-top">
          <h3>最新报价</h3>
          <div>
            {checkedAt && <span>获取于 {checkedAt}</span>}
            <button className="ghost small" onClick={load} disabled={loading}>
              {loading ? "刷新中…" : "⟳ 刷新"}
            </button>
          </div>
        </div>

        <div className="futures-quote-summary">
          <div className="futures-price-row">
            <div className="futures-price">
              <strong className={(change ?? 0) >= 0 ? "up" : "down"}>{formatMoney(quote?.price)}</strong>
              <span className={(change ?? 0) >= 0 ? "up" : "down"}>
                {formatSigned(change)}
              </span>
              <span className={(change ?? 0) >= 0 ? "up" : "down"}>
                {formatPercent(changeRate)}
              </span>
            </div>
            <span className="hint quote-time">
              {quote ? `报价 ${quoteClock(quote.time)}` : "暂无报价"}
            </span>
          </div>
          <div className="futures-stats">
            <div><span>今开</span><strong>{formatMoney(quote?.open)}</strong></div>
            <div><span>最高</span><strong>{formatMoney(quote?.high)}</strong></div>
            <div><span>最低</span><strong>{formatMoney(quote?.low)}</strong></div>
            <div><span>参考价</span><strong>{formatMoney(quote?.reference)}</strong></div>
            <div><span>振幅</span><strong>{amplitude != null ? `${amplitude.toFixed(2)}%` : "—"}</strong></div>
            <div><span>持仓量</span><strong>{quote?.openInterest?.toLocaleString("zh-CN") ?? "—"}</strong></div>
          </div>
        </div>

        {error && <p className="error">{error}</p>}
        {data?.errors?.map((message) => <p className="note" key={message}>{message}</p>)}

        <div className="tabs page-tabs" aria-label="期货图表周期">
          {DETAIL_TABS.map((item) => (
            <button
              key={item.id}
              className={tab === item.id ? "active" : ""}
              onClick={() => setTab(item.id)}
            >
              {item.label}
            </button>
          ))}
        </div>

        <div className="futures-chart-head">
          <h3>
            {tab === "intraday" ? "分时走势" :
              tab === "five" ? "五日走势" :
              tab === "daily" ? "日K走势" :
              tab === "weekly" ? "周K走势" : "月K走势"}
          </h3>
          <span>{checkedAt && `获取于 ${checkedAt}`}</span>
          <button className="ghost small" onClick={load} disabled={loading}>
            {loading ? "刷新中…" : "⟳ 刷新"}
          </button>
        </div>
        <div className="futures-chart-body">
          {tab === "intraday" && (
            <>
              <FuturesIntradayChart trend={intraday} loading={loading} />
              {intradayPoints.length >= 35 && <FuturesMacd labels={labels}
                values={intradayPoints.map((point) => point.value)} />}
            </>
          )}
          {tab === "five" && <FivePanel data={data ?? {
            instrument: symbol,
            title: futuresTitle(symbol),
            daily: [],
            weekly: [],
            monthly: [],
            errors: []
          }} />}
          {(tab === "daily" || tab === "weekly" || tab === "monthly") && data && (
            <CandlePanel data={data} tab={tab} />
          )}
          {!data && tab !== "intraday" && <div className="empty">正在获取数据…</div>}
        </div>
      </section>
    </div>
  );
}

function AddFuturesModal({
  existing,
  onClose,
  onAdded
}: {
  existing: Set<string>;
  onClose: () => void;
  onAdded: (quotes: FuturesQuote[]) => void;
}) {
  const [keyword, setKeyword] = useState("");
  const [results, setResults] = useState<FuturesSuggestion[]>([]);
  const [loading, setLoading] = useState(false);
  const [adding, setAdding] = useState<string | null>(null);
  const [error, setError] = useState("");
  const searchId = useRef(0);

  useEffect(() => {
    const request = ++searchId.current;
    const query = keyword.trim();
    if (!query) {
      setResults([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    const handle = window.setTimeout(() => {
      api
        .searchFutures(query)
        .then((items) => {
          if (request === searchId.current) {
            setResults(items);
            setError("");
          }
        })
        .catch((reason) => {
          if (request === searchId.current) {
            setResults([]);
            setError(String(reason));
          }
        })
        .finally(() => {
          if (request === searchId.current) setLoading(false);
        });
    }, 250);
    return () => {
      window.clearTimeout(handle);
      if (request === searchId.current) searchId.current += 1;
    };
  }, [keyword]);

  const add = async (suggestion: FuturesSuggestion) => {
    if (adding) return;
    setAdding(suggestion.symbol);
    try {
      const quotes = await api.addFutures(suggestion.symbol, suggestion.title);
      onAdded(quotes);
      onClose();
    } catch (reason) {
      setError(String(reason));
    } finally {
      setAdding(null);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal add-modal" onClick={(event) => event.stopPropagation()}>
        <header className="sheet-head">
          <h2>添加期货</h2>
          <button className="sheet-done" onClick={onClose}>完成</button>
        </header>
        <input
          autoFocus
          className="search"
          placeholder="搜索期货名称、代码或拼音"
          value={keyword}
          onChange={(event) => setKeyword(event.target.value)}
        />
        {loading && <p className="hint">搜索中…</p>}
        {error && <p className="error">{error}</p>}
        {!keyword.trim() && (
          <div className="search-suggestions">
            <p className="hint">输入名称、代码或拼音查找外盘期货</p>
            <div>
              <button className="ghost small" onClick={() => setKeyword("原油")}>原油</button>
              <button className="ghost small" onClick={() => setKeyword("黄金")}>黄金</button>
              <button className="ghost small" onClick={() => setKeyword("伦镍")}>伦镍</button>
            </div>
          </div>
        )}
        <div className="search-results">
          {results.map((item) => {
            const added = existing.has(item.symbol);
            return (
              <button
                key={item.symbol}
                className="search-row"
                disabled={added || Boolean(adding)}
                onClick={() => void add(item)}
              >
                <span>
                  <strong>{item.title}</strong>
                  <em>{item.symbol} · {item.kind}</em>
                </span>
                <b>{added ? "已添加" : adding === item.symbol ? "添加中…" : "添加"}</b>
              </button>
            );
          })}
          {!loading && keyword.trim() && results.length === 0 && !error && (
            <p className="hint">没有匹配结果</p>
          )}
        </div>
      </div>
    </div>
  );
}

export default function FuturesView() {
  const [quotes, setQuotes] = useState<FuturesQuote[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [loadedAt, setLoadedAt] = useState("");
  const [order, setOrder] = useState<"default" | "desc" | "asc">("default");
  const [selected, setSelected] = useState<string | null>(null);
  const [addOpen, setAddOpen] = useState(false);
  const [refreshAt, setRefreshAt] = useState(0);
  const quoteRequest = useRef(false);

  const load = useCallback((refresh = false) => {
    if (quoteRequest.current) return;
    quoteRequest.current = true;
    if (refresh) setRefreshAt(Date.now());
    setLoading(true);
    api
      .futuresQuotes()
      .then((value) => {
        setQuotes(value);
        setLoadedAt(new Intl.DateTimeFormat("sv-SE", {
          timeZone: "Asia/Shanghai",
          year: "numeric",
          month: "2-digit",
          day: "2-digit",
          hour: "2-digit",
          minute: "2-digit",
          hour12: false
        }).format(new Date()));
        setError("");
      })
      .catch((reason) => setError(String(reason)))
      .finally(() => {
        quoteRequest.current = false;
        setLoading(false);
      });
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const bySymbol = useMemo(
    () => new Map(quotes.map((quote) => [quote.instrument, quote])),
    [quotes]
  );
  const ordered = useMemo(() => {
    const custom = quotes
      .map((quote) => quote.instrument)
      .filter((symbol) => !FUTURES_ORDER.includes(symbol));
    const symbols = [...FUTURES_ORDER, ...custom];
    if (order === "default") return symbols;
    return symbols.sort((left, right) => {
      const a = quoteRate(bySymbol.get(left));
      const b = quoteRate(bySymbol.get(right));
      if (a == null && b == null) return 0;
      if (a == null) return 1;
      if (b == null) return -1;
      return order === "desc" ? b - a : a - b;
    });
  }, [order, bySymbol]);

  if (selected) {
    return (
      <FuturesDetailPanel
        symbol={selected}
        initialQuote={bySymbol.get(selected)}
        onBack={() => setSelected(null)}
      />
    );
  }

  return (
    <div className="futures-view">
      <header className="futures-title-row">
        <h1>期货</h1>
        <p>新浪财经 · 报价可能延迟 · 北京时间</p>
        <div className="futures-title-actions">
          <button className="ghost small" onClick={() => setAddOpen(true)}>＋ 添加自选</button>
          <label htmlFor="futures-order">排序</label>
          <select
            id="futures-order"
            className="select"
            value={order}
            onChange={(event) => setOrder(event.target.value as typeof order)}
          >
            <option value="default">默认顺序</option>
            <option value="desc">涨跌幅从高到低</option>
            <option value="asc">涨跌幅从低到高</option>
          </select>
        </div>
      </header>

      {error && <div className="banner error">{error}</div>}

      <div className="panel futures-table-panel">
        <div className="futures-panel-head">
          <h3>外盘行情</h3>
          {loadedAt && <span>获取于 {loadedAt}</span>}
          <div className="section-actions">
            <button className="ghost small" onClick={() => load(true)} disabled={loading}>
              {loading ? "刷新中…" : "⟳ 刷新"}
            </button>
          </div>
        </div>
        <div className="futures-header">
          <span>品种</span>
          <span title="北京时间，显示数据源已返回的完整分时">分时走势 · 北京时间</span>
          <span className="right">最新价</span>
          <span className="right">涨跌额</span>
          <span className="right">涨跌幅</span>
          <span className="right">报价时间</span>
        </div>
        <div className="futures-list">
          {ordered.map((symbol) => {
            const quote = bySymbol.get(symbol);
            const change = quoteChange(quote);
            const rate = quoteRate(quote);
            return (
              <div
                className="futures-row"
                role="button"
                tabIndex={0}
                key={symbol}
                onClick={() => setSelected(symbol)}
                onKeyDown={(event) => {
                  if (event.target === event.currentTarget && (event.key === "Enter" || event.key === " ")) {
                    event.preventDefault();
                    setSelected(symbol);
                  }
                }}
              >
                <span className="futures-name">
                  <strong>{quote?.title ?? futuresTitle(symbol)}</strong>
                  <em>
                    {symbol} · {quote?.kind ?? futuresKind(symbol)}
                    {quote && !quote.builtin && (
                      <button
                        className="link row-remove"
                        onClick={(event) => {
                          event.stopPropagation();
                          api
                            .removeFutures(symbol)
                            .then((value) => {
                              setQuotes(value);
                              intradayCache.delete(symbol);
                            })
                            .catch((reason) => setError(String(reason)));
                        }}
                      >
                        移除
                      </button>
                    )}
                  </em>
                </span>
                <Sparkline symbol={symbol} refreshAt={refreshAt} />
                <span className="right num strong">{formatMoney(quote?.price)}</span>
                <span className={`right num ${(change ?? 0) >= 0 ? "up" : "down"}`}>
                  {formatSigned(change)}
                </span>
                <span className={`right num strong ${(rate ?? 0) >= 0 ? "up" : "down"}`}>
                  {formatPercent(rate)}
                </span>
                <span className="right num muted">
                  {quote ? formatChinaDateTime(quote.time) : "—"}
                </span>
              </div>
            );
          })}
        </div>
        {quotes.length < FUTURES_ORDER.length && !loading && (
          <p className="note">部分报价暂不可用</p>
        )}
      </div>
      {addOpen && (
        <AddFuturesModal
          existing={new Set([
            ...FUTURES_ORDER,
            ...quotes.map((quote) => quote.instrument.toUpperCase())
          ])}
          onClose={() => setAddOpen(false)}
          onAdded={(value) => {
            setQuotes(value);
            setError("");
          }}
        />
      )}
    </div>
  );
}
