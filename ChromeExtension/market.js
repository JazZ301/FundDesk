import {endpoints, fetchJSON, fetchText, scriptValue} from "./feeds.js";
import {numeric, validCode} from "./backup.js";

const dateFormat = new Intl.DateTimeFormat("sv-SE", {timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit"});
const timeFormat = new Intl.DateTimeFormat("en-GB", {timeZone: "Asia/Shanghai", hour: "2-digit", minute: "2-digit", second: "2-digit"});
export const localDay = (date = new Date()) => dateFormat.format(date);
export const localTime = date => timeFormat.format(date);
export const swiftTime = (ms = Date.now()) => ms / 1000 - 978307200;
export const nativeDate = value => new Date((numeric(value) + 978307200) * 1000);
export const money = fund => fund.kind.includes("货币");
const crossBorder = fund => /QDII|海外|跨境/i.test(fund.kind) || /QDII/i.test(fund.name);
const num = value => value != null && String(value).trim() && Number.isFinite(Number(value)) ? Number(value) : undefined;
const requireRows = rows => {
  if (!rows?.length) throw new Error("行情来源未返回可用数据");
  return rows;
};

export const indexes = [
  ["sh000001", "上证指数"], ["sh000300", "沪深300"], ["sz399001", "深证成指"],
  ["sz399006", "创业板指"], ["r_hkHSI", "恒生指数"], ["usINX", "标普500", "^GSPC"],
  ["usIXIC", "纳斯达克综合", "^IXIC"]
];

export async function quotes(codes) {
  const text = await fetchText(endpoints.quotes(codes), "gb18030");
  return Object.fromEntries(requireRows([...text.matchAll(/\bv_([a-z0-9_]+)="([^"]+)"/gi)]
    .flatMap(([, code, data]) => {
      const f = data.split("~");
      if (!(num(f[3]) > 0) || num(f[32]) == null) return [];
      const rawTime = f[30];
      const time = rawTime.replace(/^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)$/, "$1-$2-$3 $4:$5:$6").replaceAll("/","-");
      let beijingTime = time;
      if (code.startsWith("us") && !/^\d{14}$/.test(rawTime)) {
        const wall = Date.parse(time.replace(" ","T") + "Z");
        if (Number.isFinite(wall)) {
          const seconds = wall % 60000;
          const when = new Date(exchangeInstant(wall - seconds,"America/New_York") + seconds);
          beijingTime = localDay(when) + " " + localTime(when);
        }
      }
      return [[code, {value: +f[3], change: num(f[31]), percent: +f[32], time, beijingTime, turnover: num(f[35]?.split("/").at(-1))}]];
    })));
}

export async function indexTrend(code) {
  const yahoo = indexes.find(([key]) => key === code)?.[2];
  if (yahoo) {
    try {
      const data = (await fetchJSON(endpoints.yahoo(yahoo))).chart?.result?.[0];
      const rows = data?.indicators?.quote?.[0];
      const clock = new Intl.DateTimeFormat("en-GB", {timeZone:"America/New_York",hour:"2-digit",minute:"2-digit"});
      return {
        reference: data?.meta?.chartPreviousClose ?? data?.meta?.previousClose,
        source: "Yahoo Finance · 美东时间",
        points: requireRows(data?.timestamp?.flatMap((seconds, i) => rows?.close?.[i] == null ? [] : [{
          time: clock.format(new Date(seconds * 1000)), value: rows.close[i], volume: rows.volume?.[i]
        }]))
      };
    } catch { /* Tencent supplies the same US index symbols in markets where Yahoo is unavailable. */ }
  }
  const symbol = code === "r_hkHSI" ? "hkHSI" : code;
  const data = (await fetchJSON(yahoo ? endpoints.usTrend(symbol) : endpoints.trend(symbol))).data?.[symbol];
  let previous = 0;
  const points = requireRows(data?.data?.data?.flatMap(line => {
    const [stamp, value, volume] = line.trim().split(/\s+/);
    if (stamp?.length !== 4 || num(value) == null) return [];
    const cumulative = num(volume);
    const delta = cumulative == null ? undefined : Math.max(0, cumulative - previous);
    if (cumulative != null) previous = cumulative;
    return [{time: stamp.slice(0, 2) + ":" + stamp.slice(2), value: +value, volume: delta}];
  }));
  return {reference: num(data.qt?.[symbol]?.[4]), points, source: yahoo ? "腾讯行情 · 美东时间" : "腾讯行情", day: normalizeDay(data.data.date)};
}

let catalogPromise;
export function catalog() {
  catalogPromise ??= fetchText(endpoints.catalog()).then(source => requireRows(scriptValue(source, "r")).flatMap(
    ([code, initials, name, kind, pinyin]) => validCode(code) ? [{code, initials, name, kind, pinyin}] : []
  )).catch(error => {
    catalogPromise = undefined;
    throw error;
  });
  return catalogPromise;
}

export function matches(fund, query) {
  const word = query.replace(/\s/g, "").toUpperCase();
  return fund.code.startsWith(word) || fund.name.replace(/\s/g, "").toUpperCase().includes(word) ||
    fund.initials.toUpperCase().startsWith(word) || fund.pinyin.toUpperCase().includes(word);
}

export async function fundSearch(query) {
  try {
    const listing = await catalog();
    return listing.filter(fund => matches(fund, query)).slice(0, 30);
  } catch {
    const response = await fetchJSON(endpoints.search(query));
    return (response.Datas ?? []).filter(row => validCode(row.CODE) && row.FundBaseInfo).slice(0, 30).map(row => ({
      code: row.CODE, name: row.NAME, kind: row.FundBaseInfo.FTYPE ?? "", initials: row.JP ?? "", pinyin: ""
    }));
  }
}

export async function fundHistory(fund, limit = 365) {
  const history = await fetchText(endpoints.history(fund.code));
  if (money(fund) || history.includes("var Data_millionCopiesIncome")) {
    const annualized = new Map(scriptValue(history, "Data_sevenDaysYearIncome") ?? []);
    return requireRows(scriptValue(history, "Data_millionCopiesIncome")).slice(-limit).map(([time, value]) => ({
      day: localDay(new Date(time)), value, annualizedRate: annualized.get(time), source: "天天基金"
    }));
  }
  const cumulative = new Map(scriptValue(history, "Data_ACWorthTrend") ?? []);
  return requireRows(scriptValue(history, "Data_netWorthTrend")).slice(-limit).filter(row => row.y > 0).map(row => ({
    day: localDay(new Date(row.x)), value: row.y, rate: num(row.equityReturn),
    cumulativeValue: cumulative.get(row.x), source: "天天基金"
  }));
}

export async function fundNAV(fund, limit = 20) {
  try {
    const {Data} = await fetchJSON(endpoints.nav(fund.code, limit));
    const isMoney = money(fund) || Data?.FundType === "005";
    return requireRows(Data?.LSJZList?.flatMap(row => {
      const value = num(row.DWJZ);
      if (value == null || (!isMoney && value <= 0) || !/^\d{4}-\d\d-\d\d$/.test(row.FSRQ)) return [];
      return [{day: row.FSRQ, value, source: "天天基金", rate: isMoney ? undefined : num(row.JZZZL),
        cumulativeValue: isMoney ? undefined : num(row.LJJZ), annualizedRate: isMoney ? num(row.LJJZ) : undefined}];
    })).sort((a,b) => a.day.localeCompare(b.day));
  } catch {
    return fundHistory(fund, limit);
  }
}

const normalizeDay = value => /^\d{4}-?\d\d-?\d\d$/.test(value ?? "") ?
  value.replace(/-/g, "").replace(/^(\d{4})(\d\d)(\d\d)$/, "$1-$2-$3") : undefined;

export async function fundEstimate(fund) {
  const {result} = await fetchJSON(endpoints.estimate(fund.code));
  const payload = result?.data;
  if (!payload || result.status?.code !== 0) throw new Error("新浪财经暂无估值");
  const baseDay = normalizeDay(payload.worth_date);
  const worth = num(payload.worth);
  const rate = num(payload.worth_rate);
  const nav = baseDay && worth > 0 && !money(fund) ?
    {day: baseDay, value: worth, rate: rate == null ? undefined : rate * 100, source: "新浪财经"} : undefined;
  const series = (payload.networth ?? []).flatMap(row => {
    const day = normalizeDay(row.pre_date);
    const time = row.min_time;
    const ms = Date.parse(day + "T" + (time?.length === 5 ? time + ":00" : time) + "+08:00");
    const value = num(row.pre_nav2);
    const change = num(row.growthrate2);
    if (row.symbol !== fund.code || !Number.isFinite(ms) || !(value > 0) || !(change > -1)) return [];
    const marketDay = crossBorder(fund) && time < "09:00" ? localDay(new Date(ms - 86400000)) : day;
    return [{timestamp: swiftTime(ms), marketDay, baseDay, value, percent: change * 100}];
  }).sort((a,b) => a.timestamp - b.timestamp);
  return {nav, estimate: series.at(-1), series};
}

export function mergeHistory(old = [], rows = []) {
  const byDay = new Map(old.map(row => [row.day, row]));
  for (const row of rows) {
    const previous = byDay.get(row.day);
    if (previous?.source === "天天基金" && row.source === "新浪财经") continue;
    byDay.set(row.day, {...row, cumulativeValue: row.cumulativeValue ?? previous?.cumulativeValue});
  }
  return [...byDay.values()].sort((a,b) => a.day.localeCompare(b.day)).slice(-365);
}

export const sectorNames = {"行业板块": "m:90+s:4", "风格板块": "m:90+e:4", "概念板块": "m:90+t:3", "地域板块": "m:90+t:1"};
export const sectorPeriods = {"今日": "f62", "近5日": "f164", "近10日": "f174"};

export async function sectors(category, period) {
  const field = sectorPeriods[period];
  const response = await fetchJSON(endpoints.sectors(sectorNames[category], field));
  return requireRows(Object.values(response.data?.diff ?? {}).flatMap(row => {
    const value = num(row[field]);
    return value == null || !row.f14 ? [] : [{code: row.f12, name: row.f14, value}];
  })).sort((a,b) => b.value - a.value);
}

export const instruments = {
  VX:"VIX 期货", CL:"纽约原油", OIL:"布伦特原油", GC:"纽约黄金", XAU:"伦敦金（现货 CFD）",
  SI:"纽约白银", HG:"美铜", CAD:"伦铜", CHA50CFD:"富时中国 A50", ES:"标普 500 期货", YM:"道琼斯期货"
};

export async function futuresQuotes() {
  const text = await fetchText(endpoints.futures(Object.keys(instruments)), "gb18030");
  return requireRows([...text.matchAll(/hq_str_hf_(\w+)="([^"]+)"/g)].flatMap(([, code, source]) => {
    const [price, , , , high, low, clock, reference, open, volume, , , day] = source.split(",");
    if (!Object.hasOwn(instruments, code) || num(price) == null || !/^\d{4}-\d\d-\d\d$/.test(day ?? "")) return [];
    const change = num(reference) ? +price - +reference : undefined;
    return [{code, value: +price, change, percent: num(reference) ? change / Math.abs(+reference) * 100 : undefined,
      open: num(open), high: num(high), low: num(low), volume: num(volume), time: day + " " + clock}];
  }));
}

