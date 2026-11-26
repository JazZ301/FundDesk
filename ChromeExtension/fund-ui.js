import {decimalText,numeric,validCode} from "./backup.js";
import {endpoints,fetchJSON} from "./feeds.js";
import {actions,changeJournal,cumulativeReturns,displayNumber,entry,holdingMetrics,positive} from "./holdings.js";
import {groups} from "./imports.js";
import {fundEstimate,fundHistory,fundNAV,fundSearch,localDay,localTime,mergeHistory,money,nativeDate,quotes} from "./market.js";
import {grid,macdRows,withMarket} from "./market-ui.js";
import {button,errorMessage,node,seriesChart,sessionAxis,show,signed} from "./ui.js";

const groupNames = Object.entries(groups);
const tabs = {estimate:"盘中估算",history:"历史净值",returns:"累计收益",holdings:"持仓明细",profile:"基金档案",observation:"观察数据"};
const periodNames = {"近1月":1,"近3月":3,"近6月":6,"近1年":12,"近3年":36,"全部":0};

export function openSearch(context) {
  const {openDialog,edit,currentBoard,refresh} = context;
  const input = node("input",{type:"search",placeholder:"基金代码、名称或拼音",ariaLabel:"搜索基金",required:true});
  const form = node("form",{className:"row"},input,node("button",{type:"submit",className:"primary"},"搜索"));
  const results = node("div",{className:"table-wrap"});
  let cursor = 0;
  form.addEventListener("submit",async event => {
    event.preventDefault();
    const keyword = input.value.trim();
    if (!keyword) return;
    const request = ++cursor;
    show(results,node("p",{className:"muted"},"正在搜索…"));
    try {
      const matches = await fundSearch(keyword);
      if (request !== cursor) return;
      if (!matches.length) {
        show(results,node("p",{className:"empty"},"没有找到基金"));
        return;
      }
      show(results,grid(["名称","代码","类型",""],matches.map(fund => [
        fund.name,fund.code,fund.kind,
        button(currentBoard().holdings.some(row => row.fund.code === fund.code) ? "查看" : "添加",async event => {
          const control = event.currentTarget;
          control.disabled = true;
          try {
            const preliminary = currentBoard().holdings.find(row => row.fund.code === fund.code);
            if (!preliminary) {
              await edit(board => board.holdings.some(row => row.fund.code === fund.code) ? board :
                {...board,holdings:[...board.holdings,{fund}]},"已添加 " + fund.name);
              void refresh();
            }
            openFund(context,fund);
          } catch (error) {show(results,node("p",{className:"muted"},errorMessage(error)));}
          finally {control.disabled = false;}
        })
      ])));
    } catch (error) {
      if (request === cursor) show(results,node("p",{className:"muted"},errorMessage(error)));
    }
  });
  openDialog("添加基金",node("div",{className:"stack"},form,results),true);
  input.focus();
}

