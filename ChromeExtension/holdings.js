import Decimal from "./vendor/decimal.mjs";
import {decimalText, numeric, readJSON} from "./backup.js";
import {localDay, localTime, money, nativeDate} from "./market.js";

Decimal.set({precision: 38, rounding: Decimal.ROUND_HALF_EVEN});
const d = value => new Decimal(value == null ? 0 : decimalText(value));
const encode = value => readJSON(value.toFixed());
export const positive = value => value != null && d(value).isPositive() && !d(value).isZero();

export function entry(value) {
  const clean = value.trim().replaceAll(",", "").replaceAll("，", "");
  if (!clean) return undefined;
  if (!/^[+-]?(?:\d+(?:\.\d+)?|\.\d+)$/.test(clean) || !Number.isFinite(+clean)) {
    throw new Error("请输入有效数值。");
  }
  return encode(new Decimal(clean));
}

function marketMinute(now) {
  const [hour, minute] = localTime(now).split(":").map(Number);
  return hour * 60 + minute;
}
const between = (value, lo, hi) => value >= lo && value <= hi;
export function canPoll(now = new Date()) {
  const weekday = new Date(localDay(now) + "T00:00:00Z").getUTCDay();
  const minute = marketMinute(now);
  return between(weekday,1,5) && (between(minute,550,705) || between(minute,775,975));
}

export function effective(snapshot, now = new Date()) {
  const {estimate, estimateAvailable, history = []} = snapshot;
  if (!estimate || estimateAvailable === false || estimate.marketDay !== localDay(now) ||
      estimate.marketDay <= (history.at(-1)?.day ?? "")) return undefined;
  const minute = marketMinute(now);
  const limit = between(minute,570,690) || between(minute,780,900) ? 25 * 60000 : 9 * 3600000;
  const age = now - nativeDate(estimate.timestamp);
  return between(age, -120000, limit) ? estimate : undefined;
}

export function holdingMetrics(holding, snapshot = {history: []}, now = new Date()) {
  const {history = []} = snapshot;
  const nav = history.at(-1);
  const quote = effective(snapshot, now);
  const result = {quote, nav};
  if (!positive(holding.shares)) return result;
  if (!nav) return {...result, exclusion: "缺少正式净值"};
  const isMoney = money(holding.fund) || nav.annualizedRate != null;
  const unit = isMoney ? d(1) : d(nav.value);
  const shares = d(holding.shares);
  const cost = d(holding.costPerShare);
  result.value = encode(shares.times(unit));
  if (cost.gt(0) && !isMoney) {
    result.profit = encode(unit.minus(cost).times(shares));
    result.profitRate = encode(unit.minus(cost).dividedBy(cost).times(100));
  }
  const day = localDay(now);
  if (isMoney) result.exclusion = "货币基金";
  else if (nav.day === day) {
    const previous = history.at(-2);
    if (nav.rate != null && previous && previous.day < nav.day && previous.annualizedRate == null) {
      result.published = encode(d(previous.value).times(d(nav.rate)).times(shares).dividedBy(100));
    } else result.exclusion = "已披露，缺少涨跌幅或前一净值";
  } else if (snapshot.estimate && snapshot.estimate.marketDay !== day) result.exclusion = "估值归属其他交易日";
  else if (quote && quote.baseDay === nav.day) result.estimated = encode(d(quote.value).minus(d(nav.value)).times(shares));
  else if (quote) result.exclusion = "估值基准日与正式净值日不一致";
  else result.exclusion = !snapshot.estimate || snapshot.estimateAvailable === false ? "暂无可用估值" : "估值时间超出有效范围";
  return result;
}

export function portfolio(board, now = new Date()) {
  const totals = {count:0, covered:0, publishedCount:0, estimatedCount:0, exclusions:{}};
  for (const holding of board.holdings) {
    if (!positive(holding.shares)) continue;
    totals.count++;
    const m = holdingMetrics(holding, board.snapshots[holding.fund.code], now);
    for (const key of ["value","profit","published","estimated"]) {
      if (m[key] != null) totals[key] = encode(d(totals[key]).plus(d(m[key])));
    }
    if (m.published != null) totals.publishedCount++;
    if (m.estimated != null) totals.estimatedCount++;
    if (m.exclusion) totals.exclusions[m.exclusion] = (totals.exclusions[m.exclusion] ?? 0) + 1;
  }
  totals.covered = totals.publishedCount + totals.estimatedCount;
  if (totals.covered) totals.dayProfit = encode(d(totals.published).plus(d(totals.estimated)));
  return totals;
}

export const actions = ["申购 / 加仓", "赎回 / 减仓", "现金分红"];