async function east(path, params, decode, hosts = ["push2","push2delay","push2his"]) {
  const results = hosts.map(host => fetchJSON(endpoints.eastQuote(host,path,params)).then(response => decode(response.data,host)));
  try { return await Promise.any(results); }
  catch { throw new Error("东方财富行情暂不可用"); }
}

export async function marketBreadth(latest) {
  try {
    return await east("ulist.np/get", {fltt:2, fields:"f6,f12,f13,f104,f105,f106,f124", secids:"1.000001,0.399001"}, data => {
      const list = Object.values(data?.diff ?? {});
      const a = list.find(item => String(item.f12) === "000001"), b = list.find(item => String(item.f12) === "399001");
      const counts = ["f6","f104","f106","f105"].map(key => [num(a?.[key]),num(b?.[key])]);
      if (counts.some(values => values.some(value => value == null || value < 0))) throw new Error("市场统计缺失");
      const [turnover,up,flat,down] = counts.map(([x,y]) => x+y);
      const times = [num(a.f124),num(b.f124)];
      const time = times.every(value => value > 0) ? new Date(Math.min(...times)*1000) : undefined;
      return {turnover,up,flat,down,time:time ? localDay(time)+" "+localTime(time) : undefined,source:"东方财富"};
    });
  } catch {
    const a = latest.sh000001, b = latest.sz399001;
    if (!Number.isFinite(a?.turnover) || !Number.isFinite(b?.turnover)) throw new Error("市场统计暂不可用");
    return {turnover:a.turnover+b.turnover,
      time:a.time.slice(0,10) === b.time.slice(0,10) ? [a.time,b.time].sort()[0] : undefined,source:"腾讯行情 · 仅成交额"};
  }
}

