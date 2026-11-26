import {displayNumber, signClass} from "./holdings.js";

export const node = (tag, properties = {}, ...children) => {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(properties)) {
    if (key.startsWith("on")) element.addEventListener(key.slice(2), value);
    else if (key in element && key !== "role") element[key] = value;
    else element.setAttribute(key, value);
  }
  element.append(...children.flat(Infinity).filter(child => child != null && child !== false));
  return element;
};

export const button = (label, action, className = "") => node("button", {
  type:"button", className, onclick: event => action(event)
}, label);
export const show = (target, ...children) => target.replaceChildren(...children.flat(Infinity).filter(child => child != null && child !== false));
export const td = (text, className = "") => node("td", {className}, text);
export const signed = (value, ending = "") => node("span", {className:signClass(value)},
  displayNumber(value) === "—" ? "—" : displayNumber(value) + ending);
export const errorMessage = error => error?.message === "Failed to fetch" ? "行情连接失败，请稍后刷新。" : error?.message ?? "操作失败。";
export const theme = board => { document.documentElement.dataset.theme = board.appearanceTheme ?? "system"; };

function minute(value) {
  const [hour, minutes] = value.split(":").map(Number);
  return hour * 60 + minutes;
}
export function sessionAxis(code) {
  return code.startsWith("us") ? [["09:30","16:00"]] : code === "r_hkHSI" ?
    [["09:30","12:00"],["13:00","16:00"]] : [["09:30","11:30"],["13:00","15:00"]];
}

const activeCharts = new WeakMap();
window.addEventListener("resize",() => {
  for (const canvas of document.querySelectorAll("canvas.chart")) activeCharts.get(canvas)?.();
});

