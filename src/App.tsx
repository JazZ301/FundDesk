import { listen } from "@tauri-apps/api/event";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  api,
  BoardView,
  COLUMN_TITLES,
  DataSourceStatus,
  formatMoney,
  formatPercent,
  formatSigned,
  FundRow,
  IndexQuote,
  indexTitle,
  MenuBarItem
} from "./api";
import FundDetail from "./FundDetail";
import MarketCenter from "./MarketCenter";
import FuturesView from "./Futures";
import PluginDataTransfer from "./PluginDataTransfer";
import DataSourceDialog from "./DataSource";

type Section = "all" | "holding" | "macd" | "red" | "market" | "futures" | "settings";
type SortKey =
  | "estimateRate"
  | "dayProfit"
  | "value"
  | "profit"
  | "profitRate"
  | "navRate";
type FundSort = { key: SortKey; direction: 1 | -1 };

const ICONS = {
  all: "M6 21V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v17l-6-5z",
  holding: "M19 7V4L4 8m15 3V8H4a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h15v-5m2-4h-5a2 2 0 0 0 0 4h5z",
  macd: "M2 12h4l2-8 4 16 3-12 2 4h5",
  red: "M2 5h20v14H2z M5 8h14v8H5z M14 12a2 4 0 1 1-4 0 2 4 0 1 1 4 0",
  market: "M3 21h18M5 17v-6h2v6zm6 0V5h2v12zm6 0V8h2v9z",
  futures: "M2 12h2l2-5 2 10 2-15 2 20 2-16 2 12 2-9 2 3h2",
  settings: "M3 6h10m4 0h4M3 12h4m4 0h10M3 18h12m4 0h2M13 4h4v4h-4zM7 10h4v4H7zM15 16h4v4h-4z",
  trend: "M3 3v18h18M5 15l5-5 4 4 7-8m-5 0h5v5",
  refresh: "M20 7a9 9 0 1 0 1 8M20 2v6h-6",
  add: "M12 4v16M4 12h16",
  search: "M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0zm-2 5 6 6",
  columns: "M3 5h18v14H3zM3 10h18M3 14h18M11 5v14",
  transfer: "M12 3v12m-4-4 4 4 4-4M6 8H4v12h16V8h-2",
  money: "M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0ZM8 7l4 5 4-5m-4 5v5m-3-5h6m-6 3h6",
  wifi: "M2 8.8a15.5 15.5 0 0 1 20 0M5 12.2a11 11 0 0 1 14 0M8.5 15.6a6 6 0 0 1 7 0M12 19h.01M12 3v5",
  info: "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 11v6M12 7h.01",
  theme: "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 2v20",
  timer: "M12 22a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 9v5l3 2M9 2h6",
  menuBar: "M3 4h18v16H3zM7 8h4v8H7zM14 8h3M14 12h3M14 16h3"
};

function Icon({ name }: { name: keyof typeof ICONS }) {
  return <svg className="ui-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75"
    strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={ICONS[name]} /></svg>;
}

const SECTIONS: { id: Section; label: string }[] = [
  { id: "all", label: "全部自选" },
  { id: "holding", label: "我的持仓" },
  { id: "macd", label: "MACD 观察" },
  { id: "red", label: "红利观察" },
  { id: "market", label: "行情中心" },
  { id: "futures", label: "期货" },
  { id: "settings", label: "设置" }
];

const SORTABLE: { key: SortKey; label: string }[] = [
  { key: "estimateRate", label: "估算涨跌" },
  { key: "dayProfit", label: "日收益" },
  { key: "value", label: "持有金额" },
  { key: "profit", label: "持有收益" },
  { key: "profitRate", label: "持有收益率" },
  { key: "navRate", label: "披露涨跌" }
];

function applyTheme(theme: string) {
  const root = document.documentElement;
  if (theme === "system") {
    delete root.dataset.theme;
  } else {
    root.dataset.theme = theme;
  }
}

const sortValue = (row: FundRow, key: SortKey): number => {
  const value = row[key];
  return value == null || !Number.isFinite(value) ? Number.NEGATIVE_INFINITY : value;
};

function fundMatches(row: FundRow, query: string) {
  const normalized = query.replace(/\s+/g, "").toUpperCase();
  if (!normalized) return true;
  return row.code.includes(normalized) || row.name.toUpperCase().includes(normalized);
}

function tone(value?: number) {
  if (value == null || value === 0) return "flat";
  return value > 0 ? "up" : "down";
}

function formatYuan(value?: number, signed = false) {
  const amount = signed ? formatSigned(value) : formatMoney(value);
  return amount === "—" ? amount : amount.replace(/^([+−-]?)/, "$1¥");
}

function ChangeText({ value, digits = 2 }: { value?: number; digits?: number }) {
  return <span className={`num ${tone(value)}`}>{formatPercent(value, digits)}</span>;
}

