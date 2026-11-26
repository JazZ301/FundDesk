import {numeric} from "./backup.js";
import {backupPanel} from "./backup-ui.js";
import {openFund, openSearch} from "./fund-ui.js";
import {canPoll, displayNumber, holdingMetrics, portfolio, positive, signClass} from "./holdings.js";
import {groups} from "./imports.js";
import {fundEstimate, fundNAV, indexes, localDay, localTime, matches, mergeHistory, money, nativeDate, quotes, swiftTime} from "./market.js";
import {showIndex, marketPanel, futuresPanel} from "./market-ui.js";
import {loadMarket, loadState, saveMarket, updateState} from "./store.js";
import {button, errorMessage, node, show, signed, td, theme} from "./ui.js";

const $ = selector => document.querySelector(selector);
const nav = $("#navigation");
const content = $("#content");
const dialog = $("#detail");
const status = $("#status");
const refreshButton = $("#refresh");
const tabs = {all:"全部自选", position:"我的持仓", ...groups, market:"行情中心", futures:"期货", settings:"设置"};
const labels = {name:"基金名称", estimateRate:"估算涨跌", dayProfit:"日收益", value:"持有金额", profit:"持有收益",
  profitRate:"持有收益率", estimateTime:"估值更新", code:"代码", nav:"净值 / 万份", navDate:"净值日", navRate:"披露涨跌", estimate:"估算净值"};
const sortKeys = ["estimateRate","dayProfit","value","profit","profitRate","navRate"];
const holdingsTabs = ["all","position","macd","red"];
const boardFilter = {tab:"all", keyword:"", sort:"", direction:-1};
const changes = new BroadcastChannel("funddesk-board");
let state = await loadState();
let marketData = (await loadMarket("index-quotes"))?.value ?? {};
let marketStatus = Object.keys(marketData).length ? "缓存" : "";
let marketAt = 0;
let refreshing;
let timer;
let dragging;

const label = (text, input) => node("label", {className:"row"}, text, input);
const filter = (item, tab) => tab === "all" || (tab === "position" ? positive(item.shares) : item.groups?.includes(tab));
const ordered = (saved, keys) => [...new Set([...(saved ?? []).filter(key => keys.includes(key)),...keys])];

function updateLocal(next, message = "", broadcast = true, redraw = true) {
  state = next;
  theme(next.board);
  if (redraw) render();
  if (message) status.textContent = message;
  if (broadcast) changes.postMessage(next.revision);
}
changes.onmessage = async () => {
  const next = await loadState();
  if (next.revision > state.revision) updateLocal(next,"",false,holdingsTabs.includes(boardFilter.tab));
};
async function edit(transform, message) {
  const next = await updateState(last => ({...last,board:transform(last.board)}));
  updateLocal(next,message);
  return next;
}

function openDialog(title, body, small = false) {
  dialog.className = small ? "small stack" : "stack";
  show(dialog, node("header",{className:"row spread"},node("h2",{id:"dialog-title"},title),
    button("关闭",() => dialog.close())),body);
  if (!dialog.open) dialog.showModal();
}
const currentBoard = () => state.board;

function renderNav() {
  show(nav, ...Object.entries(tabs).flatMap(([key,title]) => {
    const count = holdingsTabs.includes(key) ? state.board.holdings.filter(row => filter(row,key)).length : null;
    const action = button(title,() => {
      boardFilter.tab = key;
      render();
      if (key === "market" || key === "futures") content.querySelector("[data-autoload]")?.click();
    });
    if (count != null) action.append(node("span",{className:"muted"},String(count)));
    if (boardFilter.tab === key) action.setAttribute("aria-current","page");
    return key === "market" || key === "settings" ? [node("hr"),action] : [action];
  }));
}

function renderIndexes() {
  show($("#indexes"), ...indexes.map(([code,title]) => {
    const q = marketData[code];
    const card = button("",() => showIndex(openDialog,code,title),"card");
    card.append(node("strong",{},title),node("span",{className:"quote-value"},displayNumber(q?.value)),
      node("span",{className:"row"},signed(q?.percent,"%"),signed(q?.change)),
      node("small",{},q?.time ? (marketStatus ? marketStatus + " · " : "") + q.time.slice(5) : "等待报价"));
    return card;
  }));
}

