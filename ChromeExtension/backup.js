const decimalMarker = "$fundDeskDecimal";
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const finite = value => typeof value === "number" && Number.isFinite(value);
const decimalToken = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/;

export function readJSON(source) {
  return JSON.parse(source, (key, value, context) => {
    if (key === decimalMarker) throw new Error("备份中包含保留字段");
    if (typeof value === "number" && context.source !== String(value)) {
      return {[decimalMarker]: context.source};
    }
    return value;
  });
}

export function writeJSON(value) {
  return JSON.stringify(value, (_, item) =>
    object(item) && typeof item[decimalMarker] === "string" ? JSON.rawJSON(item[decimalMarker]) : item
  );
}

export function numeric(value) {
  if (finite(value)) return value;
  if (object(value) && decimalToken.test(value[decimalMarker])) {
    const number = Number(value[decimalMarker]);
    return Number.isFinite(number) ? number : NaN;
  }
  return NaN;
}

export const decimalText = value => object(value) ? value[decimalMarker] : String(value);
export const emptyBoard = () => ({holdings: [], snapshots: {}});
export const validCode = value => typeof value === "string" && /^[0-9]{6}$/.test(value);
const string = value => typeof value === "string";
const day = value => string(value) && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
  Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;

const optional = (value, validate) => value == null || validate(value);
const number = value => Number.isFinite(numeric(value));
const array = (value, validate) => Array.isArray(value) && value.every(validate);
const dictionary = (value, validate) => object(value) && Object.entries(value).every(
  ([key, item]) => validCode(key) && validate(item)
);

function validHolding(holding) {
  return object(holding) && object(holding.fund) && validCode(holding.fund.code) &&
    ["name", "kind", "initials", "pinyin"].every(key => string(holding.fund[key])) &&
    optional(holding.shares, value => numeric(value) >= 0) &&
    optional(holding.costPerShare, value => numeric(value) > 0) &&
    optional(holding.groups, value => array(value, group => ["macd", "red"].includes(group)));
}

function validSnapshot(snapshot) {
  return object(snapshot) && array(snapshot.history, nav =>
    object(nav) && day(nav.day) && number(nav.value) && string(nav.source) &&
    ["rate", "annualizedRate", "cumulativeValue"].every(key => optional(nav[key], number))
  ) && optional(snapshot.estimate, quote =>
    object(quote) && day(quote.marketDay) && optional(quote.baseDay, day) &&
    ["timestamp", "value", "percent"].every(key => number(quote[key]))
  ) && ["navCheckedAt", "estimateCheckedAt"].every(key => optional(snapshot[key], number)) &&
    optional(snapshot.estimateAvailable, value => typeof value === "boolean");
}

function validJournal(records) {
  return array(records, record => object(record) &&
    string(record.id) && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(record.id) &&
    ["申购 / 加仓", "赎回 / 减仓", "现金分红"].includes(record.action) && day(record.day) &&
    number(record.cash) && number(record.fee) &&
    ["shares", "price", "realized"].every(key => optional(record[key], number))
  );
}

function validObservation(observation) {
  return object(observation) && string(observation.updatedDay) && string(observation.source) &&
    array(observation.metrics, metric => object(metric) &&
      ["key", "label", "value"].every(key => string(metric[key])) && optional(metric.note, string)
    ) && optional(observation.series, points => array(points, point =>
      object(point) && day(point.day) && number(point.value)
    )) && optional(observation.macd, object) && optional(observation.valuation, object);
}

export function decodeBackup(source) {
  const data = readJSON(source.replace(/^\uFEFF/, ""));
  if (!object(data) || ![1, 2, 3, 4].includes(data.version)) {
    throw new Error("无法识别备份版本。请选择基金看板导出的 JSON 备份。");
  }
  const board = data.version === 1 ? {
    ...emptyBoard(), holdings: data.holdings, journals: data.journals, observations: data.observations
  } : data.board;
  if (!object(board) || !array(board.holdings, validHolding) ||
      new Set(board.holdings.map(({fund}) => fund.code)).size !== board.holdings.length) {
    throw new Error("备份含有重复基金或无效的基金资料、份额或成本。");
  }
  if (!dictionary(board.snapshots, validSnapshot) ||
      !optional(board.journals, value => dictionary(value, validJournal)) ||
      !optional(board.observations, value => dictionary(value, validObservation)) ||
      !optional(board.refreshInterval, Number.isInteger) ||
      !optional(board.appearanceTheme, string) ||
      !["fundColumnOrder", "hiddenFundColumnIDs", "fundDetailTabOrder"].every(
        key => optional(board[key], value => array(value, string))
      )) {
    throw new Error("备份中的行情、流水、观察数据或设置格式有误。");
  }
  return {version: data.version, board};
}

export function backupPreview(current, incoming) {
  const currentCodes = new Set(current.holdings.map(({fund}) => fund.code));
  const nextCodes = new Set(incoming.holdings.map(({fund}) => fund.code));
  return {
    count: nextCodes.size,
    added: [...nextCodes].filter(code => !currentCodes.has(code)).length,
    replaced: [...nextCodes].filter(code => currentCodes.has(code)).length,
    removed: [...currentCodes].filter(code => !nextCodes.has(code)).length
  };
}

export function exportBackup(board) {
  return writeJSON({version: 4, board});
}

export function exportPortable(board) {
  const observations = board.observations && Object.fromEntries(Object.entries(board.observations).map(
    ([code, observation]) => [code, {...observation, series: undefined}]
  ));
  return writeJSON({version: 3, board:{...board, snapshots:{},observations}});
}