export async function marketFlows() {
  const base = {secid:"1.000001",secid2:"0.399001",fields1:"f1,f2,f3,f7"};
  for (const intraday of [true,false]) {
    try {
      const path = "stock/fflow/" + (intraday ? "kline/get" : "daykline/get");
      const data = await east(path, {lmt:intraday ? 0 : 20,klt:intraday ? 1 : 101,...base,
        fields2:intraday ? "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63" : "f51,f52,f53,f54,f55,f56"},
      body => requireRows(body?.klines?.flatMap(line => {
        const [time,...rest] = line.split(",");
        const values = rest.slice(0,5).map(num);
        const validTime = intraday ? /^\d{4}-\d\d-\d\d \d\d:\d\d$/.test(time) : /^\d{4}-\d\d-\d\d$/.test(time);
        return validTime && values.length === 5 && values.every(Number.isFinite) ? [{time,values}] : [];
      })),intraday ? undefined : ["push2his","push2"]);
      return {data:data.sort((a,b) => a.time.localeCompare(b.time)),intraday};
    } catch (error) { if (!intraday) throw error; }
  }
}

export async function futuresIntraday(code) {
  const response = await fetchJSON(endpoints.futuresHistory("getGlobalFuturesMinLine",code));
  const records = response.result?.data?.minLine_1d;
  const points = requireRows(records?.flatMap((row,i) => {
    const offset = i ? 0 : 4;
    const value = num(row[offset+1]);
    const time = row[offset+5];
    return value == null || !time ? [] : [{time,value}];
  }));
  return {points:[...new Map(points.map(row => [row.time,row])).values()].sort((a,b) => a.time.localeCompare(b.time)),reference:num(records[0][1])};
}
export async function futuresDaily(code) {
  const response = await fetchJSON(endpoints.futuresHistory("getGlobalFuturesDailyKLine",code));
  return requireRows(response.result?.data?.flatMap(row => {
    const {date} = row;
    const [open,high,low,close] = ["open","high","low","close"].map(key => num(row[key]));
    return date && [open,high,low,close].every(Number.isFinite) && high >= low ? [{time:date,open,high,low,close,value:close}] : [];
  })).sort((a,b) => a.time.localeCompare(b.time));
}
export async function futuresFive(code, day) {
  try {
    const response = await fetchJSON(endpoints.futuresHistory("getGlobalFutures5MLine",code));
    const sessions = response.result?.data?.[code]?.flatMap(rows => {
      const first = rows[0];
      if (first?.length < 4) return [];
      const prices = [first.at(-2),...rows.slice(1).map(row => row[1])].map(num).filter(Number.isFinite);
      return prices.length > 1 ? [{day:first[0],prices,reference:num(first[1])}] : [];
    }) ?? [];
    if (sessions.length >= 5 && sessions.at(-1).day >= (day ?? localDay(new Date(Date.now()-3*86400000)))) {
      const five = sessions.slice(-5);
      return {points:five.flatMap(session => session.prices.map(value => ({time:session.day,value}))),reference:five[0].reference};
    }
  } catch { /* Use the daily source when the five-minute series is unavailable. */ }
  const rows = await futuresDaily(code);
  return {points:rows.slice(-5),reference:rows.at(-6)?.value,daily:true};
}
export function aggregate(candles, period) {
  if (period === "日 K") return candles;
  const buckets = new Map();
  for (const row of candles) {
    const date = new Date(row.time + "T00:00:00Z");
    date.setUTCDate(date.getUTCDate() - (date.getUTCDay()+6)%7);
    const key = period === "周 K" ? date.toISOString().slice(0,10) : row.time.slice(0,7);
    const old = buckets.get(key);
    buckets.set(key, old ? {...row,open:old.open,high:Math.max(old.high,row.high),low:Math.min(old.low,row.low)} : row);
  }
  return [...buckets.values()];
}

