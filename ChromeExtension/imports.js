import {decodeBackup, decimalText, validCode} from "./backup.js";
import {entry, positive} from "./holdings.js";
import {catalog} from "./market.js";

export const groups = {macd:"MACD 观察", red:"红利观察"};
const fundRecord = (code,name,kind) => ({code,name:name || code,kind:kind || "",initials:"",pinyin:""});
function csvRows(text) {
  const rows = [];
  let row = [], field = "", quoted = false;
  for (let i = 0; i < text.length; i++) {
    const character = text[i];
    if (character === '"' && quoted && text[i+1] === '"') {
      field += '"';
      i++;
    } else if (character === '"' && (quoted || !field)) {
      quoted = !quoted;
    } else if (character === "," && !quoted) {
      row.push(field);
      field = "";
    } else if (/[\r\n]/.test(character) && !quoted) {
      row.push(field);
      if (row.some(Boolean)) rows.push(row);
      row = [];
      field = "";
      if (character === "\r" && text[i+1] === "\n") i++;
    } else {
      field += character;
    }
  }
  if (quoted) throw new Error("CSV 含未闭合的引号。");
  row.push(field);
  if (row.some(Boolean)) rows.push(row);
  return rows;
}

function decodeCSV(text, funds) {
  const [columns, ...rows] = csvRows(text);
  const header = columns?.map(label => label.trim().toLowerCase()) ?? [];
  const index = (...keys) => header.findIndex(label => keys.includes(label));
  const columnsByField = {
    code:index("基金代码","代码","fundcode","code"), name:index("基金名称","名称","name"),
    kind:index("基金类型","类型","kind"), shares:index("持有份额","持仓份额","份额","shares","num"),
    cost:index("单位成本","成本价","持仓成本","cost","costpershare"), groups:index("所属分类")
  };
  if (columnsByField.code < 0) throw new Error("CSV 缺少基金代码列。");
  return rows.map(row => {
    const get = key => row[columnsByField[key]]?.trim() ?? "";
    const candidate = get("code");
    if (!/^\d{1,6}$/.test(candidate)) return null;
    const code = candidate.padStart(6,"0");
    try {
      const shares = entry(get("shares"));
      const cost = entry(get("cost"));
      if (get("shares").startsWith("-") || get("cost").startsWith("-")) return null;
      const names = get("groups").split("|").map(value => value.trim());
      return {fund: funds.get(code) ?? fundRecord(code,get("name"),get("kind")), shares,
        costPerShare:positive(cost) ? cost : undefined,
        groups:Object.keys(groups).filter(key => names.includes(groups[key]))};
    } catch {
      return null;
    }
  });
}

export function exportCSV(holdings) {
  const escaped = cell => '"' + cell.replaceAll('"','""') + '"';
  const safe = cell => /^[=+\-@]/.test(cell.trimStart()) ? "'" + cell : cell;
  const rows = [["基金代码","基金名称","基金类型","持有份额","单位成本","所属分类"]];
  for (const row of holdings) {
    const categories = ["全部自选", ...(positive(row.shares) ? ["我的持仓"] : []), ...(row.groups ?? []).map(key => groups[key])];
    rows.push([row.fund.code,safe(row.fund.name),safe(row.fund.kind),
      row.shares == null ? "" : decimalText(row.shares), row.costPerShare == null ? "" : decimalText(row.costPerShare), categories.join("|")]);
  }
  return "\uFEFF" + rows.map(row => row.map(escaped).join(",")).join("\r\n") + "\r\n";
}

async function read(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const decoder = bytes[0] === 0xff && bytes[1] === 0xfe ? "utf-16le" :
    bytes[0] === 0xfe && bytes[1] === 0xff ? "utf-16be" : "utf-8";
  return new TextDecoder(decoder,{fatal:true}).decode(bytes);
}

export async function mergeInput(file) {
  const text = await read(file);
  if (/^\s*\{/.test(text)) {
    const raw = JSON.parse(text);
    if (raw.version != null) return decodeBackup(text).board;
    if (!["fundListGroup","fundListM","fundList"].some(key => key in raw)) throw new Error("无法识别导入文件。");
    const funds = new Map((await catalog().catch(() => [])).map(fund => [fund.code,fund]));
    const rows = [...(raw.fundListGroup ?? []).flatMap(row => row.funds ?? []), ...(raw.fundListM ?? []), ...(raw.fundList ?? [])];
    return {holdings:rows.map(row => {
      const rawCode = row?.code ?? row?.fundcode ?? row?.fundCode ?? row;
      const code = Number.isInteger(rawCode) ? String(rawCode).padStart(6,"0") : rawCode;
      if (!validCode(code)) return null;
      let shares, costPerShare;
      try {
        const quantity = entry(String(row?.num ?? row?.shares ?? ""));
        const cost = entry(String(row?.cost ?? row?.costPerShare ?? ""));
        shares = positive(quantity) ? quantity : undefined;
        costPerShare = positive(cost) ? cost : undefined;
      } catch {}
      return {fund:funds.get(code) ?? fundRecord(code,row?.name), shares, costPerShare};
    })};
  }
  const funds = new Map((await catalog().catch(() => [])).map(fund => [fund.code,fund]));
  return {holdings:decodeCSV(text, funds)};
}

export function mergeBoard(board, incoming) {
  const seen = new Set(board.holdings.map(({fund}) => fund.code));
  const holdings = [...board.holdings], observations = {...board.observations}, journals = {...board.journals};
  let added = 0, invalid = 0, duplicates = 0;
  for (const item of incoming.holdings) {
    if (!item) { invalid++; continue; }
    const {code} = item.fund;
    if (seen.has(code)) { duplicates++; continue; }
    seen.add(code);
    holdings.push(item);
    if (incoming.observations?.[code]) observations[code] = incoming.observations[code];
    if (incoming.journals?.[code]) journals[code] = incoming.journals[code];
    added++;
  }
  return {board:{...board,holdings,observations,journals},added,invalid,duplicates};
}
