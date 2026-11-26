import {validCode} from "./backup.js";
import {scriptValue} from "./feeds.js";
import {displayNumber} from "./holdings.js";
import {localDay,mergeHistory} from "./market.js";

const number = value => value != null && String(value).trim() && Number.isFinite(Number(value)) ? Number(value) : undefined;
const text = value => value == null || String(value).trim() === "" ? undefined : String(value).trim();
const quotes = value => value == null ? undefined : displayNumber(value);
const date = value => /^\d{4}-\d\d-\d\d$/.test(value ?? "") && Number.isFinite(Date.parse(value)) ? value : undefined;
const pct = value => number(value) == null ? undefined : displayNumber(number(value)) + "%";
const fixed = (value,digits) => number(value) == null ? undefined : displayNumber(number(value),digits);
const fund = (row,kind) => ({code:row.code,name:row.name,kind,initials:"",pinyin:""});
const srcMACD = "MACD 本地数据", srcRed = "红利本地数据";

function metricRows(fields) {
  return fields.flatMap(([key,label,value,note]) => value == null || value === "" ? [] : [{key,label,value:String(value),note}]);
}

async function macdRows(files) {
  const html = files.get("基金_MACD战法适配度.html");
  let rows;
  if (html) {
    const raw = await html.text();
    const match = /let DATA = ([\s\S]+?);\r?\nlet NAV_END/.exec(raw);
    if (match) { try { rows = JSON.parse(match[1]); } catch {} }
  }
  if (!Array.isArray(rows) || !rows.length) {
    const json = files.get("data/analysis.json") ?? files.get("data/payload.json");
    rows = json ? JSON.parse(await json.text()) : [];
  }
  if (!Array.isArray(rows)) return [];
  return Promise.all(rows.filter(row => validCode(row?.code) && text(row.name)).map(async row => {
    const file = files.get(`data/fund/${row.code}.js`);
    let history = [], series;
    if (file) {
      const source = await file.text();
      try {
        history = (scriptValue(source,"Data_netWorthTrend") ?? []).slice(-600).flatMap(item =>
          Number.isFinite(item.x) && (item.y > 0) ? [{day:localDay(new Date(item.x)),value:item.y,rate:number(item.equityReturn),source:"天天基金"}] : []
        );
      } catch {}
      try {
        series = (scriptValue(source,"Data_ACWorthTrend") ?? []).slice(-600).flatMap(([ms,val]) =>
          ms > 0 && val > 0 ? [{day:localDay(new Date(ms)),value:val}] : []
        );
      } catch {}
    }
    if (!series?.length && history.length && Array.isArray(row.chart?.v)) {
      const values = row.chart.v.map(number).filter(Number.isFinite).slice(-history.length);
      series = history.slice(history.length-values.length).map((item,i) => ({day:item.day,value:values[i]}));
    }
    const latest = row.nav_last;
    if (!history.length && date(latest?.[0]) && number(latest?.[1]) > 0) {
      history = [{day:latest[0],value:number(latest[1]),source:srcMACD}];
    }
    const backtest = row.bt_all ?? row.bt?.all ?? {};
    const b = row.g;
    const macd = b ? {grade:text(b.grade) ?? "—",score:number(b.score),
      recommendation:({S:"优先适配",A:"适配",B:"有条件适配",C:"不推荐"})[b.grade] ?? "样本或规模不满足",
      fee8:number(row.fee8),reasons:Array.isArray(b.reasons) ? b.reasons.filter(item => typeof item === "string") : []} : undefined;
    return {fund:fund(row,text(row.ftype) ?? ""),group:"macd",history,observation:{
      updatedDay:history.at(-1)?.day ?? "—",source:srcMACD,series:series?.length ? series : undefined,macd,
      metrics:metricRows([
        ["pattern","适配形态",row.pattern],["track","跟踪指数",row.track],["scale","基金规模",row.scale],
        ["ret1y","近一年",pct(row.ret1y)],["vol","年化波动",pct(row.vol)],["er1","效率比 ER(1Y)",fixed(row.er1,3)],
        ["r2","趋势拟合 R²",fixed(row.r2,3)],["mdd","最大回撤",pct(row.mdd)],["pos","当前历史位置",number(row.pos) == null ? undefined : pct(number(row.pos)*100)],
        ["legs","有效波段",fixed(row.legs,0)],["duration","波段中位天数",fixed(row.dur_med,0)],["amp_med","波段平均振幅",pct(row.amp_med)],
        ["strat","策略累计收益",pct(backtest.strat)],["hold","买入持有收益",pct(backtest.hold)],["trades","回测交易",fixed(backtest.n,0)],
        ["win","盈利交易占比",pct(backtest.win)],["profit_factor","盈亏比",fixed(backtest.pf,2)],
        ["mdd","策略最大回撤",pct(backtest.mdd)]
      ])
    }};
  }));
}
async function redRows(files) {
  let dataset;
  if (files.has(".cache.json")) {
    try { dataset = JSON.parse(await files.get(".cache.json").text()); } catch {}
  }
  if (!Array.isArray(dataset?.funds) || !dataset.funds.length) {
    const history = files.get("history.json");
    const rows = history ? JSON.parse(await history.text()) : [];
    dataset = Array.isArray(rows) ? [...rows].sort((a,b) => String(a.date).localeCompare(String(b.date))).at(-1) : undefined;
  }
  return (dataset?.funds ?? []).filter(row => validCode(row?.code) && text(row.name)).map(row => {
    const day = date(row.nav_date), nav = number(row.nav);
    const stats = row.stats ?? {}, rs = row.rs ?? {}, signal = rs.signal ?? {};
    const evaluation = row.eval ?? {}, level = evaluation.level ?? {}, anchors = row.anchor_valuation ?? {};
    const yearly = stats["1y"] ?? {};
    const valuation = number(evaluation.total) == null ? undefined : {
      total:Math.trunc(number(evaluation.total)),maximum:Math.trunc(number(evaluation.max) ?? 8),
      level:text(level.label) ?? "—",levelDescription:text(level.desc),advice:text(level.advice) ?? "",
      anchors:(evaluation.anchors ?? []).flatMap(anchor => {
        if (!text(anchor.key) || !text(anchor.name) || number(anchor.score) == null || !text(anchor.label)) return [];
        return [{key:text(anchor.key),name:text(anchor.name),
          value:number(anchor.value) == null ? "—" : fixed(anchor.value,2)+(text(anchor.unit) ?? ""),
          score:Math.trunc(number(anchor.score)),label:text(anchor.label),rule:text(anchor.rule)}];
      }),
      oneYearPercentile:number(yearly.pct),oneYearHigh:number(yearly.hi),oneYearLow:number(yearly.lo),
      oneYearReturn:number(yearly.ret),fromHigh:number(yearly.from_high),relativeDifference:number(rs.diff),
      relativeLabel:text(signal.label),relativeAdvice:text(signal.advice)
    };
    const valuationPair = key => [fixed(anchors[key],2),pct(anchors[key+"_pct"])].filter(Boolean).join(" / ");
    return {fund:fund(row,"指数型-股票"),group:"red",history:day && nav != null ? [{day,value:nav,rate:number(row.rate),source:srcRed}] : [],
      observation:{source:srcRed,updatedDay:day ?? date((dataset.generated_at ?? dataset.ts)?.slice(0,10)) ?? "—",valuation,
        metrics:metricRows([
          ["track","跟踪指数",row.track],["anchor","估值锚",row.anchor_name],["anchor_mode","锚定方式",row.anchor_mode == null ? undefined : row.anchor_mode === "exact" ? "精确对应" : "代理参照"],
          ["dividend","股息率",pct(anchors.dividend)],["pe","PE / 分位",valuationPair("pe")],["pb","PB / 分位",valuationPair("pb")],
          ["level","估值结论",level.label],["advice","操作提示",level.advice,"来自红利本地模型"],
          ["spread","股债利差",number(evaluation.spread) == null ? undefined : quotes(evaluation.spread) + " 个百分点"],
          ["relative","相对强弱",signal.label,"与本地基准区间收益比较"],
          ["relative_diff","超额收益",number(rs.diff) == null ? undefined : quotes(rs.diff) + " 个百分点"],
          ["stats_1y","近一年涨幅",pct(stats["1y"]?.ret)],["stats_6m","近六月涨幅",pct(stats["6m"]?.ret)],["stats_3m","近三月涨幅",pct(stats["3m"]?.ret)]
        ])
      }};
  });
}