function positionEditor(context,fund,back) {
  const {openDialog,edit,currentBoard} = context;
  const holding = currentBoard().holdings.find(row => row.fund.code === fund.code);
  if (!holding) return;
  const sample = currentBoard().snapshots[fund.code];
  const value = field => holding[field] == null ? "" : decimalText(holding[field]);
  const shares = node("input",{type:"text",inputMode:"decimal",value:value("shares"),ariaLabel:"份额"});
  const cost = node("input",{type:"text",inputMode:"decimal",value:value("costPerShare"),ariaLabel:"单位成本"});
  const selected = groupNames.map(([key,name]) => [key,name,node("input",{type:"checkbox",checked:holding.groups?.includes(key) ?? false})]);
  const message = node("output",{ariaLive:"polite"});
  const preview = node("p",{className:"muted"});
  function read() {
    const balance = entry(shares.value), unitCost = entry(cost.value);
    if (balance != null && numeric(balance) < 0) throw new Error("份额不能小于零。");
    if (unitCost != null && !positive(unitCost)) throw new Error("有填写的单位成本必须大于零。");
    return {shares:balance,costPerShare:balance == null ? undefined : unitCost,groups:selected.filter(([, ,input]) => input.checked).map(([key]) => key)};
  }
  function update() {
    try {
      const metrics = holdingMetrics({...holding,...read()},sample);
      preview.textContent = `正式净值 ${displayNumber(metrics.nav?.value,4)} · 持有金额 ${displayNumber(metrics.value)} · 持有收益 ${displayNumber(metrics.profit)}`;
      message.textContent = "";
    } catch (error) {message.textContent = errorMessage(error);}
  }
  shares.oninput = cost.oninput = update;
  const save = node("button",{type:"submit",className:"primary"},"保存");
  const form = node("form",{className:"stack"},node("div",{className:"form"},
    node("label",{},"持有份额",shares),node("label",{},"单位成本（元）",cost)),
    node("div",{className:"row"},selected.map(([,name,input]) => node("label",{className:"inline-check"},input,name))),
    preview,message,node("div",{className:"row"},save,button("返回",back)));
  form.onsubmit = async event => {
    event.preventDefault();
    save.disabled = true;
    try {
      const fields = read();
      await edit(board => ({...board,holdings:board.holdings.map(row => row.fund.code === fund.code ? {...row,...fields} : row)}),"已保存持仓");
      back();
    } catch (error) {message.textContent = errorMessage(error);}
    finally {save.disabled = false;}
  };
  openDialog("编辑持仓",form,true);
  update();
}

function journalEditor(context,fund,record,back) {
  const {openDialog,edit} = context;
  const date = node("input",{type:"date",value:record?.day ?? localDay(),required:true,max:localDay()});
  const type = node("select",{},actions.map(name => node("option",{value:name},name)));
  type.value = record?.action ?? actions[0];
  const input = (field,label) => node("input",{type:"text",inputMode:"decimal",ariaLabel:label,
    value:record?.[field] == null ? "" : decimalText(record[field])});
  const quantity = input("shares","交易份额"), price = input("price","成交净值");
  const fee = input("fee","交易费用"), distribution = input(record?.action === actions[2] ? "cash" : "distribution","分红金额");
  const trade = node("div",{className:"form"},node("label",{},"交易份额",quantity),
    node("label",{},"成交净值",price),node("label",{},"费用（元）",fee));
  const dividend = node("label",{},"分红金额（元）",distribution);
  const switchFields = () => {trade.hidden = type.value === actions[2]; dividend.hidden = !trade.hidden;};
  switchFields();
  type.onchange = switchFields;
  const submit = node("button",{type:"submit",className:"primary"},"保存流水");
  const message = node("output",{ariaLive:"polite"});
  const form = node("form",{className:"stack"},node("div",{className:"form"},node("label",{},"交易类型",type),
    node("label",{},"交易日期（北京）",date)),trade,dividend,message,node("div",{className:"row"},submit,button("返回",back)));
  form.onsubmit = async event => {
    event.preventDefault();
    submit.disabled = true;
    try {
      const cash = type.value === actions[2];
      const change = {action:type.value,day:date.value,
        shares:cash ? undefined : entry(quantity.value),price:cash ? undefined : entry(price.value),
        fee:cash ? 0 : entry(fee.value),distribution:cash ? entry(distribution.value) : undefined};
      await edit(board => changeJournal(board,fund.code,change,record?.id),"已保存流水");
      back();
    } catch (error) {message.textContent = errorMessage(error);}
    finally {submit.disabled = false;}
  };
  openDialog(record ? "修改持仓流水" : "添加持仓流水",form,true);
}

function journal(context,fund,back) {
  const {openDialog,edit,currentBoard} = context;
  const records = currentBoard().journals?.[fund.code] ?? [];
  const message = node("output",{ariaLive:"polite"});
  const again = () => journal(context,fund,back);
  const journalGrid = grid(["交易日期","类型","份额","净值","费用","现金流","已实现收益","操作"],records.toReversed().map(record => [
    record.day,record.action,displayNumber(record.shares,4),displayNumber(record.price,4),
    displayNumber(record.fee),signed(record.cash),signed(record.realized),
    node("div",{className:"row"},button("修改",() => journalEditor(context,fund,record,again)),button("删除",async event => {
      if (!confirm("删除这笔流水并重新计算持仓？")) return;
      event.currentTarget.disabled = true;
      try {
        await edit(board => changeJournal(board,fund.code,undefined,record.id),"已删除流水");
        again();
      } catch (error) {
        message.textContent = errorMessage(error);
        event.target.disabled = false;
      }
    }))
  ]));
  openDialog("持仓流水",node("div",{className:"stack"},
    node("div",{className:"row"},button("添加流水",() => journalEditor(context,fund,undefined,again),"primary"),button("返回",back)),
    records.length ? node("div",{className:"table-wrap"},journalGrid) : node("p",{className:"empty"},"暂无持仓流水"),message));
}

