import assert from "node:assert/strict";
import test from "node:test";
import {decodeBackup,decimalText,exportBackup,exportPortable,numeric} from "../../ChromeExtension/backup.js";
import {actions,changeJournal,cumulativeReturns,entry,portfolio} from "../../ChromeExtension/holdings.js";
import {futuresSession,swiftTime} from "../../ChromeExtension/market.js";

const fund = (code,name=code) => ({code,name,kind:"混合型",initials:"",pinyin:""});
const nav = (day,value,rate) => ({day,value,rate,source:"天天基金"});
const now = new Date("2026-11-26T14:30:00+08:00");

test("v4 retains native Decimal tokens and settings, and lightweight export strips only snapshot history",() => {
  const original = '{"version":4,"board":{"holdings":[{"fund":{"code":"007339","name":"基金","kind":"","initials":"","pinyin":""},"shares":12345.678901234567891234,"costPerShare":1.234567890123456789012,"groups":["macd","red"]}],"snapshots":{"007339":{"history":[]}},"appearanceTheme":"dark","refreshInterval":5,"fundDetailTabOrder":["observation","history"]}}';
  const {board} = decodeBackup(original);
  assert.equal(decimalText(board.holdings[0].shares),"12345.678901234567891234");
  assert.equal(exportBackup(board),original);
  const lightweight = decodeBackup(exportPortable(board));
  assert.equal(lightweight.version,3);
  assert.deepEqual(lightweight.board.snapshots,{});
  assert.equal(lightweight.board.refreshInterval,5);
  const duplicate = {...board,holdings:[...board.holdings,...board.holdings]};
  assert.throws(() => decodeBackup(exportBackup(duplicate)),/重复基金/);
});

test("disclosed and estimated same-day returns combine, with previous-day quotes excluded",() => {
  const day = "2026-11-26", previous = "2026-11-25";
  const history = [nav(previous,1.1,0.2)];
  const quote = {marketDay:day,baseDay:previous,timestamp:swiftTime(now.getTime()-60000),value:1.12,percent:1.8};
  const board = {holdings:["007339","050025","000198"].map(code => ({fund:fund(code),shares:1000,costPerShare:1})),
    snapshots:{
      "007339":{history:[...history,nav(day,1.12,1.82)],estimate:quote},
      "050025":{history,estimate:quote},
      "000198":{history,estimate:{...quote,marketDay:previous}}
    }};
  const total = portfolio(board,now);
  assert.equal(numeric(total.published),20.02);
  assert.equal(numeric(total.estimated),20);
  assert.equal(numeric(total.dayProfit),40.02);
  assert.equal(total.covered,2);
  assert.deepEqual(total.exclusions,{"估值归属其他交易日":1});
});

test("adding, replacing and deleting a journal record recalculates its holding precisely",() => {
  const code = "007339", day = "2026-01-02";
  const base = {holdings:[{fund:fund(code),shares:100,costPerShare:1}],snapshots:{}};
  const change = {action:actions[0],day,shares:entry("20.25"),price:entry("2"),fee:entry("0.5")};
  const bought = changeJournal(base,code,change);
  assert.equal(numeric(bought.holdings[0].shares),120.25);
  const first = bought.journals[code][0];
  assert.equal(numeric(first.cash),-41);
  const changed = changeJournal(bought,code,{...change,shares:entry("25")},first.id);
  assert.equal(numeric(changed.holdings[0].shares),125);
  const deleted = changeJournal(changed,code,undefined,changed.journals[code][0].id);
  assert.equal(numeric(deleted.holdings[0].shares),100);
  assert.equal(numeric(deleted.holdings[0].costPerShare),1);
  assert.equal(deleted.journals[code],undefined);
});

test("cumulative return uses NAV precision and restarts at missing disclosure",() => {
  const result = cumulativeReturns([
    nav("2026-11-20",1.11,0),nav("2026-11-21",1.12,0.9),nav("2026-11-22",1.13),nav("2026-11-23",1.14,0.88)
  ],false);
  assert.deepEqual(result.map(row => row.time),["2026-11-22","2026-11-23"]);
  assert.ok(Math.abs(result.at(-1).value-(1.14/1.13-1)*100) < 1e-9);
});

test("futures session preserves the unfinished trading window and US summer time",() => {
  const result = futuresSession("CL",[{time:"2026-07-09 21:30:00",value:61}]);
  assert.ok(result.domain);
  assert.equal(result.domain.label,"06:00–05:00 · 北京时间");
  assert.ok(result.rows[0].axisTime < result.domain.end);
});