function IndexStrip({
  indices, checkedAt, refreshing, onRefresh, onSelect, selectedIndex
}: {
  indices: IndexQuote[];
  checkedAt: string;
  refreshing: boolean;
  onRefresh: () => void;
  onSelect: (code: string) => void;
  selectedIndex?: string | null;
}) {
  return (
    <section className="panel index-panel">
      <header className="index-heading">
        <h2><Icon name="trend" />市场指数</h2>
        {checkedAt && <time>获取于 {checkedAt}</time>}
        <button className="icon" aria-label="刷新市场指数" title="刷新市场指数" disabled={refreshing} onClick={onRefresh}>
          <Icon name="refresh" />
        </button>
      </header>
      <div className={`index-strip ${indices.length ? "" : "placeholder"}`}>
        {indices.length === 0 && (refreshing ? "指数行情加载中…" : "暂无指数行情")}
        {indices.map((quote) => (
          <button className={`index-card ${tone(quote.rate)} ${selectedIndex === quote.index ? "active" : ""}`} aria-pressed={selectedIndex === undefined ? undefined : selectedIndex === quote.index} key={quote.index} onClick={() => onSelect(quote.index)}>
            <span className="index-name">{indexTitle(quote.index)} <b aria-hidden="true">{quote.rate > 0 ? "↗" : quote.rate < 0 ? "↘" : "–"}</b></span>
            <strong>{formatMoney(quote.value)}</strong>
            <span className="index-change">
              <b>{formatPercent(quote.rate)}</b><span>{formatSigned(quote.change)}</span>
            </span>
            <time>{quote.timestamp.slice(5, 16)}{quote.index.startsWith("us") ? " 美东" : ""}</time>
          </button>
        ))}
      </div>
    </section>
  );
}

function SummaryCards({ board }: { board: BoardView }) {
  const { summary } = board;
  return (
    <section aria-label="全部持仓汇总">
      <h2 className="summary-heading">全部持仓汇总</h2>
      <div className="summary">
        <div className="summary-card primary">
          <span><Icon name="money" />持有金额</span>
          <strong>{formatYuan(summary.value)}</strong>
          <em>
            {summary.missingCount > 0 ? `${summary.missingCount} 只待更新` : "按最近正式净值"}
          </em>
        </div>
        <div className="summary-card">
          <span><Icon name="macd" />当日收益</span>
          <strong className={tone(summary.dayProfit)}>
            {formatYuan(summary.dayProfit, true)}
            <Icon name="info" />
          </strong>
          <em title={summary.exclusions.map((item) => `${item.reason} ${item.count}`).join(" · ") || undefined}>
            已披露 {summary.publishedCount} · 估算 {summary.estimatedCount} · 覆盖{" "}
            {summary.coveredCount}/{summary.holdingCount} 只
          </em>
        </div>
        <div className="summary-card">
          <span><Icon name="trend" />持有收益</span>
          <strong className={tone(summary.profit)}>{formatYuan(summary.profit, true)}</strong>
          <em>已填写成本的持仓</em>
        </div>
      </div>
    </section>
  );
}