const fundData = (path,code) => fetchJSON(endpoints.fund(path,code));
function recentRange(range, rows, includeBase = false) {
  const months = periodNames[range];
  if (!months || !rows.length) return rows;
  const limit = new Date(rows.at(-1).day + "T12:00:00Z");
  limit.setUTCMonth(limit.getUTCMonth()-months);
  const cutoff = limit.toISOString().slice(0,10);
  if (includeBase) {
    const base = rows.findLastIndex(row => row.day <= cutoff);
    return base < 0 ? rows : rows.slice(base);
  }
  return rows.filter(row => row.day >= cutoff);
}

function historyTab(context,fund,target,returnMode,uiState) {
  const field = returnMode ? "returns" : "history";
  const select = node("select",{ariaLabel:"净值区间"},Object.keys(periodNames).map(name => node("option",{value:name},name)));
  select.value = uiState[field];
  const metric = node("select",{ariaLabel:"净值类型"});
  metric.append(...(money(fund) ? [["value","万份收益"],["annualizedRate","七日年化"]] :
    [["value","单位净值"],["cumulativeValue","累计净值"]]).map(([value,title]) => node("option",{value},title)));
  const graph = node("div",{className:"stack"});
  const display = node("div",{className:"stack"});
  const view = node("div",{className:"stack"},node("div",{className:"row"},select,returnMode ? null : metric),display);
  show(target,view);
  let history = context.currentBoard().snapshots[fund.code]?.history ?? [];
  const render = () => {
    const visible = recentRange(select.value,history);
    const points = returnMode ? cumulativeReturns(recentRange(select.value,history,true),money(fund)) :
      visible.flatMap(row => {
        const value = numeric(row[metric.value]);
        return Number.isFinite(value) ? [{time:row.day,value}] : [];
      });
    return [seriesChart(points),node("small",{},"天天基金 · " + (returnMode ? "所选区间累计收益（%）" : metric.selectedOptions[0].textContent)),
      node("div",{className:"table-wrap"},grid(["日期","单位净值 / 万份","累计净值","披露涨跌 / 七日年化"],
        visible.slice(-20).toReversed().map(row => [row.day,displayNumber(row.value,4),displayNumber(row.cumulativeValue,4),signed(row.rate ?? row.annualizedRate,"%")]))
      )];
  };
  select.onchange = () => {uiState[field] = select.value;show(graph,render());};
  metric.onchange = () => show(graph,render());
  void withMarket("history-" + fund.code,display,async () => {
    const [long,recent] = await Promise.allSettled([fundHistory(fund,10000),fundNAV(fund,60)]);
    if (!long.value && !recent.value) throw Error("历史净值暂不可用");
    return [...new Map([...(long.value ?? []),...(recent.value ?? []).map(row => ({
      ...row,cumulativeValue:row.cumulativeValue ?? long.value?.find(point => point.day === row.day)?.cumulativeValue
    }))].map(row => [row.day,row])).values()].sort((a,b) => a.day.localeCompare(b.day));
  },rows => {
    history = [...new Map([...rows,...history.filter(row => !rows.some(point => point.day === row.day))].map(row => [row.day,row])).values()]
      .sort((a,b) => a.day.localeCompare(b.day));
    show(graph,render());
    return graph;
  });
  if (history.length) {
    show(graph,render());
    show(display,graph);
  }
}

