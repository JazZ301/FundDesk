import {aggregate, futuresDaily, futuresFive, futuresIntraday, futuresQuotes, futuresSession, indexTrend, instruments,
  marketBreadth, marketFlows, sectorNames, sectorPeriods, sectors} from "./market.js";
import {loadMarket, saveMarket} from "./store.js";
import {displayNumber} from "./holdings.js";
import {button, errorMessage, node, seriesChart, sessionAxis, show, signed, td} from "./ui.js";

export async function withMarket(key, target, fetcher, render) {
  try {
    const cached = await loadMarket(key);
    if (cached) show(target, render(cached.value),node("small",{className:"muted"},"正在更新 · 已显示上次缓存"));
    else show(target,node("p",{className:"muted"},"正在获取行情…"));
    try {
      const value = await fetcher();
      show(target,render(value));
      await saveMarket(key,value);
    } catch (error) {
      show(target,cached && render(cached.value),node("p",{className:"muted"},(cached ? "已显示上次缓存 · " : "") + errorMessage(error)));
    }
  } catch (error) {show(target,node("p",{className:"muted"},errorMessage(error)));}
}

export function showIndex(openDialog,code,title) {
  const body = node("section",{className:"stack"});
  const chart = node("div",{className:"stack"});
  const update = button("刷新",async () => {
    update.disabled = true;
    try {
      await withMarket("trend-" + code,chart,() => indexTrend(code),data => [
        seriesChart(data.points,{reference:data.reference,sessions:sessionAxis(code),volumes:true}),
        node("small",{},data.source + (data.day ? " · " + data.day : ""))
      ]);
    } finally {update.disabled = false;}
  });
  body.append(node("div",{className:"row"},update),chart);
  openDialog(title,body);
  update.click();
}

export function marketPanel(latest) {
  const panel = node("section",{className:"panel stack"});
  const breadth = node("div",{className:"row"});
  const flow = node("div",{className:"stack"});
  const ranking = node("div",{className:"table-wrap"});
  const flowNames = ["主力","小单","中单","大单","超大单"];
  const kind = node("select",{ariaLabel:"资金类别"},flowNames.map((name,i) => node("option",{value:String(i)},name)));
  const category = node("select",{ariaLabel:"板块分类"},Object.keys(sectorNames).map(name => node("option",{value:name},name)));
  const period = node("select",{ariaLabel:"排名周期"},Object.keys(sectorPeriods).map(name => node("option",{value:name},name)));
  const side = node("select",{ariaLabel:"排行方向"},node("option",{value:"in"},"净流入优先"),node("option",{value:"out"},"净流出优先"));
  let currentFlow, currentSectors;
  const renderSectors = value => {
    currentSectors = value;
    const rows = side.value === "in" ? value : value.toReversed();
    const max = Math.max(1,...rows.map(row => Math.abs(row.value)));
    const indicator = row => {
      const bar = node("span",{className:"sector-bar " + (row.value >= 0 ? "up" : "down"),ariaHidden:"true"});
      bar.style.width = Math.round(Math.abs(row.value)/max*100) + "%";
      return node("div",{className:"sector-bar-track"},bar);
    };
    return [grid(["板块","代码","净流入比例","资金净流入（亿元）"],
      rows.map(row => [row.name,row.code,indicator(row),signed(row.value/1e8)])),
      node("small",{},`${rows.length} 个板块 · 东方财富 · 行情时间未提供`)];
  };
  const renderFlow = result => {
    const rows = result.data.map(row => ({time:row.time,value:row.values[+kind.value] / 1e8}));
    return [seriesChart(rows),node("small",{},`东方财富 · ${result.intraday ? "分时" : "日线"} · 亿元 · ${rows.at(-1).time}`)];
  };
  const loadSectors = async () => {
    const key = category.value, duration = period.value;
    const request = node("div");
    show(ranking,request);
    currentSectors = undefined;
    await withMarket(`sector-${key}-${duration}`,request,() => sectors(key,duration),rows => {
      if (!request.isConnected) return [];
      return renderSectors(rows);
    });
  };
  const update = button("刷新本页",async () => {
    update.disabled = true;
    try {
      await Promise.all([
        withMarket("breadth",breadth,() => marketBreadth(latest()),data => [
          node("strong",{},"两市成交额 " + displayNumber(data.turnover / 1e8) + " 亿"),
          node("span",{className:"up"},`涨 ${data.up ?? "—"}`),node("span",{},`平 ${data.flat ?? "—"}`),
          node("span",{className:"down"},`跌 ${data.down ?? "—"}`),node("small",{},(data.time ?? "行情时间未提供") + " · " + data.source)
        ]),
        withMarket("main-flows",flow,marketFlows,result => {currentFlow = result;return renderFlow(result);}),
        loadSectors()
      ]);
    } finally {update.disabled = false;}
  });
  update.dataset.autoload = "1";
  category.onchange = period.onchange = () => void loadSectors();
  side.onchange = () => { if (currentSectors) show(ranking,renderSectors(currentSectors)); };
  kind.onchange = () => {if (currentFlow) show(flow,renderFlow(currentFlow));};
  panel.append(node("div",{className:"row spread"},node("h2",{},"行情中心"),update),breadth,
    node("div",{className:"row"},node("h3",{},"两市资金流向"),kind),flow,
    node("div",{className:"row"},node("h3",{},"板块排行"),category,period,side),ranking);
  const timer = setInterval(() => {
    if (!panel.isConnected) {clearInterval(timer);return;}
    if (!document.hidden) update.click();
  },90000);
  return panel;
}