export async function observeFolder(list) {
  const inputs = {macd:new Map(),red:new Map()};
  for (const file of list) {
    const parts = file.webkitRelativePath.split("/");
    const source = parts[0].toLowerCase() in inputs ? 0 : 1;
    const folder = parts[source]?.toLowerCase();
    if (!Object.hasOwn(inputs,folder)) continue;
    const relative = parts.slice(source+1).join("/");
    inputs[folder].set(relative,file);
  }
  if (!inputs.macd.size && !inputs.red.size) throw Error("请选择 macd、red 或包含它们的父文件夹。");
  const attempts = await Promise.allSettled([macdRows(inputs.macd),redRows(inputs.red)]);
  const rows = attempts.flatMap(result => result.value ?? []);
  if (!rows.length) throw Error("文件夹中没有可读取的观察数据。");
  const warnings = ["macd","red"].filter((key,i) => inputs[key].size && !attempts[i].value?.length);
  return {rows,warnings};
}

export function applyObservations(board, rows) {
  const holdings = new Map(board.holdings.map(row => [row.fund.code,row]));
  const observations = {...board.observations}, snapshots = {...board.snapshots};
  for (const item of rows) {
    const {code} = item.fund;
    const existing = holdings.get(code);
    holdings.set(code,{...existing,fund:existing?.fund ?? item.fund,groups:[...new Set([...(existing?.groups ?? []),item.group])]});
    const previous = observations[code];
    const now = item.observation;
    observations[code] = {...previous,...now,
      updatedDay:[previous?.updatedDay,now.updatedDay].filter(value => date(value)).sort().at(-1) ?? "—",
      source:[...new Set([...(previous?.source.split(" + ") ?? []),now.source])].join(" + "),
      series:now.series ?? previous?.series,macd:now.macd ?? previous?.macd,valuation:now.valuation ?? previous?.valuation,
      metrics:[...new Map([...(previous?.metrics ?? []),...now.metrics].map(row => [row.key,row])).values()]};
    const old = snapshots[code];
    if (item.history.length) snapshots[code] = {...old,history:mergeHistory(
      old?.history,item.history.filter(row => !old?.history.some(value => value.day === row.day && value.source === "天天基金"))
    )};
  }
  return {...board,holdings:[...holdings.values()],observations,snapshots};
}