function estimateTab(context,fund,target) {
  if (money(fund)) {show(target,node("p",{className:"muted"},"货币基金以正式披露万份收益和七日年化为准。"));return;}
  void withMarket("fund-estimate-" + fund.code,target,() => fundEstimate(fund), data => {
    const latest = data.estimate;
    const rows = data.series.map(row => ({time:localTime(nativeDate(row.timestamp)).slice(0,5),value:row.value}));
    const overseas = /QDII|海外|跨境/i.test(fund.kind + fund.name);
    return [node("div",{className:"row"},node("strong",{className:"quote-value"},displayNumber(latest?.value,4)),
      signed(latest?.percent,"%"),node("small",{},latest ? `估值时间 ${localDay(nativeDate(latest.timestamp))} ${localTime(nativeDate(latest.timestamp))} · 新浪财经` : "暂无盘中估值")),
      seriesChart(rows,{sessions:overseas ? undefined : sessionAxis("sh000001")})];
  });
}

function stockSymbol(row) {
  const exchange = row.NEWTEXCH == null ? "" : String(row.NEWTEXCH);
  const legacy = row.TEXCH == null ? "" : String(row.TEXCH);
  const markets = {"1":"sh","0":"sz","116":"hk","105":"us","106":"us","107":"us"};
  const fallback = {"1":"sh","0":"sz","2":"sz","4":"bj","5":"hk","7":"us"};
  const prefix = legacy === "4" && (!exchange || exchange === "0") ? "bj" : (exchange ? markets[exchange] : fallback[legacy]);
  const code = String(row.GPDM ?? "").toUpperCase().replaceAll("-",".");
  const symbol = prefix + code;
  return /^(?:(?:sh|sz|bj)\d{6}|hk\d{5}|us[A-Z][A-Z0-9]{0,7}(?:\.[A-Z0-9]{1,4})?)$/.test(symbol) ? symbol : undefined;
}

function disclosureTab(context,fund,target) {
  const areas = new Map();
  const holdingQuotes = {};
  const quoteStatus = node("small",{className:"muted"});
  let updating = false;
  const draw = area => {
    const {display,value} = area;
    show(display,node("small",{},`报告期 ${value.day ?? "—"} · 天天基金`),
      node("div",{className:"table-wrap"},grid(["证券","类型","代码","净值占比","变动","当日涨跌幅"],
        value.rows.map(row => {
          const quote = holdingQuotes[row.symbol];
          const price = signed(quote?.percent,"%");
          if (quote?.beijingTime) price.title = quote.beijingTime + " · 北京时间";
          return [row.name,row.type,row.code,signed(row.ratio,"%"),row.change ?? "—",price];
        }))));
  };
  async function updateQuotes() {
    if (updating || document.hidden) return;
    const codes = [...new Set([...areas.values()].flatMap(area => area.value.rows.map(row => row.symbol).filter(Boolean)))];
    if (!codes.length) return;
    updating = true;
    try {
      const next = {};
      for (let i = 0; i < codes.length; i += 60) Object.assign(next,await quotes(codes.slice(i,i+60)));
      Object.assign(holdingQuotes,next);
      [...areas.values()].forEach(draw);
      const latest = Object.values(next).map(row => row.beijingTime).filter(Boolean).sort().at(-1);
      quoteStatus.textContent = latest ? "腾讯个股行情 · 最新北京时间 " + latest : "腾讯个股行情已更新";
    } catch {quoteStatus.textContent = "部分个股行情暂不可用";}
    finally {updating = false;}
  }
  function showSection(code,withETF) {
    const root = node("section",{className:"stack"});
    void withMarket("disclosure-" + code,root,async () => {
      const source = await fundData("/FundMNewApi/FundMNInverstPosition",code);
      const data = source.Datas;
      if (!data || Array.isArray(data)) throw Error("暂无披露持仓");
      const fields = [["fundStocks","股票","GPDM","GPJC","JZBL"],["fundboods","债券","ZQDM","ZQMC","ZJZBL"],
        ["fundfofs","基金","TZJJDM","TZJJMC","ZJZBL"]];
      return {day:source.Expansion,target:data.ETFCODE,name:data.ETFSHORTNAME,rows:fields.flatMap(([key,type,code,name,weight]) =>
        (data[key] ?? []).map(row => ({type,code:row[code],name:row[name],ratio:Number(row[weight]),
          symbol:key === "fundStocks" ? stockSymbol(row) : undefined,
          change:[row.PCTNVCHGTYPE,row.PCTNVCHG == null ? "" : row.PCTNVCHG + " 个百分点"].filter(Boolean).join(" ")}))
      )};
    },value => {
      const display = node("div",{className:"stack"});
      const area = {display,value};
      areas.set(code,area);
      draw(area);
      void updateQuotes();
      const related = withETF && validCode(value.target) && value.target !== code ? node("details",{},
        node("summary",{},`查看目标 ETF 持仓 · ${value.name || value.target}`)) : null;
      if (related) related.ontoggle = () => {
        if (related.open && related.children.length === 1) related.append(showSection(value.target,false));
        if (!related.open) {areas.delete(value.target);related.children[1]?.remove();}
      };
      return [display,related];
    });
    return root;
  }
  show(target,quoteStatus,showSection(fund.code,true));
  const interval = setInterval(() => {
    if (!target.isConnected || !target.closest("dialog")?.open) {clearInterval(interval);return;}
    void updateQuotes();
  },(context.currentBoard().refreshInterval ?? 10)*1000);
}