export function grid(headers, rows) {
  return node("table",{},node("thead",{},node("tr",{},headers.map(value => node("th",{scope:"col"},value)))),
    node("tbody",{},rows.map(row => node("tr",{},row.map(value => td(value))))));
}

export function macdRows(rows) {
  const ema = (prior,value,period) => prior == null ? value : prior + (value - prior) * 2 / (period+1);
  let fast,slow,signal;
  return rows.map(row => {
    fast = ema(fast,row.value,12);
    slow = ema(slow,row.value,26);
    const dif = fast-slow;
    signal = ema(signal,dif,9);
    return {...row,value:2*(dif-signal),dif,dea:signal};
  });
}

function futuresDetail(openDialog,row) {
  const {code} = row;
  const periods = ["分时","五日","日 K","周 K","月 K"];
  const modes = node("div",{className:"row"});
  const target = node("div",{className:"stack"});
  const detail = node("div",{className:"stack"},node("div",{className:"row"},
    node("strong",{className:"quote-value"},displayNumber(row.value)),signed(row.change),signed(row.percent,"%"),node("small",{},row.time)),
    node("small",{},`今开 ${displayNumber(row.open)} · 最高 ${displayNumber(row.high)} · 最低 ${displayNumber(row.low)} · 持仓量 ${displayNumber(row.volume,0)}`),modes,target);
  let selected = periods[0];
  async function load(period) {
    selected = period;
    [...modes.children].forEach(control => control.classList.toggle("active",control.textContent === selected));
    const destination = node("div",{className:"stack"});
    show(target,destination);
    const render = value => {
      const raw = value.points ?? aggregate(value,period).slice(-90);
      const {rows,domain} = period === "分时" ? futuresSession(code,raw) : {rows:raw};
      const indicator = rows.length >= 35 ? macdRows(rows) : [];
      return [seriesChart(rows,{reference:value.reference,candles:period.endsWith("K"),domain}),
        value.daily ? node("small",{},"最近五个日 K · 末点可能尚未收盘") : null,
        indicator.length ? [node("h3",{},"MACD"),seriesChart(indicator,{reference:0,overlays:["dif","dea"],histogram:true,height:142})] : []].flat();
    };
    if (period === "分时") await withMarket("futures-minute-" + code,destination,() => futuresIntraday(code),render);
    else if (period === "五日") await withMarket("futures-five-" + code,destination,() => futuresFive(code,row.time.slice(0,10)),render);
    else await withMarket("futures-day-" + code,destination,() => futuresDaily(code),render);
  }
  modes.append(...periods.map(period => button(period,() => load(period))),button("刷新图表",() => load(selected)));
  openDialog(instruments[code],detail);
  void load(selected);
  let last = Date.now();
  const interval = setInterval(() => {
    if (!detail.isConnected || !detail.closest("dialog")?.open) {clearInterval(interval);return;}
    if (selected === "分时" && !document.hidden && Date.now()-last >= 120000) {
      last = Date.now();
      void load(selected);
    }
  },15000);
}

