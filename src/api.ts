import { invoke } from "@tauri-apps/api/core";

export type FundRow = {
  code: string;
  name: string;
  kind: string;
  groups: string[];
  shares?: number;
  cost?: number;
  value?: number;
  profit?: number;
  profitRate?: number;
  nav?: number;
  navDay?: string;
  navRate?: number;
  estimateValue?: number;
  estimateRate?: number;
  estimateTime?: string;
  estimateMarketDay?: string;
  estimateFresh: boolean;
  dayProfit?: number;
  exclusion?: string;
  hasObservation: boolean;
};

export type Exclusion = { reason: string; count: number };
export type EstimateHealth = {
  freshCount: number;
  staleCount: number;
  failedCount: number;
  missingCount: number;
};

export type Summary = {
  value?: number;
  dayProfit?: number;
  estimated?: number;
  published?: number;
  profit?: number;
  holdingCount: number;
  coveredCount: number;
  estimatedCount: number;
  publishedCount: number;
  missingCount: number;
  coverage?: number;
  exclusions: Exclusion[];
  estimateHealth: EstimateHealth;
};

export type MenuBarItem = "points" | "rate" | "dayProfit";

export type BoardView = {
  rows: FundRow[];
  summary: Summary;
  counts: { all: number; holding: number; macd: number; red: number };
  settings: {
    theme: string;
    refreshInterval: number;
    menuBarVisible: boolean;
    menuBarItems: MenuBarItem[];
  };
  columns: string[];
  visibleColumns: string[];
  detailTabs: string[];
  dataDir: string;
  updatedAt: string;
};

export type Bootstrap = {
  board: BoardView;
  platform: string;
  trayMode: string;
  sources: DataSourceStatus;
};

export type DataSourceStatus = {
  configured: boolean;
  path: string;
  label: string;
  missing: string[];
  error?: string;
};

export type IndexQuote = {
  index: string;
  value: number;
  change: number;
  rate: number;
  timestamp: string;
  turnover?: number;
};

export type PlotPoint = { time: number; value: number };

export type IndexTrend = {
  session: {
    time_zone: string;
    time_zone_label: string;
    windows: { start_minute: number; end_minute: number }[];
    axis_marks: { position: number; title: string }[];
  };
  source: string;
  points: PlotPoint[];
  previousClose?: number;
  volumes?: PlotPoint[];
};

export type Nav = {
  day: string;
  value: number;
  rate?: number;
  annualizedRate?: number;
  cumulativeValue?: number;
  source: string;
};

export type Estimate = {
  timestamp: number;
  marketDay: string;
  baseDay?: string;
  value: number;
  percent: number;
};

export type Snapshot = {
  history: Nav[];
  estimate?: Estimate;
  navCheckedAt?: number;
  estimateCheckedAt?: number;
  estimateAvailable?: boolean;
};

export type PeriodResult = {
  period: string;
  rate: number;
  rank?: string;
  sample?: string;
};

export type FundProfile = {
  category?: string;
  company?: string;
  managerNames?: string;
  size?: number;
  cumulativeNav?: number;
  subscription?: string;
  redemption?: string;
  originalFee?: string;
  purchaseFee?: string;
  recent: PeriodResult[];
};

export type DisclosureHolding = {
  code: string;
  name: string;
  type: string;
  weight: number;
  change?: string;
  stockMarket?: string;
};

export type FundDisclosure = {
  reportDay?: string;
  targetCode?: string;
  targetName?: string;
  holdings: DisclosureHolding[];
};

export type FundManager = {
  id: string;
  name: string;
  since?: string;
  education?: string;
  resume?: string;
};

export type ObservationMetric = {
  key: string;
  label: string;
  value: string;
  note?: string;
};

export type ObservationPoint = { day: string; value: number };

export type MacdRating = {
  score?: number;
  grade: string;
  recommendation: string;
  fee8?: number;
  scoreParts?: { label: string; points: number; maximum: number }[];
  reasons: string[];
};

export type ValuationAnchor = {
  key: string;
  name: string;
  value: string;
  score: number;
  label: string;
  rule?: string;
};

export type RedValuation = {
  total: number;
  maximum: number;
  level: string;
  levelDescription?: string;
  advice: string;
  anchors: ValuationAnchor[];
  oneYearPercentile?: number;
  oneYearHigh?: number;
  oneYearLow?: number;
  oneYearReturn?: number;
  fromHigh?: number;
  relativeDifference?: number;
  relativeLabel?: string;
  relativeAdvice?: string;
};

export type FundObservation = {
  updatedDay: string;
  source: string;
  metrics: ObservationMetric[];
  series?: ObservationPoint[];
  macd?: MacdRating;
  valuation?: RedValuation;
};

export type ManagerTenure = {
  name: string;
  since?: string;
  end?: string;
  rate?: number;
};