function profileTab(fund,target) {
  const profile = node("section",{className:"stack"});
  const managers = node("section",{className:"stack"});
  show(target,profile,managers);
  void withMarket("profile-" + fund.code,profile,async () => {
    const {Datas} = await fundData("/FundMApi/FundBaseTypeInformation.ashx",fund.code);
    if (!Datas?.FCODE) throw Error("基金档案暂不可用");
    return Datas;
  },data => [
    grid(["基金类型","基金公司","现任经理","最新规模","申购","赎回","申购费"],
      [[data.FTYPE ?? "—",data.JJGS ?? "—",data.JJJL ?? "—",data.ENDNAV ?? "—",data.SGZT ?? "—",data.SHZT ?? "—",data.RATE ?? "—"]]),
    grid(["区间","收益率","同类排名"],[["近1月","SYL_Y","RANKM","MSC"],["近3月","SYL_3Y","RANKQ","QSC"],
      ["近6月","SYL_6Y","RANKHY","HYSC"],["近1年","SYL_1N","RANKY","YSC"]]
      .map(([title,key,rank,sample]) => [title,signed(Number(data[key]),"%"),(data[rank] ?? "—") + " / " + (data[sample] ?? "—")]))
  ]);
  void withMarket("managers-" + fund.code,managers,async () => {
    const data = await Promise.allSettled([fundData("/FundMApi/FundMangerDetail.ashx",fund.code),fundData("/FundMApi/FundManagerList.ashx",fund.code)]);
    if (!data.some(row => Array.isArray(row.value?.Datas))) throw Error("经理履历暂不可用");
    return data.map(row => Array.isArray(row.value?.Datas) ? row.value.Datas : []);
  },([current,past]) => [
    node("h3",{},"现任基金经理"),...current.map(row => node("details",{},node("summary",{},`${row.MGRNAME} · ${row.FEMPDATE ?? "—"}`),
      node("p",{},row.EDUCATION ?? ""),node("p",{},row.RESUME ?? ""))),
    node("h3",{},"经理任期"),grid(["名字","开始日期","结束日期","任期收益"],past.map(row => [
      row.MGRNAME ?? "—",row.FEMPDATE ?? "—",row.LEMPDATE ?? "至今",signed(Number(row.PENAVGROWTH),"%")
    ]))
  ]);
}