function apply(holding, input) {
  const {action, day} = input;
  const fee = d(input.fee);
  const shares = d(input.shares);
  const price = d(input.price);
  const balance = d(holding.shares);
  const unitCost = holding.costPerShare == null ? undefined : d(holding.costPerShare);
  const result = {...holding};
  let cash, realized;
  if (!actions.includes(action) || day > localDay() || !/^\d{4}-\d\d-\d\d$/.test(day) ||
      localDay(new Date(day + "T00:00:00+08:00")) !== day || fee.lt(0)) throw new Error("请核对日期、份额、净值和费用。");
  if (action === actions[2]) {
    cash = d(input.distribution ?? input.cash);
    if (cash.lte(0)) throw new Error("请输入有效的分红金额。");
    realized = cash;
  } else {
    if (shares.lte(0) || price.lte(0)) throw new Error("份额和净值必须大于零。");
    const gross = shares.times(price);
    if (action === actions[0]) {
      if (balance.gt(0) && !unitCost && !money(holding.fund)) throw new Error("请先填写现有持仓的单位成本。");
      cash = gross.plus(fee).negated();
      result.shares = encode(balance.plus(shares));
      result.costPerShare = money(holding.fund) ? undefined : encode(d(holding.costPerShare).times(balance).minus(cash).dividedBy(d(result.shares)));
    } else {
      if (shares.gt(balance) || fee.gt(gross)) throw new Error("赎回份额或费用超出可用金额。");
      cash = gross.minus(fee);
      realized = unitCost && cash.minus(unitCost.times(shares));
      result.shares = encode(balance.minus(shares));
      if (balance.eq(shares)) result.costPerShare = undefined;
    }
  }
  return {holding: result, record: {
    id: input.id ?? crypto.randomUUID(), action, day,
    shares: action === actions[2] ? undefined : encode(shares), price: action === actions[2] ? undefined : encode(price),
    fee: encode(fee), cash: encode(cash), realized: realized == null ? undefined : encode(realized)
  }};
}

function journalBase(holding, records) {
  const base = {...holding};
  for (const record of records.toReversed()) {
    if (record.action === actions[2]) continue;
    const after = d(base.shares);
    const shares = d(record.shares);
    const price = d(record.price);
    if (!positive(record.shares) || (record.action === actions[0] && (!positive(record.price) || d(record.fee).lt(0)))) throw new Error("无法还原原始流水。");
    let before = record.action === actions[0] ? after.minus(shares) : after.plus(shares);
    if (before.lt(0)) throw new Error("无法还原原始持仓。");
    if (record.action === actions[0]) {
      if (before.isZero()) base.costPerShare = undefined;
      else if (!money(base.fund)) {
        const cost = d(base.costPerShare).times(after).minus(shares.times(price).plus(d(record.fee))).dividedBy(before).toDecimalPlaces(8);
        if (cost.lte(0)) throw new Error("无法还原原始持仓成本。");
        base.costPerShare = encode(cost);
      }
    } else if (after.isZero() && record.realized != null && !money(base.fund)) {
      const cost = d(record.cash).minus(d(record.realized)).dividedBy(shares).toDecimalPlaces(8);
      if (cost.lte(0)) throw new Error("无法还原原始持仓成本。");
      base.costPerShare = encode(cost);
    }
    base.shares = encode(before);
  }
  return base;
}

export function changeJournal(board, code, input, id) {
  const index = board.holdings.findIndex(row => row.fund.code === code);
  if (index < 0) throw new Error("基金已从自选移除。");
  const current = board.holdings[index];
  const records = board.journals?.[code] ?? [];
  const journals = {...board.journals};
  let nextHolding, nextRecords;
  if (!id) {
    const {holding, record} = apply(current, input);
    nextHolding = holding;
    nextRecords = [...records, record];
  } else {
    const position = records.findIndex(record => record.id === id);
    if (position < 0) throw new Error("流水记录已不存在。");
    const base = journalBase(current, records);
    nextHolding = base;
    nextRecords = [];
    for (let i = 0; i < records.length; i++) {
      if (i === position && !input) continue;
      const {holding, record} = apply(nextHolding, i === position ? input : records[i]);
      nextHolding = holding;
      nextRecords.push(i === position ? record : records[i]);
    }
  }
  if (nextRecords.length) journals[code] = nextRecords;
  else delete journals[code];
  const holdings = board.holdings.toSpliced(index, 1, nextHolding);
  return {...board, holdings, journals};
}

export const displayNumber = (value, digits = 2) => {
  const number = numeric(value);
  return Number.isFinite(number) ? new Intl.NumberFormat("zh-CN", {minimumFractionDigits: digits, maximumFractionDigits: digits}).format(number) : "—";
};
export const signClass = value => numeric(value) > 0 ? "up" : numeric(value) < 0 ? "down" : "";

export function cumulativeReturns(rows, isMoney) {
  let result = [];
  let amount = d(1);
  let previous;
  for (const row of rows) {
    let fraction;
    if (isMoney) fraction = d(row.value).dividedBy(10000);
    else if (row.rate != null) {
      const disclosed = d(row.rate);
      const base = d(previous?.value);
      const unrounded = base.gt(0) ? d(row.value).minus(base).dividedBy(base) : undefined;
      fraction = unrounded && unrounded.times(100).minus(disclosed).abs().lte("0.0051") ? unrounded : disclosed.dividedBy(100);
    }
    previous = row;
    if (!result.length || !fraction || !fraction.gt(-1)) {
      result = [{time:row.day,value:0}];
      amount = d(1);
    } else {
      amount = amount.times(fraction.plus(1));
      result.push({time:row.day,value:amount.minus(1).times(100).toNumber()});
    }
  }
  return result;
}