export type FundDetail = {
  code: string;
  name: string;
  kind: string;
  snapshot: Snapshot;
  history?: {
    navs: Nav[];
    accumulated: PlotPoint[];
    degraded?: boolean;
    degradationNote?: string;
  };
  returns: Record<string, PlotPoint[]>;
  estimateSeries: Estimate[];
  stockQuotes: Record<string, StockQuote>;
  stockQuoteFailed: boolean;
  profile?: FundProfile;
  disclosure?: FundDisclosure;
  managers?: { current: FundManager[]; tenures: ManagerTenure[] };
  observation?: FundObservation;
  errors: string[];
};

export type StockQuote = {
  rate: number;
  time: number;
};

export type MarketBreadth = {
  turnover: number;
  advancing?: number;
  flat?: number;
  declining?: number;
  asOf?: number;
  source: string;
};

export type MarketFlow = {
  time: number;
  main: number;
  small: number;
  medium: number;
  large: number;
  huge: number;
};

export type MarketCenter = {
  breadth?: MarketBreadth;
  flows?: { points: MarketFlow[]; intraday: boolean; source?: string };
  sectors?: { code: string; name: string; amount: number }[];
  errors: string[];
};

export type FuturesQuote = {
  instrument: string;
  title?: string;
  kind?: string;
  builtin?: boolean;
  price: number;
  reference?: number;
  time: number;
  open?: number;
  high?: number;
  low?: number;
  openInterest?: number;
};

export type Candle = {
  day: number;
  open: number;
  high: number;
  low: number;
  close: number;
};

export type FuturesDetail = {
  instrument: string;
  title: string;
  quote?: FuturesQuote;
  intraday?: { reference?: number; points: PlotPoint[]; averages?: PlotPoint[] };
  daily: Candle[];
  weekly: Candle[];
  monthly: Candle[];
  five?: {
    sessions: { day: number; prices: number[] }[];
    isMinuteSeries: boolean;
    reference?: number;
  };
  errors: string[];
};

export type FuturesIntraday = {
  reference?: number;
  points: PlotPoint[];
  averages?: PlotPoint[];
};

export type JournalRecord = {
  id: string;
  action: string;
  day: string;
  shares?: number;
  price?: number;
  fee: number;
  cash: number;
  realized?: number;
};

type PluginImportResult = {
  board: BoardView;
  report: { added: number; updated: number; unchanged: number; invalid: number; conflicts: number };
};

export const api = {
  dataSources: () => invoke<DataSourceStatus>("data_sources"),
  dataSourcesText: () => invoke<string>("data_sources_text"),
  saveDataSources: (text: string) => invoke<DataSourceStatus>("save_data_sources", { text }),
  clearDataSources: () => invoke<DataSourceStatus>("clear_data_sources"),
  readDataSourceFile: () => invoke<string | null>("read_data_source_file"),
  readPluginConfigFile: () => invoke<string | null>("read_plugin_config_file"),
  exportPluginConfigFile: () => invoke<boolean>("export_plugin_config_file"),
  exportPluginConfigText: () => invoke<string>("export_plugin_config_text"),
  importPluginConfig: (text: string, overwrite: boolean) =>
    invoke<PluginImportResult>("import_plugin_config", { text, overwrite }),
  bootstrap: () => invoke<Bootstrap>("bootstrap"),
  refreshBoard: () => invoke<BoardView>("refresh_board"),
  indices: () => invoke<IndexQuote[]>("indices"),
  indexTrend: (index: string) => invoke<IndexTrend>("index_trend", { index }),
  searchFunds: (keyword: string) => invoke<{ code: string; name: string; kind: string }[]>("search_funds", { keyword }),
  addFund: (code: string, group: string | null = null) =>
    invoke<BoardView>("add_fund", { code, group }),
  removeFund: (code: string) => invoke<BoardView>("remove_fund", { code }),
  setHolding: (code: string, shares: number | null, cost: number | null) =>
    invoke<BoardView>("set_holding", { code, shares, cost }),
  saveSettings: (theme: string, interval: number) => invoke<BoardView>("save_settings", { theme, interval }),
  saveMenuBar: (visible: boolean, items: MenuBarItem[]) =>
    invoke<BoardView>("save_menu_bar", { visible, items }),
  saveVisibleColumns: (columns: string[]) => invoke<BoardView>("save_visible_columns", { columns }),
  reorderColumns: (columns: string[]) => invoke<BoardView>("reorder_columns", { columns }),
  moveFund: (code: string, target: string, after: boolean, visible: string[]) =>
    invoke<BoardView>("move_fund", { code, target, after, visible }),
  setGroups: (code: string, groups: string[]) => invoke<BoardView>("set_groups", { code, groups }),
  moveDetailTab: (source: string, target: string) =>
    invoke<BoardView>("move_detail_tab", { source, target }),
  fundDetail: (code: string) => invoke<FundDetail>("fund_detail", { code }),
  fundDisclosure: (code: string) => invoke<FundDisclosure>("fund_disclosure", { code }),
  marketCenter: (category: string, period: string) =>
    invoke<MarketCenter>("market_center", { category, period }),
  futuresQuotes: () => invoke<FuturesQuote[]>("futures_quotes"),
  addFutures: (symbol: string, title: string) =>
    invoke<FuturesQuote[]>("add_futures", { symbol, title }),
  removeFutures: (symbol: string) => invoke<FuturesQuote[]>("remove_futures", { symbol }),
  futuresIntraday: (symbol: string) => invoke<FuturesIntraday>("futures_intraday", { symbol }),
  futuresDetail: (symbol: string) => invoke<FuturesDetail>("futures_detail", { symbol }),
  journalRecords: (code: string) => invoke<JournalRecord[]>("journal_records", { code }),
  addJournal: (payload: {
    code: string;
    action: string;
    day: string;
    shares?: number;
    price?: number;
    fee: number;
    distribution?: number;
  }) => invoke<BoardView>("add_journal", { payload }),
  replaceJournal: (
    id: string,
    payload: {
      code: string;
      action: string;
      day: string;
      shares?: number;
      price?: number;
      fee: number;
      distribution?: number;
    }
  ) => invoke<BoardView>("replace_journal", { id, payload }),
  deleteJournal: (code: string, id: string) => invoke<BoardView>("delete_journal", { code, id })
};