function observationTab(context,fund,target,holding,uiState) {
  const observed = context.currentBoard().observations?.[fund.code];
  const macd = holding.groups?.includes("macd");
  const red = holding.groups?.includes("red");
  const options = Object.keys(periodNames);
  const span = node("select",{ariaLabel:"观察图表区间"},options.map(value => node("option",{value},value)));
  span.value = uiState.observation;
  const graph = node("div",{className:"stack"});
  let series = observed?.series ?? [];
  const plot = () => {
    const visible = recentRange(span.value,series).map(row => ({time:row.day,value:numeric(row.value)})).filter(row => Number.isFinite(row.value));
    const previousValues = series.map(item => numeric(item.value));
    const dayIndex = new Map(series.map((row,i) => [row.day,i]));
    const average = values => values.reduce((sum,value) => sum+value,0)/values.length;
    const windows = visible.map(row => {
      const i = dayIndex.get(row.time);
      const recent = i >= 249 ? previousValues.slice(i-249,i+1) : [];
      const min = Math.min(...recent), max = Math.max(...recent);
      const percentile = max > min ? Math.min(100,Math.max(0,(row.value-min)/(max-min)*100)) : 50;
      const mean = i >= 59 ? average(previousValues.slice(i-59,i+1)) : undefined;
      const short = i >= 19 ? previousValues.slice(i-19,i+1) : [];
      const center = average(short);
      const gap = Math.sqrt(average(short.map(value => (value-center)**2)))*2;
      return {...row,mean,percentile,low:center-gap,high:center+gap};
    });
    if (!windows.length) {show(graph,node("p",{className:"muted"},"暂无净值观察数据"));return;}
    const last = windows.at(-1);
    const box = previousValues.slice(-250).filter(Number.isFinite);
    const points = series.map(row => ({time:row.day,value:numeric(row.value)}));
    const indicator = macd && points.length >= 35 ? macdRows(points).filter(row => row.time >= visible[0].time) : [];
    const marked = indicator.map((row,i) => {
      const prior = indicator[i-1];
      const signal = prior && prior.value <= 0 && row.value > 0 ? "金叉 · 买入" :
        prior && prior.value >= 0 && row.value < 0 ? "死叉 · 卖出" : undefined;
      return signal ? {...row,signal} : row;
    });
    const current = marked.at(-1);
    const signal = current?.signal ?? (current ? current.value >= 0 ? "红柱 · 持有" : "绿柱 · 空仓" : "");
    show(graph,seriesChart(windows,{overlays:["mean","low","high"],height:210}),
      node("small",{},`MA60 ${displayNumber(last.mean,4)} · 布林下轨 ${displayNumber(last.low,4)} · 上轨 ${displayNumber(last.high,4)} · 箱底 ${displayNumber(Math.min(...box),4)} · 箱顶 ${displayNumber(Math.max(...box),4)} · 当前 ${displayNumber(last.percentile)}%`),
      node("h3",{},"250 日滚动分位"),seriesChart(windows.map(row => ({...row,value:row.percentile})),{height:115}),
      marked.length ? [node("h3",{},"MACD · DIF / DEA"),node("small",{},signal),seriesChart(marked,{reference:0,overlays:["dif","dea"],histogram:true,height:148})] : []);
  };
  span.onchange = () => {uiState.observation = span.value;plot();};
  const stats = [];
  if (macd && observed?.macd) stats.push(node("h3",{},"MACD 适配度"),
    node("p",{},`${observed.macd.grade} · ${observed.macd.recommendation} · ${displayNumber(observed.macd.score)}`),
    ...observed.macd.reasons.map(reason => node("p",{className:"muted"},reason)));
  if (red && observed?.valuation) stats.push(node("h3",{},"红利四锚估值"),
    node("p",{},`${observed.valuation.total} / ${observed.valuation.maximum} · ${observed.valuation.level} · ${observed.valuation.advice}`),
    grid(["估值锚","读数","分数","判断","规则"],observed.valuation.anchors.map(row => [row.name,row.value,String(row.score),row.label,row.rule ?? "—"])));
  const redKeys = new Set(["anchor","anchor_mode","dividend","pe","pb","level","advice","spread","relative","relative_diff","stats_1y","stats_6m","stats_3m"]);
  const metrics = (observed?.metrics ?? []).filter(row => row.key === "track" || (redKeys.has(row.key) ? red : macd));
  if (metrics.length) stats.push(grid(["观察指标","读数","说明"],metrics.map(row => [row.label,row.value,row.note ?? ""])));
  show(target,...stats,node("small",{},observed ? observed.source + " · " + observed.updatedDay : "本地观察数据未导入"),
    node("div",{className:"row"},node("h3",{},"净值区间"),span),graph);
  plot();
  if (!series.length) void fundHistory(fund,1600).then(rows => {
    series = rows.filter(row => row.cumulativeValue != null).map(row => ({day:row.day,value:row.cumulativeValue}));
    plot();
  }).catch(() => {});
}