function positionSummary(board) {
  const totals = portfolio(board);
  const cards = [["持有金额","value"],["当日收益","dayProfit"],["持有收益","profit"]];
  return node("section",{className:"metrics"},...cards.map(([title,key]) => {
    const children = [node("span",{className:"muted"},title),
      node("strong",{className:"metric-value " + (key === "value" ? "" : signClass(totals[key]))}, displayNumber(totals[key]))];
    if (key !== "dayProfit") return node("div",{className:"card"},children);
    const item = button("",() => {
      const rows = [
        `北京时间 ${localDay()} · 已覆盖 ${totals.covered} / ${totals.count} 只`,
        `已披露收益 ${displayNumber(totals.published)} · ${totals.publishedCount} 只`,
        `待披露估算 ${displayNumber(totals.estimated)} · ${totals.estimatedCount} 只`,
        ...Object.entries(totals.exclusions).map(([reason,count]) => `${reason} · ${count} 只`)
      ];
      openDialog("当日收益明细",node("div",{className:"stack"},rows.map(line => node("p",{},line))),true);
    },"card");
    item.append(...children,node("small",{},`已覆盖 ${totals.covered} / ${totals.count} 只`));
    return item;
  }));
}

function moveVisible(order, visible, source, target, after) {
  const remaining = visible.filter(key => key !== source);
  const at = remaining.indexOf(target);
  if (!visible.includes(source) || at < 0) return order;
  remaining.splice(at + Number(after),0,source);
  const available = new Set(visible);
  return order.map(key => available.has(key) ? remaining.shift() : key);
}
function enableDrop(element, kind, key, handle) {
  element.draggable = true;
  element.addEventListener("dragstart", event => {
    dragging = {kind,key};
    event.dataTransfer.setData("text/plain",key);
    event.dataTransfer.effectAllowed = "move";
    element.classList.add("dragging");
  });
  element.addEventListener("dragend", () => { dragging = undefined; element.classList.remove("dragging"); });
  element.addEventListener("dragover", event => {
    if (dragging?.kind === kind) event.preventDefault();
  });
  element.addEventListener("drop",async event => {
    if (dragging?.kind !== kind || dragging.key === key) return;
    event.preventDefault();
    try { await handle(dragging.key,key,event); }
    catch (error) { status.textContent = errorMessage(error); }
  });
}