export const SWIFT_EPOCH = 978_307_200;

export const COLUMN_TITLES: Record<string, string> = {
  name: "基金名称",
  estimateRate: "估算涨跌",
  dayProfit: "日收益",
  value: "持有金额",
  profit: "持有收益",
  profitRate: "持有收益率",
  estimateTime: "估值更新",
  code: "代码",
  nav: "净值 / 万份",
  navDate: "净值日",
  navRate: "披露涨跌",
  estimate: "估算净值"
};

export const DETAIL_TITLES: Record<string, string> = {
  estimate: "净值估算",
  history: "历史净值",
  returns: "累计收益",
  holdings: "持仓明细",
  profile: "基金概况",
  observation: "观察数据",
  managers: "基金经理",
  journal: "持仓流水"
};

export const FUTURES_TITLES: Record<string, string> = {
  VX: "VIX 恐慌指数期货",
  CL: "纽约原油",
  OIL: "布伦特原油",
  GC: "纽约黄金",
  XAU: "伦敦金（现货黄金）",
  SI: "纽约白银",
  HG: "美铜",
  CAD: "伦铜",
  CHA50CFD: "富时中国 A50 期货",
  ES: "标普 500 指数期货",
  YM: "道琼斯指数期货"
};

export const FUTURES_ORDER = [
  "VX",
  "CL",
  "OIL",
  "GC",
  "XAU",
  "SI",
  "HG",
  "CAD",
  "CHA50CFD",
  "ES",
  "YM"
];

export const INDEX_TITLES: Record<string, string> = {
  sh000001: "上证指数",
  sh000300: "沪深300",
  sz399001: "深证成指",
  sz399006: "创业板指",
  hkHSI: "恒生指数",
  usINX: "标普500",
  usIXIC: "纳斯达克综合"
};

export function indexTitle(code: string): string {
  return INDEX_TITLES[code] ?? code;
}

export function futuresTitle(instrument: string): string {
  return FUTURES_TITLES[instrument] ?? instrument;
}

export function futuresKind(instrument: string): string {
  return instrument === "XAU" ? "现货报价（CFD）" : "CFD";
}

export function swiftDate(value: number): Date {
  return new Date((value + SWIFT_EPOCH) * 1000);
}

export function formatSwiftTime(value: number, timeZone = "Asia/Shanghai"): string {
  return swiftDate(value).toLocaleTimeString("zh-CN", {
    timeZone,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  });
}

export function formatSwiftDateTime(value: number, timeZone = "Asia/Shanghai"): string {
  return swiftDate(value).toLocaleString("zh-CN", {
    timeZone,
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  });
}

export function formatChinaDateTime(value: number): string {
  const date = new Date((value + SWIFT_EPOCH) * 1000);
  const parts = new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  }).formatToParts(date);
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find((item) => item.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")} ${part("hour")}:${part("minute")}`;
}

export function formatChinaTime(value: number): string {
  return new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Asia/Shanghai",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  }).format(new Date((value + SWIFT_EPOCH) * 1000));
}

export function formatSwiftDay(value: number, timeZone = "Asia/Shanghai"): string {
  return swiftDate(value).toLocaleDateString("zh-CN", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  });
}

export function formatMoney(value?: number, digits = 2): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  return value.toLocaleString("zh-CN", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function formatSigned(value?: number, digits = 2): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  if (value === 0) return formatMoney(0, digits);
  return `${value > 0 ? "+" : "−"}${formatMoney(Math.abs(value), digits)}`;
}

export function formatPercent(value?: number, digits = 2): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  if (value === 0) return `${(0).toFixed(digits)}%`;
  return `${value > 0 ? "+" : "-"}${Math.abs(value).toFixed(digits)}%`;
}