export function seriesChart(rows, {reference, sessions, volumes = false, height = 230, candles = false, overlays = [], histogram = false, domain} = {}) {
  const output = node("div", {className:"muted chart-note", ariaLive:"polite"});
  const label = node("small", {className:"muted"});
  const canvas = node("canvas", {className:"chart", height, ariaLabel:"行情走势图"});
  const container = node("div", {}, canvas, label, output);
  const timePosition = clock => {
    let offset = 0;
    const at = minute(clock);
    for (const [a,b] of sessions) {
      const start = minute(a), end = minute(b);
      if (at >= start && at <= end) return offset + at - start;
      offset += end - start;
    }
    return undefined;
  };
  const points = rows.map((r,i) => ({...r, x:domain ? r.axisTime-domain.start : sessions ? timePosition(r.time) : i}))
    .filter(row => row.x != null && Number.isFinite(row.value));
  if (!points.length) return node("p", {className:"muted"}, "暂无可绘制数据");
  const endX = domain ? domain.end-domain.start : sessions ? sessions.reduce((sum,[a,b]) => sum + minute(b) - minute(a),0) : Math.max(1,rows.length - 1);
  label.textContent = domain ? domain.label : sessions ? sessions.map(([a,b]) => a + "–" + b).join(" / ") : points[0].time + " – " + points.at(-1).time;
  const values = points.flatMap(row => [row.value,...overlays.map(key => row[key]),...(candles ? [row.low,row.high] : [])]).filter(Number.isFinite);
  const hasReference = Number.isFinite(reference);
  const low = Math.min(...values), high = Math.max(...values);
  const range = hasReference ? Math.max(Math.abs(reference-low),Math.abs(high-reference),0.001) * 1.06 : 0;
  const min = hasReference ? reference-range : low === high ? low - .01 : low;
  const max = hasReference ? reference+range : low === high ? high + .01 : high;
  let hovered;
  function draw() {
    const width = Math.max(220, Math.round(canvas.getBoundingClientRect().width));
    if (canvas.width !== width) canvas.width = width;
    const ctx = canvas.getContext("2d");
    const styles = getComputedStyle(canvas);
    const color = key => styles.getPropertyValue(key).trim();
    const left = 49, right = hasReference ? width - 51 : width - 10;
    const bottom = volumes ? height - 49 : height - 9;
    const x = value => left + value / endX * (right - left);
    const y = value => bottom - (value - min) / (max - min) * (bottom - 10);
    ctx.clearRect(0,0,width,height);
    ctx.font = "10px sans-serif";
    for (let i = 0; i < 5; i++) {
      const value = min + (max - min) * i / 4;
      const position = y(value);
      ctx.fillStyle = color("--muted");
      ctx.fillText(displayNumber(value),1,position + 3);
      if (hasReference && reference !== 0) ctx.fillText(displayNumber((value-reference)/reference*100) + "%",right + 3,position + 3);
      ctx.strokeStyle = i === 2 && hasReference ? "#4877bf" : color("--grid");
      ctx.beginPath(); ctx.moveTo(left,position); ctx.lineTo(right,position); ctx.stroke();
    }
    const maxVolume = volumes ? Math.max(...points.map(row => row.volume ?? 0)) : 0;
    if (maxVolume > 0) points.forEach((row,i) => {
      ctx.fillStyle = row.value >= (points[i-1]?.value ?? reference) ? color("--up") : color("--down");
      const size = (row.volume ?? 0) / maxVolume * 36;
      ctx.fillRect(x(row.x) - 1, height - size, Math.max(1,(right-left)/endX*.75), size);
    });
    const line = (key, style) => {
      ctx.strokeStyle = style;
      ctx.lineWidth = 1.45;
      ctx.beginPath();
      let continues = false;
      for (const row of points) {
        if (!Number.isFinite(row[key])) {continues = false;continue;}
        if (!continues) ctx.moveTo(x(row.x),y(row[key]));
        else ctx.lineTo(x(row.x),y(row[key]));
        continues = true;
      }
      ctx.stroke();
    };
    if (candles) {
      const size = Math.max(2,Math.min(10,(right-left)/(endX+1)*.63));
      for (const row of points) {
        const tint = row.close >= row.open ? color("--up") : color("--down");
        ctx.strokeStyle = ctx.fillStyle = tint;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(x(row.x),y(row.low));
        ctx.lineTo(x(row.x),y(row.high));
        ctx.stroke();
        ctx.fillRect(x(row.x)-size/2,Math.min(y(row.open),y(row.close)),size,Math.max(1,Math.abs(y(row.open)-y(row.close))));
      }
    } else if (histogram) {
      const size = Math.max(1,Math.min(7,(right-left)/(endX+1)*.7));
      for (const row of points) {
        ctx.fillStyle = row.value >= 0 ? color("--up") : color("--down");
        ctx.fillRect(x(row.x)-size/2,Math.min(y(0),y(row.value)),size,Math.max(1,Math.abs(y(0)-y(row.value))));
      }
    } else line("value",color("--strong"));
    overlays.forEach((key,index) => line(key,["#cf8b33","#6a8be8","#9875d5"][index % 3]));
    for (const row of points.filter(point => point.signal)) {
      ctx.fillStyle = row.value >= 0 ? color("--up") : color("--down");
      ctx.beginPath();ctx.arc(x(row.x),y(row.value),3,0,Math.PI*2);ctx.fill();
    }
    const marker = hovered ?? (points.length === 1 ? points[0] : undefined);
    if (marker) {
      ctx.fillStyle = color("--strong");
      ctx.beginPath(); ctx.arc(x(marker.x),y(marker.value),3,0,Math.PI*2); ctx.fill();
    }
  }
  canvas.addEventListener("pointermove", event => {
    const chartWidth = canvas.width - (hasReference ? 100 : 59);
    const estimated = (event.offsetX - 49) / chartWidth * endX;
    hovered = points.reduce((closest,row) => Math.abs(row.x-estimated) < Math.abs(closest.x-estimated) ? row : closest);
    const volume = hovered.volume == null ? "" : " · 成交量 " + displayNumber(hovered.volume / 10000) + " 万";
    const ohlc = candles ? " · 开 " + displayNumber(hovered.open) + " · 高 " + displayNumber(hovered.high) + " · 低 " + displayNumber(hovered.low) : "";
    output.textContent = hovered.time + " · " + displayNumber(hovered.value, 3) + volume + ohlc + (hovered.signal ? " · " + hovered.signal : "");
    draw();
  });
  canvas.addEventListener("pointerleave", () => { hovered = undefined; output.textContent = ""; draw(); });
  activeCharts.set(canvas,draw);
  requestAnimationFrame(draw);
  return container;
}

export function download(name, text, mime = "application/json") {
  const url = URL.createObjectURL(new Blob([text], {type:mime}));
  node("a", {href:url, download:name}).click();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
