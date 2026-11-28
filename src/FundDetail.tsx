import { useEffect, useMemo, useRef, useState } from "react";
import {
  api,
  BoardView,
  DETAIL_TITLES,
  formatChinaDateTime,
  formatChinaTime,
  formatMoney,
  formatPercent,
  formatSigned,
  FundDetail as FundDetailData,
  FundDisclosure,
  FundRow,
  Nav,
  swiftDate
} from "./api";
import { MacdObservation } from "./MacdObservation";
import { RedObservation } from "./RedObservation";
import { EstimateIntradayChart, LineChart } from "./chart";

const PERIODS = ["近1月", "近3月", "近6月", "近1年", "近3年", "近5年", "成立以来"];
const BASE_TABS = ["estimate", "history", "returns", "holdings", "profile", "observation"];
const MONTHS: Record<string, number | null> = {
  近1月: 1,
  近3月: 3,
  近6月: 6,
  近1年: 12,
  近3年: 36,
  近5年: 60,
  成立以来: null
};
const HISTORY_STYLES = [
  ["unit", "单位净值"],
  ["accumulated", "累计净值"]
] as const;

function chinaDay(value: number): string {
  return new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  }).format(swiftDate(value));
}

function cutoffDay(navs: Nav[], period: string): string | null {
  const months = MONTHS[period];
  if (months == null || navs.length === 0) return null;
  const last = navs[navs.length - 1].day;
  const date = new Date(`${last}T00:00:00+08:00`);
  date.setMonth(date.getMonth() - months);
  return date.toISOString().slice(0, 10);
}

function filterNavs(navs: Nav[], period: string): Nav[] {
  const cutoff = cutoffDay(navs, period);
  return cutoff ? navs.filter((nav) => nav.day >= cutoff) : navs;
}

function changeTone(value?: number) {
  if (value == null || value === 0) return "flat";
  return value > 0 ? "up" : "down";
}

function signedMoney(value?: number): string {
  const signed = formatSigned(value);
  if (signed === "—") return signed;
  return signed.startsWith("+") || signed.startsWith("−")
    ? `${signed[0]}¥${signed.slice(1)}`
    : `¥${signed}`;
}

function stockQuoteSymbol(holding: { code: string; stockMarket?: string }): string | undefined {
  const prefix =
    holding.stockMarket === "shanghai" ? "sh" :
    holding.stockMarket === "shenzhen" ? "sz" :
    holding.stockMarket === "beijing" ? "bj" :
    holding.stockMarket === "hongkong" || holding.stockMarket === "hongKong" ? "hk" :
    holding.stockMarket === "unitedstates" || holding.stockMarket === "unitedStates" ? "us" : undefined;
  if (!prefix) return undefined;
  const code = holding.stockMarket === "unitedstates" || holding.stockMarket === "unitedStates"
    ? holding.code.toUpperCase().replaceAll("-", ".")
    : holding.code;
  return `${prefix}${code}`;
}