function sparkline(value,code) {
  const {rows,domain} = futuresSession(code,value.points);
  const width = 88, height = 26;
  const canvas = node("canvas",{width,height,className:"spark",ariaLabel:"期货分钟走势"});
  const ctx = canvas.getContext("2d");
  const values = rows.map(row => row.value);
  const min = Math.min(...values), max = Math.max(...values);
  ctx.strokeStyle = "#368675";
  ctx.lineWidth = 1.3;
  ctx.beginPath();
  rows.forEach((row,i) => {
    const ratio = domain ? (row.axisTime-domain.start)/(domain.end-domain.start) : i/Math.max(1,rows.length-1);
    const x = 1+ratio*(width-2), y = max===min ? height/2 : 2+(max-row.value)/(max-min)*(height-4);
    if (i) ctx.lineTo(x,y);
    else ctx.moveTo(x,y);
  });
  ctx.stroke();
  return canvas;
}

export function futuresPanel(openDialog) {
  const target = node("div",{className:"table-wrap"});
  const order = node("select",{ariaLabel:"期货排序"},["默认顺序","涨跌幅降序","涨跌幅升序"].map(name => node("option",{value:name},name)));
  let rows;
  let trendRequestAt = 0;
  const trends = new Map();
  const pending = new Set();
  const display = data => {
    rows = data;
    const sorted = [...rows];
    if (order.selectedIndex) sorted.sort((a,b) => ((b.percent ?? -Infinity) - (a.percent ?? -Infinity)) * (order.selectedIndex === 1 ? 1 : -1));
    return grid(["品种","分时","最新价","涨跌点","涨跌幅","报价时间（北京）"],
      sorted.map(row => [button(instruments[row.code],() => futuresDetail(openDialog,row),"link"),
        trends.has(row.code) ? sparkline(trends.get(row.code),row.code) : "—", displayNumber(row.value),signed(row.change),signed(row.percent,"%"),row.time]));
  };
  const update = button("刷新期货",async () => {
    update.disabled = true;
    try {
      await withMarket("futures-quotes",target,futuresQuotes,display);
      if (!rows || Date.now()-trendRequestAt < 120000) return;
      trendRequestAt = Date.now();
      const codes = rows.map(row => row.code);
      for (let at=0; at<codes.length && target.isConnected; at+=4) {
        await Promise.all(codes.slice(at,at+4).map(async code => {
          if (pending.has(code)) return;
          pending.add(code);
          try {
            const current = await loadMarket("futures-minute-" + code);
            if (current) trends.set(code,current.value);
            if (!current || Date.now()-current.updatedAt >= 120000) {
              const value = await futuresIntraday(code);
              trends.set(code,value);
              await saveMarket("futures-minute-" + code,value);
            }
          } catch {} finally {pending.delete(code);}
        }));
        if (target.isConnected) show(target,display(rows));
      }
    }
    finally {update.disabled = false;}
  });
  update.dataset.autoload = "1";
  order.onchange = () => {if (rows) show(target,display(rows));};
  const timer = setInterval(() => {
    if (!target.isConnected) {clearInterval(timer);return;}
    if (!document.hidden) update.click();
  },60000);
  return node("section",{className:"panel stack"},node("div",{className:"row spread"},node("h2",{},"期货"),node("div",{className:"row"},order,update)),target);
}