const exchangeSessions = {
  OIL:["Europe/London",60,1380],
  CAD:["Europe/London",60,1140],
  CHA50CFD:["Asia/Singapore",1020,990]
};
const exchangeFormatters = new Map();

function zonedParts(ms, zone) {
  if (!exchangeFormatters.has(zone)) exchangeFormatters.set(zone,new Intl.DateTimeFormat("en-GB", {
    timeZone:zone, year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hourCycle:"h23"
  }));
  const parts = Object.fromEntries(exchangeFormatters.get(zone).formatToParts(new Date(ms)).map(part => [part.type,+part.value]));
  return Date.UTC(parts.year,parts.month-1,parts.day,parts.hour,parts.minute);
}

function exchangeInstant(wall, zone) {
  let ms = wall;
  for (let i=0; i<3; i++) ms += wall-zonedParts(ms,zone);
  return ms;
}

export function futuresSession(code, points) {
  const stamp = row => Date.parse(row.time.replace(" ","T") + (row.time.length === 16 ? ":00" : "") + "+08:00");
  const rows = points.map(row => ({...row,axisTime:stamp(row)})).filter(row => Number.isFinite(row.axisTime));
  if (!rows.length) return {rows:points};
  const [zone,opens,closes] = exchangeSessions[code] ?? ["America/New_York",1080,1020];
  const localTimeMs = zonedParts(rows.at(-1).axisTime, zone);
  const day = Math.floor(localTimeMs/86400000)*86400000;
  const minute = 60000;
  for (const offset of [0,-1]) {
    const base = day+offset*86400000;
    const start = exchangeInstant(base+opens*minute,zone);
    const end = exchangeInstant(base+closes*minute+(closes<=opens ? 86400000 : 0),zone);
    const latest = rows.at(-1).axisTime;
    if (latest >= start && latest <= end) {
      return {rows:rows.filter(row => row.axisTime >= start && row.axisTime <= end),domain:{start,end,
        label:localTime(new Date(start)).slice(0,5) + "–" + localTime(new Date(end)).slice(0,5) + " · 北京时间"}};
    }
  }
  return {rows};
}