function RefreshableTitle({
  title,
  detail,
  loadedAt,
  refreshing,
  onRefresh
}: {
  title: string;
  detail?: string;
  loadedAt: string;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  return (
    <div className="card-title-row">
      <div>
        <h3>{title}</h3>
        {detail && <p className="hint">{detail}</p>}
      </div>
      <div className="card-side">
        {loadedAt && <span>获取于 {loadedAt}</span>}
        <button className="ghost small" disabled={refreshing} onClick={onRefresh}>⟳ 刷新</button>
      </div>
    </div>
  );
}

function PositionStat({
  label,
  value,
  suffix,
  color
}: {
  label: string;
  value: string;
  suffix?: string;
  color?: string;
}) {
  return (
    <div className="position-stat">
      <span>{label}</span>
      <strong className={color}>{value}{suffix && <em>{suffix}</em>}</strong>
    </div>
  );
}

export default function FundDetail({
  code,
  row,
  tabs,
  onTabsChanged,
  onClose,
  onChanged
}: {
  code: string;
  row?: FundRow;
  tabs: string[];
  onTabsChanged: (view: BoardView) => void;
  onClose: () => void;
  onChanged: (view: BoardView) => void;
}) {
  const [detail, setDetail] = useState<FundDetailData | null>(null);
  const [tab, setTab] = useState("holdings");
  const [historyPeriod, setHistoryPeriod] = useState("近1年");
  const [returnsPeriod, setReturnsPeriod] = useState("近1年");
  const [historyStyle, setHistoryStyle] = useState<"unit" | "accumulated">("unit");
  const [error, setError] = useState("");
  const [loadedAt, setLoadedAt] = useState("");
  const [editing, setEditing] = useState(false);
  const [shares, setShares] = useState("");
  const [cost, setCost] = useState("");
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);
  const [dragTab, setDragTab] = useState<string | null>(null);
  const [dragOverTab, setDragOverTab] = useState<string | null>(null);
  const [showTarget, setShowTarget] = useState(false);
  const [targetDetail, setTargetDetail] = useState<FundDisclosure | null>(null);
  const [targetLoading, setTargetLoading] = useState(false);
  const [refreshingDisclosure, setRefreshingDisclosure] = useState(false);
  const dragState = useRef<{
    item: string;
    pointerId: number;
    startX: number;
    startY: number;
    active: boolean;
  } | null>(null);
  const suppressTabClick = useRef(false);

  useEffect(() => {
    let cancelled = false;
    setDetail(null);
    setError("");
    setShowTarget(false);
    setTargetDetail(null);
    api
      .fundDetail(code)
      .then((value) => {
        if (!cancelled) {
          setDetail(value);
          setLoadedAt(formatChinaDateTime(Date.now() / 1000 - 978_307_200));
        }
      })
      .catch((reason) => {
        if (!cancelled) setError(String(reason));
      });
    return () => {
      cancelled = true;
    };
  }, [code]);

  useEffect(() => {
    if (!row) return;
    setShares(row.shares != null ? String(row.shares) : "");
    setCost(row.cost != null ? String(row.cost) : "");
    setEditing(false);
    setSaved(false);
  }, [row?.code]);

  const availableTabs = useMemo(
    () =>
      tabs.filter(
        (item) =>
          BASE_TABS.includes(item) &&
          (item !== "observation" || Boolean(row?.groups.length))
      ),
    [tabs, detail, row]
  );

  useEffect(() => {
    if (availableTabs.length && !availableTabs.includes(tab)) {
      setTab(availableTabs[0]);
    }
  }, [availableTabs, tab]);

  const navs = detail?.history?.navs ?? [];
  const platformName = navigator.userAgent.includes("Mac") ? "Mac" : "Windows 电脑";
  const snapshotNav = detail?.snapshot?.history?.at(-1);
  const nav = snapshotNav ?? navs.at(-1);
  const estimate = detail?.snapshot?.estimate ?? detail?.estimateSeries.at(-1);
  const period = tab === "returns" ? returnsPeriod : historyPeriod;
  const setPeriod = tab === "returns" ? setReturnsPeriod : setHistoryPeriod;
  const isMoney = (detail?.kind ?? row?.kind ?? "").includes("货币");

  const detailTabAt = (x: number, y: number) => {
    const element = document.elementFromPoint(x, y);
    const tab = element?.closest<HTMLElement>("[data-detail-tab]");
    return tab?.dataset.detailTab ?? null;
  };

  const beginTabDrag = (event: React.PointerEvent<HTMLButtonElement>, item: string) => {
    if (event.button !== 0) return;
    dragState.current = {
      item,
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      active: false
    };
    event.currentTarget.setPointerCapture(event.pointerId);
  };

  const updateTabDrag = (event: React.PointerEvent<HTMLButtonElement>) => {
    const drag = dragState.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    if (!drag.active) {
      if (Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) < 4) return;
      drag.active = true;
      setDragTab(drag.item);
    }
    event.preventDefault();
    const target = detailTabAt(event.clientX, event.clientY);
    setDragOverTab(target && target !== drag.item ? target : null);
  };

  const finishTabDrag = (event: React.PointerEvent<HTMLButtonElement>) => {
    const drag = dragState.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    dragState.current = null;
    if (drag.active) {
      suppressTabClick.current = true;
      window.setTimeout(() => {
        suppressTabClick.current = false;
      }, 0);
      const target = detailTabAt(event.clientX, event.clientY);
      if (target && target !== drag.item) {
        api
          .moveDetailTab(drag.item, target)
          .then(onTabsChanged)
          .catch((reason) => setError(String(reason)));
      }
    }
    setDragTab(null);
    setDragOverTab(null);
  };

  const cancelTabDrag = () => {
    dragState.current = null;
    setDragTab(null);
    setDragOverTab(null);
  };

  const visibleNavs = useMemo(() => filterNavs(navs, historyPeriod), [navs, historyPeriod]);
  const navPoints = useMemo(
    () => visibleNavs.map((item) => ({ label: item.day, value: item.value })),
    [visibleNavs]
  );
  const accumulatedPoints = useMemo(() => {
    const points = detail?.history?.accumulated ?? [];
    const cutoff = cutoffDay(navs, historyPeriod);
    return (cutoff ? points.filter((point) => chinaDay(point.time) >= cutoff) : points)
      .map((point) => ({ label: chinaDay(point.time), value: point.value }));
  }, [detail, historyPeriod, navs]);
  const returnPoints = useMemo(() => {
    const points = detail?.returns?.[returnsPeriod] ?? [];
    return points.map((point) => ({ label: chinaDay(point.time), value: point.value }));
  }, [detail, returnsPeriod]);
  const estimateDay = estimate?.marketDay ?? detail?.estimateSeries.at(-1)?.marketDay ?? "";
  const estimatePoints = useMemo(() => {
    const series = detail?.estimateSeries ?? [];
    if (!series.length) return [];
    const day = series[series.length - 1].marketDay;
    return series
      .filter((point) => point.marketDay === day)
      .map((point) => ({ label: formatChinaTime(point.timestamp), value: point.value }));
  }, [detail]);
  const estimateIntraday = useMemo(() => {
    const series = detail?.estimateSeries ?? [];
    if (!series.length) return [];
    const day = series[series.length - 1].marketDay;
    return series
      .filter((point) => point.marketDay === day)
      .map((point) => ({ time: point.timestamp, value: point.value }));
  }, [detail]);
  const observation = detail?.observation;
  const disclosureSymbols = useMemo(
    () => new Set((detail?.disclosure?.holdings ?? []).map(stockQuoteSymbol).filter(Boolean) as string[]),
    [detail]
  );
  const disclosureQuotes = detail?.stockQuotes ?? {};
  const latestQuoteTime = useMemo(() => {
    const times = [...disclosureSymbols]
      .map((symbol) => disclosureQuotes[symbol]?.time)
      .filter((value): value is number => value != null);
    return times.length ? Math.max(...times) : null;
  }, [disclosureQuotes, disclosureSymbols]);
  const stockQuoteStatus = (() => {
    if (!disclosureSymbols.size) return "个股行情暂不可用";
    const quotes = [...disclosureSymbols].map((symbol) => disclosureQuotes[symbol]).filter(Boolean);
    if (detail?.stockQuoteFailed) {
      return quotes.length ? "腾讯行情 · 刷新失败，显示上次报价" : "腾讯行情 · 刷新失败";
    }
    if (!latestQuoteTime) return "正在获取个股行情…";
    const coverage = quotes.length < disclosureSymbols.size ? " · 部分报价缺失" : "";
    return `腾讯行情 · 最新 ${formatChinaDateTime(latestQuoteTime)}${coverage}`;
  })();

  const positionDecimal = (input: string): number | null => {
    const normalized = input.replaceAll(",", "").replaceAll("，", "").replaceAll("¥", "").trim();
    if (!normalized) return null;
    const value = Number(normalized);
    return Number.isFinite(value) ? value : null;
  };
  const quantity = positionDecimal(shares);
  const costPerShare = positionDecimal(cost);
  const sharesEmpty = shares.trim() === "";
  const costEmpty = cost.trim() === "";
  const positionValidation =
    !sharesEmpty && quantity == null ? "持有份额请输入数字" :
    quantity != null && quantity < 0 ? "持有份额不能小于 0" :
    !isMoney && !costEmpty && costPerShare == null ? "单位成本请输入数字" :
    !isMoney && costPerShare != null && costPerShare <= 0 ? "单位成本必须大于 0" : null;
  const previewValue =
    quantity != null && nav?.value != null && quantity > 0 ? quantity * nav.value : undefined;
  const previewProfit =
    previewValue != null && costPerShare != null && quantity != null
      ? previewValue - quantity * costPerShare
      : undefined;
  const canSave =
    !positionValidation &&
    (sharesEmpty || (quantity != null && quantity >= 0)) &&
    (isMoney || costEmpty || (costPerShare != null && costPerShare > 0));

  const saveHolding = async () => {
    if (!canSave) return;
    setBusy(true);
    try {
      const view = await api.setHolding(
        code,
        sharesEmpty ? null : quantity,
        isMoney ? null : (costEmpty ? null : costPerShare)
      );
      onChanged(view);
      setEditing(false);
      setSaved(true);
      setError("");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  const openTarget = async () => {
    const target = detail?.disclosure?.targetCode;
    if (!target) return;
    if (showTarget) {
      setShowTarget(false);
      return;
    }
    setShowTarget(true);
    if (!targetDetail) {
      setTargetLoading(true);
      try {
        setTargetDetail(await api.fundDisclosure(target));
      } catch (reason) {
        setError(String(reason));
      } finally {
        setTargetLoading(false);
      }
    }
  };

  const refreshDetail = async () => {
    setRefreshingDisclosure(true);
    try {
      const value = await api.fundDetail(code);
      setDetail(value);
      setLoadedAt(formatChinaDateTime(Date.now() / 1000 - 978_307_200));
      if (showTarget && value.disclosure?.targetCode) {
        setTargetDetail(await api.fundDisclosure(value.disclosure.targetCode));
      }
      setError("");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setRefreshingDisclosure(false);
    }
  };

  const disclosureTable = (report: FundDisclosure | undefined, quotes: Record<string, { rate: number; time: number }>) => {
    const holdings = report?.holdings ?? [];
    if (!holdings.length) return <p className="hint">该报告暂未提供重仓明细。</p>;
    const showsQuotes = holdings.some((holding) => holding.type === "股票");
    return (
      <div className="disclosure-table">
        <div className={`disclosure-row header${showsQuotes ? "" : " no-quote"}`}>
          <span>名称</span>
          <span>代码</span>
          <span>类别</span>
          {showsQuotes && <span>当日涨跌幅</span>}
          <span>占净值</span>
          <span>较上期</span>
        </div>
        {holdings.map((holding) => {
          const symbol = stockQuoteSymbol(holding);
          const quote = symbol ? quotes[symbol] : undefined;
          return (
            <div className={`disclosure-row${showsQuotes ? "" : " no-quote"}`} key={`${holding.type}-${holding.code}`}>
              <span>{holding.name}</span>
              <span>{holding.code}</span>
              <span>{holding.type}</span>
              {showsQuotes && (
                <span className={changeTone(quote?.rate)} title={quote ? `腾讯行情 · ${formatChinaDateTime(quote.time)} 北京时间` : "当日涨跌幅"}>
                  {formatPercent(quote?.rate)}
                </span>
              )}
              <span>{holding.weight.toFixed(2)}%</span>
              <span>{holding.change ?? "—"}</span>
            </div>
          );
        })}
      </div>
    );
  };

  return (
    <div className="detail-page">
        <header className="detail-head">
          <button className="detail-back" onClick={onClose}>‹ 返回</button>
          <div className="detail-identity">
            <h2>{detail?.name ?? row?.name ?? code}</h2>
            <p className="detail-subtitle">{code}{detail?.kind || row?.kind ? `  ·  ${detail?.kind ?? row?.kind}` : ""}</p>
            {(row?.groups.length ?? 0) > 0 && (
              <p className="group-caption">
                {row?.groups.map((group) => group === "macd" ? "MACD 观察" : "红利观察").join("  ·  ")}
              </p>
            )}
          </div>
        </header>

        <div className="detail-quote-cards">
          <section className="quote-card">
            <span className="quote-label">{isMoney ? "每万份收益" : "正式净值"}</span>
            <div className="quote-line">
              <strong>{nav?.value != null ? nav.value.toFixed(4) : "—"}</strong>
              <em className={isMoney ? "flat" : changeTone(nav?.rate)}>
                {formatPercent(isMoney ? nav?.annualizedRate : nav?.rate)}
              </em>
            </div>
            <p>{nav ? `${nav.day}  ·  ${nav.source}${isMoney ? "  ·  七日年化" : ""}` : "等待可用正式净值"}</p>
          </section>
          <section className="quote-card">
            <span className="quote-label">盘中估算</span>
            <div className="quote-line">
              <strong>{estimate?.value != null ? estimate.value.toFixed(4) : "—"}</strong>
              <em className={changeTone(estimate?.percent)}>{formatPercent(estimate?.percent)}</em>
            </div>
            <p>
              {isMoney
                ? "此类基金按万份收益展示"
                : estimate
                  ? `${formatChinaDateTime(estimate.timestamp)}  ·  新浪财经`
                  : "数据源暂未提供估算"}
            </p>
          </section>
        </div>

        <div className="detail-tabs swift-tabs" aria-label="基金详情">
          {availableTabs.map((item) => (
            <button
              key={item}
              data-detail-tab={item}
              className={[
                tab === item ? "active" : "",
                dragTab === item ? "dragging" : "",
                dragOverTab === item ? "drop-target" : ""
              ].filter(Boolean).join(" ")}
              onClick={() => {
                if (suppressTabClick.current) {
                  suppressTabClick.current = false;
                  return;
                }
                setTab(item);
              }}
              onPointerDown={(event) => beginTabDrag(event, item)}
              onPointerMove={updateTabDrag}
              onPointerUp={finishTabDrag}
              onPointerCancel={cancelTabDrag}
              onLostPointerCapture={cancelTabDrag}
            >
              {DETAIL_TITLES[item] ?? item}
            </button>
          ))}
        </div>

        {error && <p className="error detail-error">{error}</p>}

        <div className="detail-body">
          {tab === "holdings" && (
            <section className="swift-card">
              <div className="card-title-row">
                <div>
                  <h3>公开披露的持仓</h3>
                  <p className="hint">
                    披露期 {detail?.disclosure?.reportDay ?? "未提供"} · 天天基金
                  </p>
                  <p className="quote-status">{stockQuoteStatus}</p>
                </div>
                <div className="card-side disclosure-side">
                  <div className="card-side-line">
                    <span>获取于 {loadedAt}</span>
                    <button className="ghost small" disabled={refreshingDisclosure} onClick={() => void refreshDetail()}>
                      ⟳ 刷新
                    </button>
                  </div>
                  {detail?.disclosure?.targetCode && (
                    <span className="target-caption">
                      目标 ETF  {detail.disclosure.targetName ?? ""} {detail.disclosure.targetCode}
                    </span>
                  )}
                </div>
              </div>
              {disclosureTable(detail?.disclosure, disclosureQuotes)}
              {detail?.disclosure?.targetCode && detail.disclosure.targetCode !== code && (
                <div className="target-block">
                  <button className="ghost small" onClick={() => void openTarget()}>
                    {showTarget ? "收起目标 ETF 持仓" : "查看目标 ETF 持仓"}
                  </button>
                  {showTarget && (
                    <div className="target-disclosure">
                      <div className="card-title-row">
                        <h3>{detail.disclosure.targetName ?? detail.disclosure.targetCode}</h3>
                        <span className="hint">
                          披露期 {targetDetail?.reportDay ?? "未提供"} · 天天基金
                        </span>
                      </div>
                      {targetLoading && <p className="hint">正在读取目标 ETF 持仓…</p>}
                      {targetDetail && disclosureTable(targetDetail, {})}
                    </div>
                  )}
                </div>
              )}
            </section>
          )}

          {tab === "estimate" && (
            <section className="swift-card">
              {isMoney ? (
                <p className="hint">货币基金按披露的万份收益和七日年化查看。</p>
              ) : (
                <>
                  <RefreshableTitle
                    title="估算分时"
                    detail={estimateDay ? `${estimateDay} · 新浪财经 · 估算净值` : "等待估算数据"}
                    loadedAt={loadedAt}
                    refreshing={refreshingDisclosure}
                    onRefresh={() => void refreshDetail()}
                  />
                  {estimatePoints.length > 0 ? (
                    <>
                      <p className="chart-readout">
                        {estimatePoints.at(-1)?.label}   {estimatePoints.at(-1)?.value.toFixed(4)}
                      </p>
                      {/(QDII|海外|全球|美国|香港|纳斯达克|标普)/.test(`${detail?.name ?? ""} ${detail?.kind ?? ""}`) ? (
                        <LineChart
                          points={estimatePoints}
                          digits={4}
                          height={211}
                          area={false}
                          primary
                          emptyText="数据源未提供该基金的估算分时。"
                        />
                      ) : (
                        <EstimateIntradayChart points={estimateIntraday} height={211} />
                      )}
                    </>
                  ) : (
                    <p className="hint">数据源未提供该基金的估算分时。</p>
                  )}
                </>
              )}
            </section>
          )}

          {(tab === "history" || tab === "returns") && (
            <section className="swift-card">
              <RefreshableTitle
                title={tab === "history" ? "净值走势" : "区间累计收益"}
                loadedAt={loadedAt}
                refreshing={refreshingDisclosure}
                onRefresh={() => void refreshDetail()}
              />
              <div className="history-toolbar">
                <div className="segmented swift-segmented">
                  {PERIODS.map((item) => (
                    <button key={item} className={period === item ? "active" : ""} onClick={() => setPeriod(item)}>
                      {item}
                    </button>
                  ))}
                </div>
                {tab === "history" && !isMoney && Boolean(detail?.history?.accumulated?.length) && (
                  <select value={historyStyle} onChange={(event) => setHistoryStyle(event.target.value as "unit" | "accumulated")}>
                    {HISTORY_STYLES.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
                  </select>
                )}
              </div>
              {detail?.history?.degraded && (
                <p className="note">⚠ {detail.history.degradationNote ?? "历史净值接口暂时不可用，当前显示最近披露数据。"}</p>
              )}
              {tab === "returns" ? (
                <>
                  <p className="hint">
                    {isMoney ? "按披露的万份收益复利计算 · 天天基金" : "按披露的日涨跌复利计算 · 天天基金"}
                  </p>
                  {returnPoints.length > 0 && (
                    <p className="chart-readout">
                      {returnPoints.at(-1)?.label}   {formatPercent(returnPoints.at(-1)?.value)}
                    </p>
                  )}
                  <LineChart points={returnPoints} baseline={0} digits={2} height={195} symmetric primary area={false} emptyText="暂无收益数据" />
                </>
              ) : (
                <>
                  <p className="hint">
                    {(isMoney ? "万份收益" : historyStyle === "accumulated" ? "累计净值" : "单位净值")}
                    {" · "}{(historyStyle === "accumulated" ? accumulatedPoints : navPoints).length} 个披露日 · 天天基金
                  </p>
                  {(isMoney || historyStyle === "unit" ? navPoints : accumulatedPoints).at(-1) && (
                    <p className="chart-readout">
                      {(isMoney || historyStyle === "unit" ? navPoints : accumulatedPoints).at(-1)?.label}
                      {"   "}
                      {(isMoney || historyStyle === "unit" ? navPoints : accumulatedPoints).at(-1)?.value.toFixed(4)}
                    </p>
                  )}
                  <LineChart
                    points={isMoney || historyStyle === "unit" ? navPoints : accumulatedPoints}
                    digits={4}
                    height={175}
                    primary
                    area={false}
                    emptyText="暂无净值数据"
                  />
                  <h4 className="recent-title">最近披露</h4>
                  <div className="recent-nav-grid">
                    <div className="recent-nav-row header">
                      <span>净值日期</span>
                      <span>{isMoney ? "万份收益" : "单位净值"}</span>
                      <span>{isMoney ? "七日年化" : "日涨跌"}</span>
                    </div>
                    {visibleNavs.slice(-8).reverse().map((item) => (
                      <div className="recent-nav-row" key={item.day}>
                        <span>{item.day}</span>
                        <span>{item.value.toFixed(4)}</span>
                        <span className={changeTone(isMoney ? item.annualizedRate : item.rate)}>
                          {formatPercent(isMoney ? item.annualizedRate : item.rate)}
                        </span>
                      </div>
                    ))}
                  </div>
                </>
              )}
            </section>
          )}

          {tab === "profile" && (
            <div className="profile-cards">
              <section className="swift-card">
                <RefreshableTitle
                  title="基金档案"
                  loadedAt={loadedAt}
                  refreshing={refreshingDisclosure}
                  onRefresh={() => void refreshDetail()}
                />
                <div className="profile-grid">
                  <div><span>基金类型</span><strong>{detail?.profile?.category ?? "—"}</strong></div>
                  <div><span>基金公司</span><strong>{detail?.profile?.company ?? "—"}</strong></div>
                  <div><span>基金经理</span><strong>{detail?.profile?.managerNames ?? "—"}</strong></div>
                  <div><span>基金规模</span><strong>{detail?.profile?.size != null ? `${formatMoney(detail.profile.size / 100_000_000)} 亿元` : "—"}</strong></div>
                  <div><span>申购状态</span><strong>{detail?.profile?.subscription ?? "—"}</strong></div>
                  <div><span>赎回状态</span><strong>{detail?.profile?.redemption ?? "—"}</strong></div>
                  <div><span>累计净值</span><strong>{detail?.profile?.cumulativeNav?.toFixed(4) ?? "—"}</strong></div>
                  <div><span>公布费率</span><strong>{detail?.profile?.originalFee ?? detail?.profile?.purchaseFee ?? "—"}</strong></div>
                </div>
                {Boolean(detail?.profile?.recent.length) && (
                  <div className="profile-periods">
                    {detail?.profile?.recent.map((item) => (
                      <div key={item.period}>
                        <span>{item.period}</span>
                        <strong className={changeTone(item.rate)}>{formatPercent(item.rate)}</strong>
                        <em>{item.rank ? `排名 ${item.rank}${item.sample ? `/${item.sample}` : ""}` : "—"}</em>
                      </div>
                    ))}
                  </div>
                )}
              </section>
              <section className="swift-card">
                <RefreshableTitle
                  title="基金经理"
                  loadedAt={loadedAt}
                  refreshing={refreshingDisclosure}
                  onRefresh={() => void refreshDetail()}
                />
                {!detail?.managers?.current.length && !detail?.managers?.tenures.length && (
                  <p className="hint">数据源暂未提供经理档案。</p>
                )}
                <div className="manager-disclosures">
                  {detail?.managers?.current.map((manager) => (
                    <details key={manager.id}>
                      <summary>{manager.name}{manager.since ? ` · ${manager.since} 起` : ""}</summary>
                      {manager.education && <p className="hint">{manager.education}</p>}
                      <p>{manager.resume ?? "简介暂未披露。"}</p>
                    </details>
                  ))}
                </div>
                {Boolean(detail?.managers?.tenures.length) && (
                  <>
                    <h4 className="recent-title">历任区间</h4>
                    <div className="tenure-table">
                      {detail?.managers?.tenures.map((tenure) => (
                        <div key={`${tenure.name}-${tenure.since}`}>
                          <span>{tenure.name}</span>
                          <span>{tenure.since ?? "—"} 至 {tenure.end ?? "现在"}</span>
                          <span className={changeTone(tenure.rate)}>{formatPercent(tenure.rate)}</span>
                        </div>
                      ))}
                    </div>
                  </>
                )}
              </section>
            </div>
          )}

          {tab === "observation" && (
            <section className="observation-tab">
              {!observation && (
                <div className="empty observation-empty">
                  暂未取得历史净值。观察数据会自动从公开净值生成，请检查数据源或在后台刷新后重试，无需导入。
                </div>
              )}
              {row?.groups.includes("macd") && observation && (
                <MacdObservation key={code} observation={observation} />
              )}
              {row?.groups.includes("red") && observation?.valuation && (
                <RedObservation
                  valuation={observation.valuation}
                  source={observation.source}
                  updatedDay={observation.updatedDay}
                />
              )}
              {Boolean(observation?.metrics.length) && (
                <div className="observation-metrics">
                  <div className="metric-grid">
                    {observation?.metrics.map((metric) => (
                      <div className="metric-card" key={metric.key}>
                        <span>{metric.label}</span>
                        <strong>{metric.value}</strong>
                        {metric.note && <em>{metric.note}</em>}
                      </div>
                    ))}
                  </div>
                </div>
              )}
              <p className="hint observation-foot">
                {observation
                  ? `观察数据由历史净值自动计算，更新至 ${observation.updatedDay}；后台刷新会继续补齐。`
                  : "观察数据由历史净值自动计算，无需外部导入。"}
              </p>
            </section>
          )}
        </div>

        <section className="position-panel">
          <header className="position-head">
            <div>
              <h3>本地持仓</h3>
              <p className="hint">只保存在这台 {platformName}，可随时修改份额和单位成本</p>
            </div>
            <div className="position-actions">
              {saved && <span className="saved-note">已保存</span>}
              {!editing && (
                <button className="primary small" onClick={() => {
                  setShares(row?.shares != null ? String(row.shares) : "");
                  setCost(row?.cost != null ? String(row.cost) : "");
                  setEditing(true);
                  setSaved(false);
                }}>✎ 编辑持仓</button>
              )}
            </div>
          </header>
          {editing ? (
            <>
              <div className="position-editor">
                <label className="position-field">
                  <span>持有份额</span>
                  <div><input autoFocus value={shares} onChange={(event) => setShares(event.target.value)} placeholder="例如 10,000.00" /><em>份</em></div>
                  <small>{sharesEmpty ? "留空保存会清除持仓" : "当前份额"}</small>
                </label>
                {!isMoney && (
                  <label className="position-field">
                    <span>单位成本</span>
                    <div><input value={cost} onChange={(event) => setCost(event.target.value)} placeholder="例如 1.0144" /><em>元</em></div>
                    <small>{costEmpty ? "用于计算持有收益" : "当前单位成本"}</small>
                  </label>
                )}
                <div className="position-nav">
                  <span>当前正式净值</span>
                  <strong>{nav?.value != null ? nav.value.toFixed(4) : "—"}</strong>
                  <small>{nav?.day ?? "等待净值"}</small>
                </div>
              </div>
              <div className="position-editor-foot">
                <div>
                  {positionValidation ? (
                    <span className="down">⚠ {positionValidation}</span>
                  ) : previewValue != null ? (
                    <>
                      <span className="muted">＝ 持仓金额约 ¥{formatMoney(previewValue)}</span>
                      {previewProfit != null && <span className={changeTone(previewProfit)}>持有收益约 {signedMoney(previewProfit)}</span>}
                    </>
                  ) : (
                    <span className="muted">ⓘ {isMoney ? "按持有份额计算金额" : "填写份额后可预览持仓金额和收益"}</span>
                  )}
                </div>
                <div className="position-actions">
                  <button className="ghost small" onClick={() => { setEditing(false); setShares(row?.shares != null ? String(row.shares) : ""); setCost(row?.cost != null ? String(row.cost) : ""); }}>取消</button>
                  <button className="primary small" disabled={busy || !canSave} onClick={() => void saveHolding()}>保存持仓</button>
                </div>
              </div>
            </>
          ) : row?.shares != null && row.shares > 0 ? (
            <div className="position-stats">
              <PositionStat label="持有份额" value={formatMoney(row.shares, 2)} suffix="份" />
              {!isMoney && <PositionStat label="单位成本" value={row.cost != null ? row.cost.toFixed(4) : "—"} suffix="元" />}
              <PositionStat label="持有金额" value={row.value != null ? `¥${formatMoney(row.value)}` : "—"} />
              <PositionStat label="持有收益" value={signedMoney(row.profit)} color={changeTone(row.profit)} />
              {row.dayProfit != null && (
                <PositionStat label="盘中估算日收益" value={signedMoney(row.dayProfit)} color={changeTone(row.dayProfit)} />
              )}
              <div className="position-latest">最近净值 {nav?.day ?? "—"}</div>
            </div>
          ) : (
            <div className="position-empty">
              <span>尚未填写持有份额</span>
              <span className="hint">最近净值 {nav?.day ?? "—"}</span>
            </div>
          )}
          {!isMoney && (editing || (row?.shares ?? 0) > 0) && (
            <p className="position-precision-note">
              <strong>持有收益差异提示</strong>
              <span>单位成本只显示 4 位小数。即使两边显示的成本价相同，实际计算时保留的小数位数不同，持有收益也可能有差异。</span>
            </p>
          )}
        </section>

    </div>
  );
}
