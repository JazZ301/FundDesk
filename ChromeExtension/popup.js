import {portfolio, displayNumber, signClass} from "./holdings.js";
import {indexTrend, quotes} from "./market.js";
import {loadMarket, loadState, saveMarket} from "./store.js";
import {errorMessage, node, seriesChart, sessionAxis, show, signed, theme} from "./ui.js";

const code = "sh000001";
const quoteElement = document.querySelector("#quote");
const trendElement = document.querySelector("#trend");
const refresh = document.querySelector("#refresh");
const last = await loadState();
theme(last.board);
const total = portfolio(last.board);
show(document.querySelector("#portfolio"), node("span", {className:"muted"}, "持仓当日收益"),
  node("strong", {className:signClass(total.dayProfit)}, displayNumber(total.dayProfit)));

function renderQuote(row, cached = false) {
  show(quoteElement, node("div", {className:"row"},
    node("strong", {className:"quote-value"}, displayNumber(row.value)),
    signed(row.change), signed(row.percent,"%")
  ), node("small", {}, (cached ? "缓存 · " : "") + row.time + " · 腾讯行情"));
}

function renderTrend(data, cached = false) {
  show(trendElement, seriesChart(data.points,{reference:data.reference,sessions:sessionAxis(code),volumes:true,height:163}),
    node("small", {}, (cached ? "分时缓存 · " : "分时 · ") + data.source + (data.day ? " · " + data.day : "")));
}

async function update() {
  if (refresh.disabled) return;
  refresh.disabled = true;
  try {
    const updates = await Promise.allSettled([
      quotes([code]).then(async rows => {
        if (!rows[code]) throw new Error("未取得上证报价");
        renderQuote(rows[code]);
        await saveMarket("popup-quote", rows[code]);
      }),
      indexTrend(code).then(async data => {
        renderTrend(data);
        await saveMarket("trend-" + code, data);
      })
    ]);
    for (const [i,result] of updates.entries()) {
      if (result.status === "fulfilled") continue;
      const target = [quoteElement, trendElement][i];
      const cached = await loadMarket(["popup-quote","trend-" + code][i]);
      if (cached) [renderQuote,renderTrend][i](cached.value,true);
      else show(target, node("p", {className:"muted"}, errorMessage(result.reason)));
    }
  } finally {
    refresh.disabled = false;
  }
}
refresh.addEventListener("click",update);
await update();
