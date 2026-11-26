import {enableMarketHeaders} from "./market-permissions.js";

const url = (host, path, params = {}) => {
  const address = new URL(path, `https://${host}`);
  address.search = new URLSearchParams(params);
  return address.href;
};

export const endpoints = {
  catalog: () => url("fund.eastmoney.com", "/js/fundcode_search.js"),
  search: key => url("fundsuggest.eastmoney.com", "/FundSearch/api/FundSearchAPI.ashx", {key, m: 9}),
  nav: (code, pageSize = 20) => url("api.fund.eastmoney.com", "/f10/lsjz", {fundCode: code, pageIndex: 1, pageSize}),
  history: code => url("fund.eastmoney.com", `/pingzhongdata/${code}.js`),
  estimate: symbol => url("stock.finance.sina.com.cn", "/fundInfo/api/openapi.php/FdFundService.getEstimateNetworthPic", {symbol}),
  fund: (path, FCODE) => url("fundmobapi.eastmoney.com", path, {FCODE, deviceid: "Wap", plat: "Wap", product: "EFund", version: "2.0.0"}),
  quotes: codes => url("qt.gtimg.cn", "/q=" + codes.join(",")),
  usTrend: code => url("web.ifzq.gtimg.cn", "/appstock/app/usMinute/query", {code}),
  trend: code => url("web.ifzq.gtimg.cn", "/appstock/app/minute/query", {code}),
  futures: codes => url("hq.sinajs.cn", "/list=" + codes.map(code => "hf_" + code).join(",")),
  futuresHistory: (method, symbol) => url("stock2.finance.sina.com.cn", "/futures/api/openapi.php/GlobalFuturesService." + method, {symbol}),
  eastQuote: (host, path, query) => url(host + ".eastmoney.com", "/api/qt/" + path, query),
  sectors: (code, key) => url("data.eastmoney.com", "/dataapi/bkzj/getbkzj", {key, code}),
  yahoo: symbol => url("query1.finance.yahoo.com", "/v8/finance/chart/" + symbol, {interval: "1m", range: "1d"})
};

export async function fetchText(address, encoding = "utf-8") {
  await enableMarketHeaders();
  const response = await fetch(address, {
    cache: "no-store", credentials: "omit", signal: AbortSignal.timeout(12000)
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const payload = await response.arrayBuffer();
  if (!payload.byteLength || payload.byteLength > 10_000_000) throw new Error("响应为空或超出大小限制");
  return new TextDecoder(encoding).decode(payload);
}

export async function fetchJSON(address) {
  return JSON.parse(await fetchText(address));
}

export function scriptValue(script, name) {
  const match = new RegExp(`(?:^|[;\\s])(?:var\\s+)?${name}\\s*=\\s*`).exec(script);
  if (!match) return undefined;
  const source = script.slice(match.index + match[0].length).trimStart();
  const closing = {"[": "]", "{": "}"};
  let depth = 0;
  let quoted = false;
  let escaped = false;
  for (let i = 0; i < source.length; i++) {
    const char = source[i];
    if (quoted) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') quoted = false;
    } else if (char === '"') {
      quoted = true;
    } else if (closing[char]) {
      depth++;
    } else if (char === "]" || char === "}") {
      depth--;
      if (!depth) return JSON.parse(source.slice(0, i + 1));
    } else if (char === ";" && !depth) {
      return JSON.parse(source.slice(0, i));
    }
  }
  return JSON.parse(source.trim());
}