export function openFund(context,fund) {
  const {openDialog,edit,currentBoard} = context;
  const board = currentBoard();
  const holding = board.holdings.find(row => row.fund.code === fund.code);
  if (!holding) return;
  const all = [...new Set([...(board.fundDetailTabOrder ?? []).filter(key => Object.hasOwn(tabs,key)), ...Object.keys(tabs)])];
  const visible = all.filter(key => key !== "observation" || holding.groups?.length);
  const body = node("div",{className:"stack"});
  const section = node("div",{className:"stack"});
  const bar = node("div",{className:"row"});
  const uiState = {history:"近1年",returns:"近1年",observation:"近1年"};
  let selected = visible[0], source;
  const back = () => openFund(context,fund);
  const update = mode => {
    selected = mode;
    [...bar.children].forEach(control => control.classList.toggle("active",control.dataset.mode === mode));
    const target = node("div",{className:"stack"});
    show(section,target);
    if (mode === "estimate") estimateTab(context,fund,target);
    if (mode === "history" || mode === "returns") historyTab(context,fund,target,mode === "returns",uiState);
    if (mode === "holdings") disclosureTab(context,fund,target);
    if (mode === "profile") profileTab(fund,target);
    if (mode === "observation") observationTab(context,fund,target,holding,uiState);
  };
  for (const mode of visible) {
    const control = button(tabs[mode],() => update(mode));
    control.dataset.mode = mode;
    control.draggable = true;
    control.ondragstart = event => {source = mode;event.dataTransfer.setData("text/plain",mode);};
    control.ondragover = event => event.preventDefault();
    control.ondrop = async event => {
      event.preventDefault();
      if (!source || source === mode) return;
      const next = visible.filter(key => key !== source);
      next.splice(next.indexOf(mode) + Number(event.offsetX > control.clientWidth/2),0,source);
      const queue = [...next];
      try {
        await edit(board => ({...board,fundDetailTabOrder:all.map(key => visible.includes(key) ? queue.shift() : key)}));
        next.forEach(key => bar.append(bar.querySelector(`[data-mode="${key}"]`)));
        visible.splice(0,visible.length,...next);
        all.splice(0,all.length,...currentBoard().fundDetailTabOrder);
      } catch (error) {show(section,node("p",{},errorMessage(error)));}
    };
    bar.append(control);
  }
  const metrics = holdingMetrics(holding,board.snapshots[fund.code]);
  body.append(node("div",{className:"row spread"},
    node("small",{className:"muted"},[fund.code,fund.kind,...(holding.groups ?? []).map(group => groups[group])].filter(Boolean).join(" · ")),
    node("div",{className:"row"},button("编辑持仓",() => positionEditor(context,fund,back)),button("持仓流水",() => journal(context,fund,back)),
      button("移出自选",async event => {
        if (!confirm("将该基金及对应持仓、流水和观察资料移出看板？")) return;
        event.currentTarget.disabled = true;
        try {
          await edit(board => {
            const { [fund.code]: _snapshot,...snapshots} = board.snapshots;
            const { [fund.code]: _journal,...journals} = board.journals ?? {};
            const { [fund.code]: _observation,...observations} = board.observations ?? {};
            return {...board,holdings:board.holdings.filter(row => row.fund.code !== fund.code),snapshots,journals,observations};
          },"已移出 " + fund.name);
          document.querySelector("#detail").close();
        } catch (error) {show(section,node("p",{},errorMessage(error)));event.target.disabled = false;}
      })
    )),node("div",{className:"notice"},`份额 ${displayNumber(holding.shares,4)} · 成本 ${displayNumber(holding.costPerShare,4)} · 持有金额 ${displayNumber(metrics.value)} · 持有收益 ${displayNumber(metrics.profit)} · 当日收益 ${displayNumber(metrics.published ?? metrics.estimated)}`),bar,section);
  openDialog(fund.name,body);
  update(selected);
}