function holdingsPanel(board) {
  const section = node("section",{className:"panel stack"});
  const title = tabs[boardFilter.tab];
  const search = node("input",{type:"search",placeholder:"搜索当前列表",value:boardFilter.keyword,ariaLabel:"搜索当前列表"});
  const result = node("div",{className:"table-wrap"});
  const order = ordered(board.fundColumnOrder,Object.keys(labels));
  const visible = order.filter(key => key === "name" || !board.hiddenFundColumnIDs?.includes(key));
  const tools = node("details",{},node("summary",{},"显示列"));
  const checkboxes = node("div",{className:"row"});
  for (const key of order) {
    const input = node("input",{type:"checkbox",checked:visible.includes(key),disabled:key === "name"});
    input.addEventListener("change",async () => {
      try {
        await edit(board => {
          const hidden = new Set(board.hiddenFundColumnIDs ?? []);
          if (input.checked) hidden.delete(key);
          else hidden.add(key);
          return {...board,hiddenFundColumnIDs:[...hidden]};
        });
      } catch (error) { status.textContent = errorMessage(error); }
    });
    checkboxes.append(label(labels[key],input));
  }
  checkboxes.append(button("显示全部列",() => edit(board => ({...board,hiddenFundColumnIDs:[]}))));
  tools.append(checkboxes);
  const sort = node("select",{ariaLabel:"排序"},node("option",{value:""},"添加顺序"),
    sortKeys.map(key => node("option",{value:key},labels[key])));
  sort.value = boardFilter.sort;
  sort.addEventListener("change",() => {boardFilter.sort = sort.value; boardFilter.direction = -1; renderRows();});
  const direction = button(boardFilter.direction < 0 ? "降序" : "升序",() => {
    boardFilter.direction *= -1;
    direction.textContent = boardFilter.direction < 0 ? "降序" : "升序";
    renderRows();
  });
  function renderRows() {
    sort.value = boardFilter.sort;
    direction.textContent = boardFilter.direction < 0 ? "降序" : "升序";
    direction.disabled = !boardFilter.sort;
    const entries = board.holdings.filter(item => filter(item,boardFilter.tab) && matches(item.fund,boardFilter.keyword))
      .map(holding => {
        const snapshot = board.snapshots[holding.fund.code];
        const m = holdingMetrics(holding,snapshot);
        return {holding,snapshot,...m,estimateRate:m.quote?.percent,dayProfit:m.published ?? m.estimated,
          navRate:money(holding.fund) || m.nav?.annualizedRate != null ? undefined : m.nav?.rate};
      });
    if (boardFilter.sort) entries.sort((a,b) => {
      const first = numeric(a[boardFilter.sort]), second = numeric(b[boardFilter.sort]);
      if (!Number.isFinite(first)) return Number.isFinite(second) ? 1 : 0;
      if (!Number.isFinite(second)) return -1;
      return (first-second)*boardFilter.direction;
    });
    const launch = entry => openFund({openDialog,edit,currentBoard},entry.holding.fund);
    const cell = (item,key) => {
      const {holding,nav,quote,snapshot} = item;
      if (key === "name") {
        const link = button(holding.fund.name,() => launch(item),"link");
        link.addEventListener("contextmenu",event => {
          event.preventDefault();
          launch(item);
        });
        return td(link);
      }
      if (key === "code") return td(holding.fund.code);
      if (key === "navDate") return td(nav?.day ?? "—");
      if (key === "nav") return td(displayNumber(nav?.value,4));
      if (key === "estimate") return td(displayNumber(quote?.value,4));
      if (key === "estimateTime") return td(snapshot?.estimate ? localTime(nativeDate(snapshot.estimate.timestamp)).slice(0,5) : "—");
      if (key === "value") return td(displayNumber(item.value));
      return td(signed(key === "navRate" ? nav?.annualizedRate ?? item.navRate : item[key],key.toLowerCase().endsWith("rate") ? "%" : ""));
    };
    const header = node("tr",{},...visible.map(key => {
      const th = node("th",{scope:"col"},sortKeys.includes(key) ? button(labels[key] + (boardFilter.sort === key ? (boardFilter.direction < 0 ? " ↓" : " ↑") : ""),() => {
        boardFilter.direction = boardFilter.sort === key ? -boardFilter.direction : -1;
        boardFilter.sort = key;
        renderRows();
      },"link") : labels[key]);
      enableDrop(th,"column",key,(source,target,event) => edit(board => {
        const after = event.clientX > th.getBoundingClientRect().left + th.offsetWidth/2;
        return {...board,fundColumnOrder:moveVisible(order,visible,source,target,after)};
      }));
      return th;
    }));
    const rows = entries.map(item => {
      const row = node("tr",{},...visible.map(key => cell(item,key)));
      if (!boardFilter.sort) enableDrop(row,"row",item.holding.fund.code,(source,target,event) => edit(board => {
        const after = event.clientY > row.getBoundingClientRect().top + row.offsetHeight/2;
        const codes = board.holdings.map(item => item.fund.code);
        const visibleCodes = entries.map(item => item.holding.fund.code);
        const map = new Map(board.holdings.map(item => [item.fund.code,item]));
        return {...board,holdings:moveVisible(codes,visibleCodes,source,target,after).map(code => map.get(code))};
      }));
      return row;
    });
    show(result, entries.length ? node("table",{},node("thead",{},header),node("tbody",{},rows)) :
      node("p",{className:"empty"},boardFilter.keyword ? "没有匹配的基金" : "此分组暂无基金"));
    search.onkeydown = event => {if (event.key === "Enter" && !event.isComposing && entries.length) launch(entries[0]);};
  }
  search.addEventListener("input",() => {boardFilter.keyword = search.value; renderRows();});
  section.append(node("div",{className:"row spread"},node("h2",{},title),node("div",{className:"row"},search,sort,direction,tools)),result);
  renderRows();
  return section;
}

function settings(board) {
  const interval = node("select",{ariaLabel:"自动刷新频率"},[5,10,30,60].map(value => node("option",{value:String(value)},`${value} 秒`)));
  interval.value = String([5,10,30,60].includes(board.refreshInterval) ? board.refreshInterval : 10);
  interval.addEventListener("change",async () => {
    await edit(board => ({...board,refreshInterval:+interval.value}),"已更新刷新频率");
    schedule();
    void refresh();
  });
  const appearance = node("select",{ariaLabel:"主题"},[["system","跟随系统"],["light","白色"],["dark","黑色"]].map(([value,title]) => node("option",{value},title)));
  appearance.value = board.appearanceTheme ?? "system";
  appearance.addEventListener("change",() => edit(board => ({...board,appearanceTheme:appearance.value}),"已更新主题"));
  return [node("section",{className:"panel stack"},node("h2",{},"设置"),
    node("div",{className:"row"},label("主题",appearance),label("盘中估值刷新",interval))),
    backupPanel(state,(next,message) => {
      updateLocal(next,message);
      schedule();
    })];
}

function render() {
  renderNav();
  renderIndexes();
  const {board} = state;
  const tab = boardFilter.tab;
  if (holdingsTabs.includes(tab)) {
    const active = document.activeElement;
    const focused = active?.getAttribute("aria-label") === "搜索当前列表";
    show(content, positionSummary(board), holdingsPanel(board));
    if (focused) content.querySelector("[type=search]")?.focus();
  } else if (tab === "settings") show(content, settings(board));
  else if (tab === "market") show(content,marketPanel(() => marketData));
  else show(content,futuresPanel(openDialog));
}