function AddFundModal({
  existing,
  group,
  onClose,
  onAdded
}: {
  existing: Map<string, string[]>;
  group: "macd" | "red" | null;
  onClose: () => void;
  onAdded: (view: BoardView, fund: { code: string; name: string }) => void;
}) {
  const [keyword, setKeyword] = useState("");
  const [results, setResults] = useState<{ code: string; name: string; kind: string }[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const searchId = useRef(0);

  useEffect(() => {
    const request = ++searchId.current;
    if (!keyword.trim()) {
      setResults([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    const handle = window.setTimeout(() => {
      api
        .searchFunds(keyword.trim())
        .then((funds) => {
          if (request === searchId.current) {
            setResults(funds);
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

  const groupTitle = group === "macd" ? "MACD 观察" : "红利观察";
  const membership = (code: string) => {
    const groups = existing.get(code);
    return groups ? (group ? groups.includes(group) : true) : false;
  };
  const actionLabel = (code: string) => {
    if (!existing.has(code)) return group ? `加入${groupTitle}` : "添加";
    if (membership(code)) return "已添加";
    return group ? `加入${groupTitle}` : "已添加";
  };

  const add = async (code: string) => {
    try {
      const view = await api.addFund(code, group);
      const fund = view.rows.find((row) => row.code === code);
      onAdded(view, { code, name: fund?.name || code });
      onClose();
    } catch (reason) {
      setError(String(reason));
    }
  };

  const codeQuery = /^\d{6}$/.test(keyword.trim()) ? keyword.trim() : "";
  const codeAlreadyMember = Boolean(codeQuery) && existing.has(codeQuery) && membership(codeQuery);
  const showCodeFallback =
    Boolean(codeQuery) &&
    !loading &&
    results.length === 0 &&
    !codeAlreadyMember;

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal add-modal" onClick={(event) => event.stopPropagation()}>
        <header className="sheet-head">
          <h2>添加基金</h2>
          <button className="sheet-done" onClick={onClose}>完成</button>
        </header>
        <input
          autoFocus
          className="search"
          placeholder="搜索基金代码、名称或拼音"
          value={keyword}
          onChange={(event) => setKeyword(event.target.value)}
        />
        {loading && <p className="hint">搜索中…</p>}
        {error && <p className="error">{error}</p>}
        {!keyword.trim() && (
          <div className="search-suggestions">
            <p className="hint">也可以直接查找这些公开基金</p>
            <div>
              <button className="ghost small" onClick={() => setKeyword("007339")}>沪深 300 联接 C</button>
              <button className="ghost small" onClick={() => setKeyword("008163")}>南方红利低波联接 A</button>
            </div>
          </div>
        )}
        <div className="search-results">
          {results.map((fund) => (
            <button
              key={fund.code}
              className="search-row"
              disabled={membership(fund.code)}
              onClick={() => void add(fund.code)}
            >
              <span>
                <strong>{fund.name}</strong>
                <em>{fund.code}{fund.kind ? ` · ${fund.kind}` : ""}</em>
              </span>
              <b>{actionLabel(fund.code)}</b>
            </button>
          ))}
          {showCodeFallback && (
            <button className="search-row" onClick={() => void add(codeQuery)}>
              <span>
                <strong>直接添加代码 {codeQuery}</strong>
                <em>未在搜索结果中匹配时仍可先加入看板</em>
              </span>
              <b>{group ? `加入${groupTitle}` : "添加"}</b>
            </button>
          )}
          {!loading && codeAlreadyMember && results.length === 0 && (
            <p className="hint">{codeQuery} {group ? `已在${groupTitle}中` : "已在看板中"}</p>
          )}
          {!loading && keyword && results.length === 0 && !showCodeFallback && !codeAlreadyMember && (
            <p className="hint">没有匹配结果</p>
          )}
        </div>
      </div>
    </div>
  );
}

function ColumnPicker({
  board,
  onChange,
  onError
}: {
  board: BoardView;
  onChange: (view: BoardView) => void;
  onError: (message: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const visible = new Set(board.visibleColumns);

  const save = async (columns: string[]) => {
    setBusy(true);
    try {
      onChange(await api.saveVisibleColumns(columns));
    } catch (reason) {
      onError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="popover-wrap">
      <button className="ghost small" onClick={() => setOpen((value) => !value)}>
        <Icon name="columns" />显示列
      </button>
      {open && (
        <div className="popover">
          <strong>显示列</strong>
          <div className="column-list">
            {board.columns.map((column) => (
              <label key={column} className="check-row">
                <input
                  type="checkbox"
                  checked={column === "name" || visible.has(column)}
                  disabled={column === "name" || busy}
                  onChange={(event) => {
                    const next = new Set(visible);
                    if (event.target.checked) next.add(column);
                    else next.delete(column);
                    void save([...next]);
                  }}
                />
                <span>{COLUMN_TITLES[column] ?? column}</span>
              </label>
            ))}
          </div>
          <button className="link" disabled={busy || visible.size === board.columns.length} onClick={() => void save(board.columns)}>
            显示全部列
          </button>
        </div>
      )}
    </div>
  );
}

function Cell({ row, column }: { row: FundRow; column: string }) {
  switch (column) {
    case "name":
      return (
        <div className="fund-name">
          <strong title={row.name}>{row.name}</strong>
        </div>
      );
    case "code":
      return <span className="code">{row.code}</span>;
    case "estimateRate":
      return <ChangeText value={row.estimateRate} />;
    case "dayProfit":
      return <span className={`num ${tone(row.dayProfit)}`}>{formatYuan(row.dayProfit, true)}</span>;
    case "value":
      return <span className="num">{formatYuan(row.value)}</span>;
    case "profit":
      return <span className={`num ${tone(row.profit)}`}>{formatYuan(row.profit, true)}</span>;
    case "profitRate":
      return <ChangeText value={row.profitRate} />;
    case "estimateTime":
      return <span className="muted num">{row.estimateTime?.slice(0, 5) ?? "—"}</span>;
    case "nav":
      return <span className="num">{row.nav != null ? row.nav.toFixed(4) : "—"}</span>;
    case "navDate":
      return <span className="muted num">{row.navDay?.slice(5) ?? "—"}</span>;
    case "navRate":
      return <ChangeText value={row.navRate} />;
    case "estimate":
      return <span className="num">{row.estimateValue != null ? row.estimateValue.toFixed(4) : "—"}</span>;
  }
}

function FundTable({
  board,
  rows,
  query,
  onQuery,
  sort,
  onSort,
  onChooseSort,
  onSelect,
  onChanged,
  onError,
  group,
  onRemoveFund,
  onRemoveGroup
}: {
  board: BoardView;
  rows: FundRow[];
  query: string;
  onQuery: (query: string) => void;
  sort: FundSort | null;
  onSort: (key: SortKey) => void;
  onChooseSort: (key: SortKey | null) => void;
  onSelect: (code: string) => void;
  onChanged: (view: BoardView) => void;
  onError: (message: string) => void;
  group: "macd" | "red" | null;
  onRemoveFund: (row: FundRow) => void;
  onRemoveGroup: (row: FundRow, group: "macd" | "red") => void;
}) {
  const columns = board.visibleColumns;
  const [dragColumn, setDragColumn] = useState<string | null>(null);
  const [dragCode, setDragCode] = useState<string | null>(null);
  const [dropTarget, setDropTarget] = useState<{ code: string; after: boolean } | null>(null);
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; row: FundRow } | null>(null);

  useEffect(() => {
    if (!contextMenu) return;
    const close = () => setContextMenu(null);
    window.addEventListener("pointerdown", close);
    window.addEventListener("blur", close);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("blur", close);
    };
  }, [contextMenu]);

  const reorder = async (target: string) => {
    if (!dragColumn || dragColumn === target) return;
    const next = columns.filter((column) => column !== dragColumn);
    next.splice(next.indexOf(target), 0, dragColumn);
    setDragColumn(null);
    onChanged(await api.reorderColumns(next));
  };

  const move = async (target: string) => {
    if (!dragCode || !dropTarget || dragCode === target) return;
    const code = dragCode;
    const after = dropTarget.after;
    setDragCode(null);
    setDropTarget(null);
    onChanged(await api.moveFund(code, target, after, rows.map((row) => row.code)));
  };

  return (
    <section className="panel table-panel">
      <div className="table-toolbar">
        <div className="table-title">
          <strong>基金列表</strong>
          <span className="pill">{rows.length}</span>
          <label className="table-search">
            <Icon name="search" />
            <input id="fund-search" type="search" aria-label="查找名称或代码" placeholder="查找名称或代码"
              value={query} onChange={(event) => onQuery(event.target.value)} />
          </label>
        </div>
        <div className="section-actions">
          {sort && (
            <button className="ghost small" onClick={() => onSort(sort.key)}>
              排序：{SORTABLE.find((item) => item.key === sort.key)?.label}
              {sort.direction > 0 ? " ↑" : " ↓"}
            </button>
          )}
          <ColumnPicker board={board} onChange={onChanged} onError={onError} />
          <select
            aria-label="基金排序"
            className="select small"
            value={sort?.key ?? ""}
            onChange={(event) => onChooseSort((event.target.value || null) as SortKey | null)}
          >
            <option value="">添加顺序</option>
            {SORTABLE.map((item) => (
              <option key={item.key} value={item.key}>{item.label}</option>
            ))}
          </select>
        </div>
      </div>
      <div className="table-scroll">
        <table className={`fund-table ${sort ? "sorted" : ""}`}>
          <thead>
            <tr>
              <th className="drag-col" />
              {columns.map((column) => (
                <th
                  key={column}
                  draggable
                  className={["name", "code"].includes(column) ? "left" : "right"}
                  onDragStart={() => setDragColumn(column)}
                  onDragOver={(event) => event.preventDefault()}
                  onDrop={() => void reorder(column).catch((reason) => onError(String(reason)))}
                  onClick={() => {
                    const sortable = SORTABLE.find((item) => item.key === column);
                    if (sortable) onSort(sortable.key);
                  }}
                >
                  {COLUMN_TITLES[column] ?? column}
                  {sort?.key === column && <i>{sort.direction > 0 ? "↑" : "↓"}</i>}
                </th>
              ))}
              <th className="disclosure-col" />
            </tr>
          </thead>
          <tbody>
            {rows.map((row, index) => (
              <tr
                key={row.code}
                className={[
                  index % 2 ? "alternate" : "",
                  dragCode === row.code ? "dragging" : "",
                  dropTarget?.code === row.code ? (dropTarget.after ? "drop-after" : "drop-before") : ""
                ].join(" ")}
                draggable={!sort}
                onDragStart={() => setDragCode(row.code)}
                onDragOver={(event) => {
                  if (!dragCode || sort) return;
                  event.preventDefault();
                  const rect = event.currentTarget.getBoundingClientRect();
                  setDropTarget({ code: row.code, after: event.clientY > rect.top + rect.height / 2 });
                }}
                onDrop={(event) => {
                  event.preventDefault();
                  void move(row.code).catch((reason) => onError(String(reason)));
                }}
                onDragEnd={() => {
                  setDragCode(null);
                  setDropTarget(null);
                }}
                onContextMenu={(event) => {
                  event.preventDefault();
                  setContextMenu({ x: event.clientX, y: event.clientY, row });
                }}
                onClick={() => onSelect(row.code)}
              >
                <td className="drag-col">
                  {!sort && <span className="drag-handle" title="拖动调整顺序">≡</span>}
                </td>
                {columns.map((column) => (
                  <td key={column} className={["name", "code"].includes(column) ? "left" : "right"}>
                    <Cell row={row} column={column} />
                  </td>
                ))}
                <td className="disclosure-col">›</td>
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <div className="empty">没有符合条件的基金</div>}
      </div>
      {contextMenu && (
        <div
          className="row-context-menu"
          style={{ left: contextMenu.x, top: contextMenu.y }}
          onPointerDown={(event) => event.stopPropagation()}
        >
          <button onClick={() => {
            onSelect(contextMenu.row.code);
            setContextMenu(null);
          }}>查看基金详情</button>
          {group ? (
            <button className="danger-text" onClick={() => {
              onRemoveGroup(contextMenu.row, group);
              setContextMenu(null);
            }}>
              移出{group === "macd" ? "MACD 观察" : "红利观察"}
            </button>
          ) : (
            <button className="danger-text" onClick={() => {
              onRemoveFund(contextMenu.row);
              setContextMenu(null);
            }}>移除基金</button>
          )}
        </div>
      )}
    </section>
  );
}

const SETTINGS_TABS: {
  id: "appearance" | "refresh" | "menuBar" | "sources" | "about";
  label: string;
  hint: string;
  icon: keyof typeof ICONS;
}[] = [
  { id: "appearance", label: "外观主题", hint: "界面配色", icon: "theme" },
  { id: "refresh", label: "刷新间隔", hint: "自动检查", icon: "timer" },
  { id: "menuBar", label: "菜单栏", hint: "上证与收益", icon: "menuBar" },
  { id: "sources", label: "数据源", hint: "接口配置", icon: "wifi" },
  { id: "about", label: "关于与免责声明", hint: "使用说明", icon: "info" }
];

type SettingsTab = (typeof SETTINGS_TABS)[number]["id"];

function SettingsDialog({
  board,
  sources,
  onOpenSources,
  onChange,
  onClose
}: {
  board: BoardView;
  sources: DataSourceStatus;
  onOpenSources: () => void;
  onChange: (view: BoardView) => void;
  onClose: () => void;
}) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [tab, setTab] = useState<SettingsTab>("appearance");
  const save = async (theme: string, interval: number) => {
    setSaving(true);
    try {
      const view = await api.saveSettings(theme, interval);
      applyTheme(view.settings.theme);
      onChange(view);
      setError("");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setSaving(false);
    }
  };
  const saveMenuBar = async (visible: boolean, items: MenuBarItem[]) => {
    setSaving(true);
    try {
      const view = await api.saveMenuBar(visible, items);
      onChange(view);
      setError("");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setSaving(false);
    }
  };
  const toggleMenuItem = (item: MenuBarItem) => {
    const current = board.settings.menuBarItems;
    const next = current.includes(item)
      ? current.filter((value) => value !== item)
      : [...current, item];
    void saveMenuBar(board.settings.menuBarVisible, next);
  };
  return (
    <div className="modal-backdrop settings-backdrop" onClick={onClose}>
      <div className="modal settings-modal" onClick={(event) => event.stopPropagation()}>
        <header className="sheet-head">
          <h2>设置</h2>
          <button className="sheet-done" onClick={onClose}>完成</button>
        </header>
        <div className="settings-split">
          <nav className="settings-nav" aria-label="设置分类">
            {SETTINGS_TABS.map((item) => (
              <button
                key={item.id}
                type="button"
                className={tab === item.id ? "active" : ""}
                aria-current={tab === item.id ? "page" : undefined}
                onClick={() => {
                  setTab(item.id);
                  setError("");
                }}
              >
                <span className="settings-nav-icon"><Icon name={item.icon} /></span>
                <span className="settings-nav-text">
                  <strong>{item.label}</strong>
                  <small>{item.hint}</small>
                </span>
              </button>
            ))}
          </nav>
          <div className="settings-pane">
            <div className="settings-pane-body">
              {tab === "appearance" && (
                <section className="settings-card">
                  <h3><span className="settings-icon"><Icon name="theme" /></span>外观主题</h3>
                  <p>手动切换白色或黑色界面；跟随系统会随 macOS 外观自动变化。</p>
                  <div className="segmented settings-segmented">
                    {[
                      ["system", "跟随系统"],
                      ["light", "白色"],
                      ["dark", "黑色"]
                    ].map(([value, label]) => (
                      <button
                        key={value}
                        className={board.settings.theme === value ? "active" : ""}
                        disabled={saving}
                        onClick={() => void save(value, board.settings.refreshInterval)}
                      >
                        {label}
                      </button>
                    ))}
                  </div>
                </section>
              )}
              {tab === "refresh" && (
                <>
                  <section className="settings-card">
                    <h3><span className="settings-icon"><Icon name="timer" /></span>自动刷新间隔</h3>
                    <p>
                      按所选间隔自动检查自选基金。盘中估值会按此周期请求，正式净值仍沿用原有缓存周期，
                      避免重复下载历史数据。
                    </p>
                    <div className="segmented settings-segmented">
                      {[5, 10, 30, 60].map((interval) => (
                        <button
                          key={interval}
                          className={board.settings.refreshInterval === interval ? "active" : ""}
                          disabled={saving}
                          onClick={() => void save(board.settings.theme, interval)}
                        >
                          {interval} 秒
                        </button>
                      ))}
                    </div>
                    <div className="settings-current">
                      <span><b>✓</b> 当前每 {board.settings.refreshInterval} 秒自动检查</span>
                      <em>默认 10 秒</em>
                    </div>
                  </section>
                  <section className="settings-rows">
                    <div><strong>盘中估算</strong><span>每 {board.settings.refreshInterval} 秒检查，交易时段内生效</span></div>
                    <div><strong>正式净值</strong><span>继续使用现有缓存周期，手动刷新可立即检查</span></div>
                    <div><strong>请求保护</strong><span>刷新进行中不会重复发起，失败后会自动退避重试</span></div>
                  </section>
                </>
              )}
              {tab === "menuBar" && (
                <section className="settings-card">
                  <h3><span className="settings-icon"><Icon name="menuBar" /></span>菜单栏信息</h3>
                  <p>
                    macOS 菜单栏显示上证行情和当日持仓收益；Windows 显示在托盘提示中。
                    关闭后菜单栏不再显示该入口，应用图标仍保留在 Dock。
                  </p>
                  <label className="settings-toggle">
                    <span>
                      <strong>显示菜单栏信息</strong>
                      <small>关闭后不再显示上证点数、涨跌幅和持仓收益</small>
                    </span>
                    <input
                      type="checkbox"
                      checked={board.settings.menuBarVisible}
                      disabled={saving}
                      onChange={(event) =>
                        void saveMenuBar(event.target.checked, board.settings.menuBarItems)}
                    />
                  </label>
                  <fieldset
                    className="settings-options"
                    disabled={saving || !board.settings.menuBarVisible}
                  >
                    <legend>显示内容</legend>
                    {([
                      ["points", "上证点数", "当前上证指数点位，如 3555.27"],
                      ["rate", "涨跌幅", "相对昨收的涨跌幅，如 +1.57%"],
                      ["dayProfit", "当日持仓收益", "全部持仓的当日收益，前面加 ¥，如 ¥+123.45"]
                    ] as [MenuBarItem, string, string][]).map(([value, label, hint]) => (
                      <label className="settings-option" key={value}>
                        <input
                          type="checkbox"
                          checked={board.settings.menuBarItems.includes(value)}
                          onChange={() => toggleMenuItem(value)}
                        />
                        <span>
                          <strong>{label}</strong>
                          <small>{hint}</small>
                        </span>
                      </label>
                    ))}
                  </fieldset>
                </section>
              )}
              {tab === "sources" && (
                <section className="settings-card">
                  <h3><span className="settings-icon"><Icon name="wifi" /></span>数据源</h3>
                  <p>
                    {sources.configured
                      ? `已配置：${sources.label || "自定义配置"}`
                      : "尚未配置。行情、净值和估算不会加载，需要先导入数据源地址。"}
                  </p>
                  <div className="section-actions">
                    <button className="ghost small" onClick={onOpenSources}>配置数据源</button>
                    {!sources.configured && <span className="hint">缺少 {sources.missing.length} 项地址</span>}
                  </div>
                </section>
              )}
              {tab === "about" && (
                <section className="settings-card settings-disclaimer">
                  <h3><span className="settings-icon"><Icon name="info" /></span>关于与免责声明</h3>
                  <p>
                    本软件仅供学习和研究使用，不构成任何投资建议或操作依据。行情、净值、估值等数据均来自第三方公开接口，
                    可能存在延迟、缺失、口径差异或错误。本软件不对数据的准确性、完整性和及时性作出保证，亦不承担因使用
                    这些数据而产生的责任。请以基金公司、交易所等官方披露为准，谨慎参考。
                  </p>
                </section>
              )}
              {error && <p className="error">{error}</p>}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function TransferDialog({ onChange, onClose }: { onChange: (view: BoardView) => void; onClose: () => void }) {
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal transfer-modal" onClick={(event) => event.stopPropagation()}>
        <header className="sheet-head">
          <h2>导入与导出</h2>
          <button className="sheet-done" onClick={onClose}>完成</button>
        </header>
        <PluginDataTransfer onChange={onChange} />
      </div>
    </div>
  );
}

export default function App() {
  const [board, setBoard] = useState<BoardView | null>(null);
  const [sourcesStatus, setSourcesStatus] = useState<DataSourceStatus | null>(null);
  const [indices, setIndices] = useState<IndexQuote[]>([]);
  const [indicesCheckedAt, setIndicesCheckedAt] = useState("");
  const [indicesRefreshing, setIndicesRefreshing] = useState(false);
  const requestingIndices = useRef(false);
  const [section, setSection] = useState<Section>("all");
  const [returnSection, setReturnSection] = useState<Section>("all");
  const [selectedIndex, setSelectedIndex] = useState<string | null>(null);
  const [detailCode, setDetailCode] = useState<string | null>(null);
  const [addOpen, setAddOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [transferOpen, setTransferOpen] = useState(false);
  const [dataSourceOpen, setDataSourceOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<FundSort | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const mainRef = useRef<HTMLElement | null>(null);
  const boardScrollTop = useRef(0);
  const tableScrollTop = useRef(0);
  const restoreBoardScroll = useRef(false);

  const openFundDetail = useCallback((code: string) => {
    boardScrollTop.current = mainRef.current?.scrollTop ?? 0;
    tableScrollTop.current = document.querySelector<HTMLElement>(".table-scroll")?.scrollTop ?? 0;
    restoreBoardScroll.current = false;
    setDetailCode(code);
  }, []);

  const closeFundDetail = useCallback(() => {
    restoreBoardScroll.current = true;
    setDetailCode(null);
  }, []);

  useEffect(() => {
    if (detailCode) {
      if (mainRef.current) mainRef.current.scrollTop = 0;
      return;
    }
    if (!restoreBoardScroll.current) return;
    restoreBoardScroll.current = false;
    requestAnimationFrame(() => {
      if (mainRef.current) mainRef.current.scrollTop = boardScrollTop.current;
      const table = document.querySelector<HTMLElement>(".table-scroll");
      if (table) table.scrollTop = tableScrollTop.current;
    });
  }, [detailCode]);

  const updateBoard = useCallback((view: BoardView) => {
    setBoard(view);
    applyTheme(view.settings.theme);
  }, []);

  const fundAdded = useCallback((view: BoardView, fund: { code: string; name: string }) => {
    updateBoard(view);
    const added = view.rows.find((row) => row.code === fund.code);
    const groupLabel = section === "macd" ? "MACD 观察" : section === "red" ? "红利观察" : "";
    const visible =
      section === "all" ||
      (section === "holding" && (added?.shares ?? 0) > 0) ||
      ((section === "macd" || section === "red") && Boolean(added?.groups.includes(section)));
    setNotice(
      groupLabel
        ? `已把 ${fund.name} 加入${groupLabel}`
        : section === "holding"
          ? `已添加 ${fund.name} 到全部自选；填写持仓后会出现在我的持仓`
          : `已添加 ${fund.name}`
    );
    setQuery("");
    if (!visible) setSection("all");
  }, [section, updateBoard]);

  useEffect(() => {
    if (!notice) return;
    const handle = window.setTimeout(() => setNotice(""), 4000);
    return () => window.clearTimeout(handle);
  }, [notice]);

  const refresh = useCallback(async () => {
    setRefreshing(true);
    try {
      const view = await api.refreshBoard();
      updateBoard(view);
      setError("");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setRefreshing(false);
    }
  }, [updateBoard]);

  const updateIndices = useCallback((quotes: IndexQuote[]) => {
    setIndices(quotes);
    setIndicesCheckedAt(new Intl.DateTimeFormat("sv-SE", {
      timeZone: "Asia/Shanghai", dateStyle: "short", timeStyle: "short"
    }).format(new Date()));
  }, []);

  const refreshIndices = useCallback(async () => {
    if (requestingIndices.current) return;
    requestingIndices.current = true;
    setIndicesRefreshing(true);
    try {
      updateIndices(await api.indices());
    } catch {
      // Keep the last successful quotes and their fetch time when the provider is unavailable.
    } finally {
      requestingIndices.current = false;
      setIndicesRefreshing(false);
    }
  }, [updateIndices]);

  useEffect(() => {
    api
      .bootstrap()
      .then((value) => {
        updateBoard(value.board);
        setSourcesStatus(value.sources);
      })
      .catch((reason) => setError(String(reason)));
    void refreshIndices();
  }, [updateBoard, refreshIndices]);

  useEffect(() => {
    const pending = [
      listen<BoardView>("board://updated", (event) => updateBoard(event.payload)),
      listen<IndexQuote[]>("market://indices", (event) => updateIndices(event.payload)),
      listen("app://refresh", () => void refresh())
    ];
    return () => {
      pending.forEach((item) => void item.then((off) => off()));
    };
  }, [refresh, updateBoard, updateIndices]);

  useEffect(() => {
    const id = window.setInterval(() => {
      void refreshIndices();
    }, 60_000);
    return () => window.clearInterval(id);
  }, [refreshIndices]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const modifier = event.metaKey || event.ctrlKey;
      if (!modifier) return;
      if (event.key.toLowerCase() === "n") {
        event.preventDefault();
        setAddOpen(true);
      }
      if (event.key.toLowerCase() === "r") {
        event.preventDefault();
        void refresh();
      }
      if (event.key.toLowerCase() === "f") {
        event.preventDefault();
        document.querySelector<HTMLInputElement>("#fund-search")?.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [refresh]);

  const rows = useMemo(() => {
    if (!board) return [];
    let result = board.rows.filter((row) => fundMatches(row, query));
    if (section === "holding") result = result.filter((row) => (row.shares ?? 0) > 0);
    if (section === "macd") result = result.filter((row) => row.groups.includes("macd"));
    if (section === "red") result = result.filter((row) => row.groups.includes("red"));
    if (!sort) return result;
    return [...result].sort((left, right) => {
      const a = sortValue(left, sort.key);
      const b = sortValue(right, sort.key);
      if (a === Number.NEGATIVE_INFINITY && b !== Number.NEGATIVE_INFINITY) return 1;
      if (b === Number.NEGATIVE_INFINITY && a !== Number.NEGATIVE_INFINITY) return -1;
      return (a - b) * sort.direction;
    });
  }, [board, query, section, sort]);

  const existing = useMemo(
    () => new Map(board?.rows.map((row) => [row.code, row.groups] as const) ?? []),
    [board]
  );
  const counts = board?.counts ?? { all: 0, holding: 0, macd: 0, red: 0 };
  const showBoard = section === "all" || section === "holding" || section === "macd" || section === "red";
  const title = SECTIONS.find((item) => item.id === section)?.label ?? "全部自选";
  const detailRow = board && detailCode ? board.rows.find((row) => row.code === detailCode) : undefined;
  const estimateHealth = board?.summary.estimateHealth;
  const refreshWarning = [
    estimateHealth && estimateHealth.failedCount > 0
      ? `${estimateHealth.failedCount} 只估值刷新失败`
      : "",
    estimateHealth && estimateHealth.staleCount > 0
      ? `${estimateHealth.staleCount} 只估值已超时`
      : ""
  ].filter(Boolean).join(" · ");

  if (!board) {
    return (
      <div className="loading-screen">
        <div className="brand-mark"><Icon name="trend" /></div>
        <p>{error || "正在读取本机数据…"}</p>
      </div>
    );
  }

  return (
    <div className={`app${section === "market" && !detailCode ? " sheet-mode" : ""}`}>
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark"><Icon name="trend" /></span>
          <strong>基金看板</strong>
        </div>
        <nav>
          {SECTIONS.map((item) => {
            const count =
              item.id === "all" ? counts.all :
              item.id === "holding" ? counts.holding :
              item.id === "macd" ? counts.macd :
              item.id === "red" ? counts.red : undefined;
            return (
              <button
                key={item.id}
                className={section === item.id || (item.id === "settings" && settingsOpen) ? "active" : ""}
                aria-current={section === item.id ? "page" : undefined}
                onClick={() => {
                  setDetailCode(null);
                  if (item.id === "settings") {
                    setSettingsOpen(true);
                    return;
                  }
                  if (showBoard) setReturnSection(section);
                  setSection(item.id);
                  if (item.id === "market") setSelectedIndex(null);
                }}
              >
                <Icon name={item.id} />
                <span>{item.label}</span>
                {count !== undefined && <b>{count}</b>}
              </button>
            );
          })}
        </nav>
        <button className="sidebar-transfer" onClick={() => {
          setTransferOpen(true);
        }}><Icon name="transfer" />导入与导出</button>
      </aside>

      <main ref={mainRef} className={`main${showBoard && !detailCode ? " board-main" : ""}${section === "market" ? " market-main" : ""}${detailCode ? " detail-main" : ""}`}>
        {detailCode ? (
          <FundDetail
            code={detailCode}
            row={detailRow}
            tabs={board.detailTabs}
            onTabsChanged={updateBoard}
            onClose={closeFundDetail}
            onChanged={updateBoard}
          />
        ) : (
          <>
        {section !== "market" && section !== "futures" && <header className="topbar">
          <div className="page-heading">
            <h1>{title}</h1>
            <p className="subtitle">
              {new Date().toLocaleDateString("sv-SE", { timeZone: "Asia/Shanghai" })} · 北京时间
            </p>
          </div>
          <div className="topbar-actions">
            {showBoard && (
              <button className="ghost" onClick={() => void refresh()} disabled={refreshing}>
                <Icon name="refresh" />{refreshing ? "刷新中…" : "刷新"}
              </button>
            )}
            {showBoard && <button className="primary" onClick={() => setAddOpen(true)}><Icon name="add" />添加基金</button>}
          </div>
        </header>}

        {error && <div className="banner error">{error}</div>}
        {notice && <div className="banner notice" role="status">{notice}</div>}
        {sourcesStatus && !sourcesStatus.configured && (
          <div className="banner warning data-source-banner">
            <span>
              {sourcesStatus.error
                ? `数据源配置无法读取：${sourcesStatus.error}`
                : "尚未配置数据源，行情、净值和估算不会加载。"}
            </span>
            <button className="ghost small" onClick={() => setDataSourceOpen(true)}>配置数据源</button>
          </div>
        )}
        {showBoard && (
          <>
            <SummaryCards board={board} />
            <IndexStrip
              indices={indices}
              checkedAt={indicesCheckedAt}
              refreshing={indicesRefreshing}
              onRefresh={() => void refreshIndices()}
              onSelect={(code) => {
                setReturnSection(section);
                setSelectedIndex(code);
                setSection("market");
              }}
            />
            <FundTable
              board={board}
              rows={rows}
              query={query}
              onQuery={setQuery}
              sort={sort}
              onSort={(key) =>
                setSort((current) =>
                  current?.key === key
                    ? { key, direction: current.direction > 0 ? -1 : 1 }
                    : { key, direction: -1 }
                )
              }
              onChooseSort={(key) => setSort(key ? { key, direction: -1 } : null)}
              onSelect={openFundDetail}
              onChanged={updateBoard}
              onError={setError}
              group={section === "macd" ? "macd" : section === "red" ? "red" : null}
              onRemoveFund={(row) => {
                if (!window.confirm(`将从自选中移除 ${row.name} 及本地持仓和流水。`)) return;
                api.removeFund(row.code).then(updateBoard).catch((reason) => setError(String(reason)));
              }}
              onRemoveGroup={(row, group) => {
                api
                  .setGroups(row.code, row.groups.filter((item) => item !== group))
                  .then(updateBoard)
                  .catch((reason) => setError(String(reason)));
              }}
            />
            <footer className="table-foot">
              <span
                className={refreshWarning ? "footer-warning" : ""}
                title={estimateHealth
                  ? `估值状态：正常 ${estimateHealth.freshCount} 只，超时 ${estimateHealth.staleCount} 只，刷新失败 ${estimateHealth.failedCount} 只，暂无 ${estimateHealth.missingCount} 只`
                  : undefined}
              >
                {refreshWarning
                  ? <><Icon name="wifi" />{refreshWarning} · 保留上次数据</>
                  : <><Icon name="transfer" />最近检查 {board.updatedAt.slice(11, 16)}</>}
              </span>
              <span className="footer-refresh">每 {board.settings.refreshInterval} 秒自动检查</span>
              <span
                className="footer-disclaimer"
                title="仅供学习和研究使用，不构成投资建议；数据来自第三方公开接口，准确性和完整性不作保证。"
              >
                数据来自公开接口 · 仅供学习参考
              </span>
            </footer>
          </>
        )}

        {section === "market" && (
          <MarketCenter
            selectedIndex={selectedIndex}
            onSelect={setSelectedIndex}
            onBack={() => setSection(returnSection)}
            onRefreshIndices={refreshIndices}
            indicesRefreshing={indicesRefreshing}
            indexStrip={
              <IndexStrip indices={indices} checkedAt={indicesCheckedAt}
                selectedIndex={selectedIndex} onRefresh={() => void refreshIndices()}
                refreshing={indicesRefreshing}
                onSelect={(code) => setSelectedIndex(selectedIndex === code ? null : code)} />
            }
          />
        )}
        {section === "futures" && <FuturesView />}
          </>
        )}
      </main>

      {addOpen && (
        <AddFundModal
          existing={existing}
          group={section === "macd" || section === "red" ? section : null}
          onClose={() => setAddOpen(false)}
          onAdded={fundAdded}
        />
      )}
      {settingsOpen && sourcesStatus && (
        <SettingsDialog
          board={board}
          sources={sourcesStatus}
          onOpenSources={() => {
            setSettingsOpen(false);
            setDataSourceOpen(true);
          }}
          onChange={updateBoard}
          onClose={() => setSettingsOpen(false)}
        />
      )}
      {transferOpen && (
        <TransferDialog onChange={updateBoard} onClose={() => setTransferOpen(false)} />
      )}
      {dataSourceOpen && sourcesStatus && (
        <DataSourceDialog
          status={sourcesStatus}
          onSaved={(next) => {
            setSourcesStatus(next);
            if (next.configured) {
              void refresh();
              void refreshIndices();
            }
          }}
          onClose={() => setDataSourceOpen(false)}
        />
      )}
    </div>
  );
}