function schedule() {
  clearInterval(timer);
  const seconds = [5,10,30,60].includes(state.board.refreshInterval) ? state.board.refreshInterval : 10;
  timer = setInterval(() => {if (!document.hidden) void refresh();},seconds * 1000);
}

async function refresh(force = false) {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    if (force) refreshButton.disabled = true;
    try {
      const current = await loadState();
      const now = new Date();
      const timestamp = swiftTime(now.getTime());
      if (force || now - marketAt >= 60000) {
        marketAt = now.getTime();
        void quotes(indexes.map(([key]) => key)).then(async rows => {
          marketData = {...marketData,...rows};
          marketStatus = "";
          renderIndexes();
          await saveMarket("index-quotes", marketData);
        }).catch(() => {
          marketStatus = "缓存";
          renderIndexes();
        });
      }
      const jobs = current.board.holdings.map(({fund}) => {
        const before = current.board.snapshots[fund.code] ?? {history:[]};
        const age = value => value == null ? Infinity : timestamp - numeric(value);
        const wantNAV = force || age(before.navCheckedAt) >= (before.history.length ? 1200 : 240);
        const wantEstimate = !money(fund) && (force || (canPoll(now) &&
          age(before.estimateCheckedAt) >= (before.estimateAvailable === false ? Math.max(30,(current.board.refreshInterval ?? 10)*4) : (current.board.refreshInterval ?? 10))));
        return {fund,wantNAV,wantEstimate};
      }).filter(job => job.wantNAV || job.wantEstimate);
      let failures = 0;
      const results = [];
      for (let i = 0; i < jobs.length; i += 4) {
        const batch = await Promise.all(jobs.slice(i,i+4).map(async ({fund,wantNAV,wantEstimate}) => {
          const [nav,quote] = await Promise.allSettled([wantNAV ? fundNAV(fund) : undefined,wantEstimate ? fundEstimate(fund) : undefined]);
          failures += Number(nav.status === "rejected") + Number(quote.status === "rejected");
          return {code:fund.code,nav:nav.value,quote:quote.value,wantNAV,wantEstimate};
        }));
        results.push(...batch);
      }
      if (results.length) {
        const next = await updateState(last => {
          if (last.restoreRevision !== current.restoreRevision) return last;
          const snapshots = {...last.board.snapshots};
          const currentCodes = new Set(last.board.holdings.map(({fund}) => fund.code));
          for (const row of results) {
            if (!currentCodes.has(row.code)) continue;
            const before = snapshots[row.code] ?? {history:[]};
            const item = {...before};
            const navAllowed = row.wantNAV && !(numeric(item.navCheckedAt) > timestamp);
            const quoteAllowed = row.wantEstimate && !(numeric(item.estimateCheckedAt) > timestamp);
            if (navAllowed) item.navCheckedAt = row.nav ? timestamp : timestamp - 960;
            if (quoteAllowed) {
              item.estimateCheckedAt = timestamp;
              item.estimateAvailable = Boolean(row.quote?.estimate);
              if (row.quote?.estimate && !(numeric(item.estimate?.timestamp) > row.quote.estimate.timestamp)) item.estimate = row.quote.estimate;
            }
            item.history = mergeHistory(item.history,[...(quoteAllowed && row.quote?.nav ? [row.quote.nav] : []),...(navAllowed ? row.nav ?? [] : [])]);
            snapshots[row.code] = item;
          }
          return {...last,board:{...last.board,snapshots}};
        },{snapshotOnly:true});
        updateLocal(next,"",true,holdingsTabs.includes(boardFilter.tab));
      }
      if (force || results.length) status.textContent = failures ? `部分数据更新失败（${failures} 项）` : "已检查更新 · " + localTime(new Date());
    } catch (error) { status.textContent = errorMessage(error); }
    finally {refreshButton.disabled = false;}
  })().finally(() => {refreshing = undefined;});
  return refreshing;
}

$("#add").addEventListener("click",() => openSearch({openDialog,edit,currentBoard,refresh}));
refreshButton.addEventListener("click",() => {
  void refresh(true);
  if (boardFilter.tab === "market" || boardFilter.tab === "futures") content.querySelector("[data-autoload]")?.click();
});
document.addEventListener("visibilitychange",() => {if (!document.hidden) void refresh();});
document.addEventListener("keydown",event => {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f" && !dialog.open) {
    const input = content.querySelector("[type=search]");
    if (input) {event.preventDefault(); input.focus(); input.select();}
  }
});
theme(state.board);
render();
schedule();
void refresh();
