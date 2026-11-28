import { formatChinaDateTime, formatChinaTime, formatMoney, formatPercent, formatSwiftTime, FuturesIntraday, IndexTrend, PlotPoint } from "./api";
import * as echarts from "echarts";
import { useEffect, useMemo, useRef, useState } from "react";

export type ChartPoint = { label: string; value: number };

type Palette = {
  ink: string;
  muted: string;
  line: string;
  brand: string;
  up: string;
  down: string;
  panel: string;
  tooltip: string;
};

function readPalette(): Palette {
  const styles = getComputedStyle(document.documentElement);
  const value = (name: string, fallback: string) => styles.getPropertyValue(name).trim() || fallback;
  const dark = document.documentElement.dataset.theme === "dark"
    || (!document.documentElement.dataset.theme
      && window.matchMedia("(prefers-color-scheme: dark)").matches);
  return {
    ink: value("--ink", dark ? "#e8eefb" : "#16233b"),
    muted: value("--muted", dark ? "#93a3bd" : "#7c8aa0"),
    line: value("--line", dark ? "#223252" : "#e3e9f2"),
    brand: value("--brand", dark ? "#7ea2f5" : "#3f6ad8"),
    up: value("--up", dark ? "#f0736f" : "#d84a4a"),
    down: value("--down", dark ? "#4fc79a" : "#1c9c6b"),
    panel: value("--panel", dark ? "#14203a" : "#ffffff"),
    tooltip: dark ? "rgba(8,22,36,0.96)" : "rgba(15,23,42,0.92)"
  };
}

function usePalette(): Palette {
  const [palette, setPalette] = useState<Palette>(() => readPalette());
  useEffect(() => {
    const update = () => setPalette(readPalette());
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    media.addEventListener("change", update);
    return () => {
      observer.disconnect();
      media.removeEventListener("change", update);
    };
  }, []);
  return palette;
}

function useChart(): {
  container: React.RefObject<HTMLDivElement>;
  instance: React.MutableRefObject<echarts.ECharts | null>;
} {
  const container = useRef<HTMLDivElement>(null);
  const instance = useRef<echarts.ECharts | null>(null);
  useEffect(() => {
    if (!container.current) return;
    const chart = echarts.init(container.current, undefined, { renderer: "canvas" });
    instance.current = chart;
    const observer = new ResizeObserver(() => chart.resize());
    observer.observe(container.current);
    return () => {
      observer.disconnect();
      chart.dispose();
      instance.current = null;
    };
  }, []);
  return { container, instance };
}

type LineChartProps = {
  points: ChartPoint[];
  baseline?: number;
  height?: number;
  digits?: number;
  emptyText?: string;
  symmetric?: boolean;
  area?: boolean;
  primary?: boolean;
};

export function LineChart({
  points,
  baseline,
  height = 280,
  digits = 2,
  emptyText = "暂无数据",
  symmetric = false,
  area = true,
  primary = false
}: LineChartProps) {
  const palette = usePalette();
  const { container, instance } = useChart();

  const option = useMemo<echarts.EChartsOption>(() => {
    if (points.length === 0) {
      return {
        title: {
          text: emptyText,
          left: "center",
          top: "middle",
          textStyle: { color: palette.muted, fontSize: 13, fontWeight: "normal" }
        }
      };
    }
    const values = points.map((point) => point.value);
    const last = values[values.length - 1];
    const reference = baseline ?? values[0];
    const rising = last >= reference;
    const color = primary ? palette.brand : rising ? palette.up : palette.down;
    let min: number | undefined;
    let max: number | undefined;
    if (symmetric && baseline !== undefined) {
      const deviation = Math.max(...values.map((value) => Math.abs(value - baseline)), Math.abs(baseline) * 0.002);
      min = baseline - deviation * 1.25;
      max = baseline + deviation * 1.25;
    }
    return {
      animation: false,
      backgroundColor: "transparent",
      grid: { left: 62, right: 24, top: 20, bottom: 34 },
      tooltip: {
        trigger: "axis",
        backgroundColor: palette.tooltip,
        borderWidth: 0,
        textStyle: { color: "#f8fafc", fontSize: 12 },
        formatter: (params) => {
          const list = Array.isArray(params) ? params : [params];
          const index = (list[0] as { dataIndex: number }).dataIndex;
          const point = points[index];
          if (!point) return "";
          const delta = baseline !== undefined ? point.value - baseline : undefined;
          return [
            `<b>${point.label}</b>`,
            `数值 ${point.value.toFixed(digits)}`,
            ...(delta !== undefined
              ? [`相对基准 ${delta >= 0 ? "+" : ""}${delta.toFixed(digits)}`]
              : [])
          ].join("<br/>");
        }
      },
      xAxis: {
        type: "category",
        data: points.map((point) => point.label),
        boundaryGap: false,
        axisLine: { lineStyle: { color: palette.line } },
        axisTick: { show: false },
        axisLabel: {
          color: palette.muted,
          fontSize: 10,
          interval: Math.max(Math.floor(points.length / 6) - 1, 0)
        }
      },
      yAxis: {
        type: "value",
        scale: !symmetric,
        min,
        max,
        axisLine: { show: false },
        axisTick: { show: false },
        splitLine: { lineStyle: { color: palette.line, opacity: 0.65 } },
        axisLabel: {
          color: palette.muted,
          fontSize: 10,
          formatter: (value: number) => value.toFixed(digits)
        }
      },
      series: [
        {
          type: "line",
          data: values,
          symbol: "none",
          lineStyle: { width: 1.7, color },
          areaStyle: area
            ? {
                color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
                  { offset: 0, color: rising ? "rgba(224,90,90,0.18)" : "rgba(36,160,107,0.18)" },
                  { offset: 1, color: "rgba(255,255,255,0)" }
                ])
              }
            : undefined,
          markLine:
            baseline !== undefined
              ? {
                  silent: true,
                  symbol: "none",
                  label: {
                    formatter: `基准 ${baseline.toFixed(digits)}`,
                    position: "insideEndTop",
                    color: palette.brand,
                    fontSize: 10
                  },
                  lineStyle: { color: palette.brand, type: "dashed", width: 1 },
                  data: [{ yAxis: baseline }]
                }
              : undefined
        }
      ]
    };
  }, [points, baseline, digits, emptyText, symmetric, area, primary, palette]);

  useEffect(() => {
    instance.current?.setOption(option, true);
  }, [option]);

  return <div className="chart" style={{ height }} ref={container} />;
}

export function EstimateIntradayChart({
  points,
  height = 211
}: {
  points: { time: number; value: number }[];
  height?: number;
}) {
  const palette = usePalette();
  const { container, instance } = useChart();
  const option = useMemo<echarts.EChartsOption>(() => {
    const windows = [[570, 690], [780, 900]];
    const total = windows.reduce((sum, [start, end]) => sum + end - start, 0);
    const minuteOf = (value: number) => {
      const [hour, minute] = formatSwiftTime(value).split(":").map(Number);
      return hour * 60 + minute;
    };
    const positionOf = (value: number) => {
      const minute = minuteOf(value);
      let offset = 0;
      for (const [start, end] of windows) {
        if (minute >= start && minute <= end) return offset + minute - start;
        offset += end - start;
      }
      return null;
    };
    const slots = Array.from({ length: total + 1 }, () => null as number | null);
    for (const point of points) {
      const position = positionOf(point.time);
      if (position != null) slots[position] = point.value;
    }
    const values = slots.filter((value): value is number => value != null);
    if (values.length === 0) {
      return {
        title: {
          text: "数据源未提供该基金的估算分时。",
          left: "center",
          top: "middle",
          textStyle: { color: palette.muted, fontSize: 13, fontWeight: "normal" }
        }
      };
    }
    const marks = new Map([
      [0, "09:30"],
      [60, "10:30"],
      [120, "11:30/13:00"],
      [180, "14:00"],
      [240, "15:00"]
    ]);
    const low = Math.min(...values);
    const high = Math.max(...values);
    const padding = Math.max((high - low) * 0.1, Math.abs(high) * 0.0005, 0.0001);
    return {
      animation: false,
      backgroundColor: "transparent",
      grid: { left: 18, right: 24, top: 14, bottom: 30 },
      tooltip: {
        trigger: "axis",
        backgroundColor: palette.tooltip,
        borderWidth: 0,
        textStyle: { color: "#f8fafc", fontSize: 12 },
        formatter: (params) => {
          const list = Array.isArray(params) ? params : [params];
          const index = (list[0] as { dataIndex: number }).dataIndex;
          const value = slots[index];
          if (value == null) return "";
          return `<b>${marks.get(index) ?? ""}</b><br/>估算净值 ${value.toFixed(4)}`;
        }
      },
      xAxis: {
        type: "category",
        data: Array.from({ length: total + 1 }, (_, index) => String(index)),
        boundaryGap: false,
        axisLine: { lineStyle: { color: palette.line } },
        axisTick: { show: false },
        axisLabel: {
          color: palette.muted,
          fontSize: 10,
          interval: (index: number) => marks.has(index),
          formatter: (_value: string, index: number) => marks.get(index) ?? ""
        },
        splitLine: {
          show: true,
          interval: (index: number) => marks.has(index),
          lineStyle: { color: palette.line, type: "dashed" }
        }
      },
      yAxis: {
        type: "value",
        min: low - padding,
        max: high + padding,
        axisLine: { show: false },
        axisTick: { show: false },
        axisLabel: { show: false },
        splitLine: { lineStyle: { color: palette.line, type: "dashed" } }
      },
      series: [{
        type: "line",
        data: slots,
        symbol: "none",
        connectNulls: true,
        lineStyle: { width: 1.5, color: palette.brand }
      }]
    };
  }, [points, palette]);

  useEffect(() => {
    instance.current?.setOption(option, true);
  }, [instance, option]);

  return <div className="chart" style={{ height }} ref={container} />;
}

export function IndexSessionChart({ trend }: { trend: IndexTrend }) {
  const palette = usePalette();
  const { container, instance } = useChart();
  const model = useMemo(() => {
    const { session } = trend;
    const byMinute = (points: PlotPoint[]) => {
      const result = new Map<number, PlotPoint>();
      for (const point of points) {
        const [hour, minute] = formatSwiftTime(point.time, session.time_zone).split(":").map(Number);
        const local = hour * 60 + minute;
        let offset = 0;
        for (const window of session.windows) {
          if (local >= window.start_minute && local <= window.end_minute) {
            const position = offset + local - window.start_minute;
            if ((result.get(position)?.time ?? -Infinity) <= point.time) result.set(position, point);
            break;
          }
          offset += window.end_minute - window.start_minute;
        }
      }
      return result;
    };
    const prices = byMinute(trend.points);
    const volumes = byMinute(trend.volumes ?? []);
    const total = session.windows.reduce((sum, window) => sum + window.end_minute - window.start_minute, 0);
    const marks = new Map(session.axis_marks.map(({ position, title }) => [position, title]));
    const minutes = Array.from({ length: total + 1 }, (_, index) => index);
    const points = minutes.flatMap((minute) => prices.get(minute) ?? []);
    const latest = points.at(-1);
    const baseline = Math.max(trend.previousClose ?? points[0]?.value ?? 1, 0.01);
    const padding = Math.max(baseline * 0.002, ...points.map((point) => Math.abs(point.value - baseline) * 1.08));
    return { prices, volumes, minutes, marks, latest, baseline, padding };
  }, [trend]);
  const { prices, volumes, minutes, marks, latest, baseline, padding } = model;
  const [hover, setHover] = useState<number>();
  const active = hover === undefined ? latest : prices.get(hover) ?? latest;
  const rate = (value: number) => (value - baseline) / baseline * 100;
  const option = useMemo<echarts.EChartsOption>(() => {
    let previous: number | undefined;
    const volumeData = minutes.map((minute) => {
      const volume = volumes.get(minute);
      const price = prices.get(minute)?.value;
      const color = price == null || previous == null || price === previous
        ? palette.muted : price > previous ? palette.up : palette.down;
      if (price != null) previous = price;
      return volume ? { value: volume.value / 10_000, itemStyle: { color, opacity: 0.75 } } : null;
    });
    const showVolume = volumes.size > 0;
    const gridLine = { color: palette.line, type: "dashed" as const };
    const axis = {
      type: "category" as const,
      data: minutes,
      boundaryGap: false,
      axisLine: { show: false },
      axisTick: { show: false },
      axisLabel: {
        color: palette.muted,
        interval: (index: number) => marks.has(index),
        formatter: (_value: string, index: number) => marks.get(index) ?? ""
      },
      splitLine: { show: true, interval: (index: number) => marks.has(index), lineStyle: gridLine }
    };
    const priceAxis = {
      type: "value" as const,
      min: baseline - padding,
      max: baseline + padding,
      interval: padding / 3,
      axisLine: { show: false },
      axisTick: { show: false }
    };
    const axisColor = (value?: number | string) => {
      const delta = Number(value) - baseline;
      return delta > 1e-7 ? palette.up : delta < -1e-7 ? palette.down : palette.muted;
    };
    const series: echarts.SeriesOption[] = [{
      type: "line",
      data: minutes.map((minute) => prices.get(minute)?.value ?? null),
      symbol: "none",
      connectNulls: true,
      lineStyle: { color: palette.brand, width: 1.8 },
      markLine: {
        silent: true, symbol: "none", label: { show: false },
        lineStyle: { color: palette.brand, type: "solid" },
        data: [{ yAxis: baseline }]
      },
      markPoint: latest ? {
        silent: true, symbol: "circle", symbolSize: 6, label: { show: false },
        itemStyle: { color: palette.brand },
        data: [{ name: "最新点位", coord: [minutes.find((minute) => prices.get(minute) === latest)!, latest.value] }]
      } : undefined
    }];
    if (showVolume) series.push({
      type: "bar", xAxisIndex: 1, yAxisIndex: 2, data: volumeData, barMaxWidth: 7
    });
    return {
      animation: false,
      title: showVolume ? { text: "成交量（万）", left: 0, bottom: 96,
        padding: 0, textStyle: { color: palette.muted, fontSize: 10, fontWeight: "normal" } } : undefined,
      grid: [
        { left: 69, right: 60, top: 13, bottom: showVolume ? 125 : 32 },
        ...(showVolume ? [{ left: 69, right: 60, bottom: 26, height: 65 }] : [])
      ],
      axisPointer: { link: [{ xAxisIndex: "all" }], lineStyle: { color: palette.brand, opacity: 0.4 } },
      tooltip: { trigger: "axis", showContent: false },
      xAxis: showVolume ? [axis, { ...axis, gridIndex: 1 }] : [axis],
      yAxis: [
        { ...priceAxis, splitLine: { lineStyle: gridLine },
          axisLabel: { color: axisColor, formatter: (value: number) => formatMoney(value) } },
        { ...priceAxis, position: "right", splitLine: { show: false },
          axisLabel: { color: axisColor, formatter: (value: number) => formatPercent(Math.abs(value - baseline) < 1e-7 ? 0 : (value - baseline) / baseline * 100) } },
        ...(showVolume ? [{
          type: "value" as const, gridIndex: 1, splitNumber: 2,
          splitLine: { show: false }, axisLabel: { color: palette.muted }
        }] : [])
      ],
      series
    };
  }, [prices, volumes, minutes, marks, latest, baseline, padding, palette]);

  useEffect(() => {
    const chart = instance.current;
    if (!chart) return;
    const select = (event: unknown) => {
      const value = (event as { axesInfo?: { value: number }[] }).axesInfo?.[0]?.value;
      setHover(value === undefined ? undefined : Number(value));
    };
    const reset = () => setHover(undefined);
    const renderer = chart.getZr();
    chart.on("updateAxisPointer", select);
    renderer.on("globalout", reset);
    return () => {
      if (!chart.isDisposed()) {
        chart.off("updateAxisPointer", select);
        renderer.off("globalout", reset);
      }
    };
  }, [instance, latest]);
  useEffect(() => {
    instance.current?.setOption(option, true);
  }, [instance, option]);


  return (
    <>
      {latest && <div className="chart-subhead index-chart-readout">
        <span>{active && <>● {formatSwiftTime(active.time, trend.session.time_zone)}　{formatMoney(active.value)}　<strong className={rate(active.value) > 0 ? "up" : rate(active.value) < 0 ? "down" : ""}>{formatPercent(rate(active.value))}</strong></>}</span>
        <span>{trend.previousClose == null ? "基准" : "昨收"} {formatMoney(baseline)} · 指数点位 / 涨跌幅 · {trend.session.time_zone_label}</span>
      </div>}
      {!latest && <div className="empty">该指数当前没有可显示的有效交易时段数据</div>}
      <div hidden={!latest} className="chart" style={{ height: volumes.size > 0 ? 425 : 330 }} ref={container} />
    </>
  );
}

export function FuturesIntradayChart({
  trend,
  loading
}: {
  trend?: FuturesIntraday | null;
  loading: boolean;
}) {
  const palette = usePalette();
  const { container, instance } = useChart();
  const model = useMemo(() => {
    const points = trend?.points ?? [];
    const reference = trend?.reference;
    const baseline = reference != null && Number.isFinite(reference) && reference !== 0 ? reference : undefined;
    const averageByTime = new Map(trend?.averages?.map((point) => [point.time, point.value]));
    const percent = (price: number) => baseline === undefined ? undefined : (price - baseline) / Math.abs(baseline) * 100;
    return { points, baseline, averageByTime, percent };
  }, [trend]);
  const { points, baseline, averageByTime, percent } = model;
  const latest = points.at(-1);
  const latestRate = latest && percent(latest.value);

  const option = useMemo<echarts.EChartsOption>(() => {
    if (!latest) {
      return { title: { text: loading ? "正在获取分时…" : "暂无分时数据", left: "center", top: "middle",
        textStyle: { color: palette.muted, fontSize: 13, fontWeight: "normal" } } };
    }
    const colors = (value?: number | string) => {
      const change = percent(Number(value)) ?? 0;
      return change >= 0.005 ? palette.up : change <= -0.005 ? palette.down : palette.muted;
    };
    const values = points.map((point) => point.value);
    const averages = points.map((point) => averageByTime.get(point.time) ?? null);
    const displayed = [...values, ...averages.filter((value): value is number => value !== null)];
    const low = Math.min(...displayed);
    const high = Math.max(...displayed);
    const padding = Math.max((high - low) * 0.08, Math.abs(high) * 0.0005, 0.0001);
    const halfRange = baseline === undefined ? 0
      : Math.max(Math.abs(high - baseline), Math.abs(low - baseline), Math.abs(baseline) * 0.001) + padding;
    const priceAxis = {
      type: "value" as const,
      min: baseline === undefined ? low - padding : baseline - halfRange,
      max: baseline === undefined ? high + padding : baseline + halfRange,
      interval: halfRange ? halfRange / 2 : undefined,
      axisLine: { show: false },
      axisTick: { show: false }
    };
    const lastIndex = points.length - 1;
    const marks = new Set(Array.from({ length: 7 }, (_, index) => Math.round(lastIndex * index / 6)));
    const series: echarts.SeriesOption[] = [{
      name: "价格",
      type: "line",
      data: values,
      symbol: "none",
      lineStyle: { color: palette.brand, width: 1.8 },
      markLine: baseline === undefined ? undefined : {
        silent: true, symbol: "none", label: { show: false },
        lineStyle: { color: palette.muted, type: "dashed" },
        data: [{ yAxis: baseline }]
      },
      markPoint: {
        silent: true, symbol: "circle", symbolSize: 6, label: { show: false },
        itemStyle: { color: palette.brand },
        data: [{ name: "最新价", coord: [lastIndex, latest.value] }]
      }
    }];
    if (averageByTime.size) series.push({
      name: "均价", type: "line", data: averages, symbol: "none",
      lineStyle: { width: 1.2, color: "#c79536" }
    });
    return {
      animation: false,
      grid: { left: 73, right: baseline === undefined ? 32 : 73, top: 28, bottom: 32 },
      tooltip: {
        trigger: "axis",
        confine: true,
        axisPointer: { type: "cross", label: { show: false } },
        backgroundColor: palette.tooltip,
        borderWidth: 0,
        textStyle: { color: "#f8fafc", fontSize: 12 },
        formatter: (params) => {
          const index = (Array.isArray(params) ? params[0] : params)?.dataIndex;
          const point = points[index];
          if (!point) return "";
          const average = averages[index];
          return [
            `<b>${formatChinaDateTime(point.time)}</b>`,
            `价格 ${formatMoney(point.value)}`,
            ...(baseline === undefined ? [] : [`涨跌幅 ${formatPercent(percent(point.value))}`]),
            ...(average == null ? [] : [`均价 ${formatMoney(average)}`])
          ].join("<br/>");
        }
      },
      xAxis: {
        type: "category",
        data: points.map((point) => formatChinaTime(point.time)),
        boundaryGap: false,
        axisLine: { onZero: false, lineStyle: { color: palette.line } },
        axisTick: { show: false },
        axisLabel: { color: palette.muted, fontSize: 11, hideOverlap: true,
          showMinLabel: true, showMaxLabel: true, interval: (index) => marks.has(index) },
        splitLine: { show: true, interval: (index) => marks.has(index),
          lineStyle: { color: palette.line, type: "dashed" } }
      },
      yAxis: [
        { ...priceAxis, name: "价格", nameGap: 12, nameTextStyle: { color: palette.muted },
          axisLabel: { color: colors, formatter: (price: number) => formatMoney(price) },
          splitLine: { lineStyle: { color: palette.line, opacity: 0.7 } } },
        ...(baseline === undefined ? [] : [{
          ...priceAxis, name: "涨跌幅", position: "right" as const, nameGap: 12,
          nameTextStyle: { color: palette.muted }, splitLine: { show: false },
          axisLabel: { color: colors, formatter: (price: number) => {
            const change = percent(price) ?? 0;
            return formatPercent(Math.abs(change) < 0.005 ? 0 : change);
          } }
        }])
      ],
      series
    };
  }, [points, baseline, latest, averageByTime, percent, loading, palette]);

  useEffect(() => {
    instance.current?.setOption(option, true);
  }, [instance, option]);

  const latestAverage = latest && averageByTime.get(latest.time);
  return (
    <>
      {latest && <div className="futures-intraday-readout">
        <span>最新 <strong>{formatChinaDateTime(latest.time)}</strong> 北京时间</span>
        <span>价格 <strong>{formatMoney(latest.value)}</strong></span>
        <span>涨跌幅 <strong className={latestRate && latestRate > 0 ? "up" : latestRate && latestRate < 0 ? "down" : ""}>{formatPercent(latestRate)}</strong></span>
        {latestAverage != null && <span>均价 <strong className="futures-average">{formatMoney(latestAverage)}</strong></span>}
        <span>{baseline === undefined ? "参考价缺失" : <>参考价 <strong>{formatMoney(baseline)}</strong></>}</span>
      </div>}
      <div className="chart" style={{ height: 300 }} ref={container} />
    </>
  );
}

export type TrendChartProps = {
  labels: string[];
  values: number[];
  volumes?: number[];
  baseline?: number;
  baselineLabel?: string;
  digits?: number;
  height?: number;
  emptyText?: string;
  average?: (number | null)[];
  area?: boolean;
};

export function TrendChart({
  labels,
  values,
  volumes,
  baseline,
  baselineLabel = "昨收",
  digits = 2,
  height = 340,
  emptyText = "暂无分时数据",
  average,
  area = true
}: TrendChartProps) {
  const palette = usePalette();
  const { container, instance } = useChart();
  const showVolume = Boolean(volumes && volumes.length > 1);

  const option = useMemo<echarts.EChartsOption>(() => {
    if (values.length < 2) {
      return {
        title: {
          text: emptyText,
          left: "center",
          top: "middle",
          textStyle: { color: palette.muted, fontSize: 13, fontWeight: "normal" }
        }
      };
    }
    const floor = Math.min(...values, baseline ?? Number.POSITIVE_INFINITY);
    const ceiling = Math.max(...values, baseline ?? Number.NEGATIVE_INFINITY);
    const span = ceiling - floor;
    const padding = Math.max(span * 0.06, Math.abs(ceiling) * 0.0008, 0.0001);
    const yMin = floor - padding;
    const yMax = ceiling + padding;
    const series: echarts.SeriesOption[] = [
      {
        name: "点位",
        type: "line",
        data: values,
        symbol: "none",
        lineStyle: { width: 1.8, color: palette.brand },
        areaStyle: area
          ? {
              color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
                { offset: 0, color: "rgba(63,106,216,0.16)" },
                { offset: 1, color: "rgba(255,255,255,0)" }
              ])
            }
          : undefined,
        markLine:
          baseline !== undefined
            ? {
                silent: true,
                symbol: "none",
                label: {
                  formatter: baselineLabel,
                  position: "insideEndTop",
                  color: palette.muted,
                  fontSize: 10
                },
                lineStyle: { color: palette.muted, type: "dashed", width: 1, opacity: 0.7 },
                data: [{ yAxis: baseline }]
              }
            : undefined
      }
    ];
    if (average && average.length === values.length) {
      series.push({
        name: "均价",
        type: "line",
        data: average,
        symbol: "none",
        lineStyle: { width: 1.1, color: "#c79536", opacity: 0.9 }
      });
    }
    if (showVolume) {
      const directions = (volumes ?? []).map((_, index) => {
        const current = values[index];
        const previous = index > 0 ? values[index - 1] : current;
        return current >= previous ? palette.up : palette.down;
      });
      series.push({
        name: "成交量",
        type: "bar",
        xAxisIndex: 1,
        yAxisIndex: 1,
        data: (volumes ?? []).map((value, index) => ({
          value: Math.round(value / 10_000),
          itemStyle: { color: directions[index], opacity: 0.72 }
        })),
        barMaxWidth: 5
      });
    }
    return {
      animation: false,
      backgroundColor: "transparent",
      grid: showVolume
        ? [
            { left: 62, right: 24, top: 20, height: "58%" },
            { left: 62, right: 24, top: "76%", height: "12%" }
          ]
        : [{ left: 62, right: 24, top: 20, bottom: 34 }],
      axisPointer: { link: [{ xAxisIndex: "all" }] },
      tooltip: {
        trigger: "axis",
        backgroundColor: palette.tooltip,
        borderWidth: 0,
        textStyle: { color: "#f8fafc", fontSize: 12 },
        formatter: (params) => {
          const list = Array.isArray(params) ? params : [params];
          const index = (list[0] as { dataIndex: number }).dataIndex;
          const lines = [`<b>${labels[index] ?? ""}</b>`];
          if (values[index] !== undefined) lines.push(`点位 ${values[index].toFixed(digits)}`);
          const mean = average?.[index];
          if (mean != null) lines.push(`均价 ${mean.toFixed(digits)}`);
          if (baseline !== undefined && baseline !== 0) {
            const percent = ((values[index] - baseline) / baseline) * 100;
            lines.push(`涨跌 ${percent >= 0 ? "+" : ""}${percent.toFixed(2)}%`);
          }
          if (volumes?.[index] !== undefined) {
            lines.push(`成交 ${(volumes[index] / 10_000).toFixed(0)} 万`);
          }
          return lines.join("<br/>");
        }
      },
      xAxis: showVolume
        ? [
            {
              type: "category",
              data: labels,
              boundaryGap: false,
              axisLine: { lineStyle: { color: palette.line } },
              axisTick: { show: false },
              axisLabel: { show: false }
            },
            {
              type: "category",
              gridIndex: 1,
              data: labels,
              boundaryGap: false,
              axisLine: { lineStyle: { color: palette.line } },
              axisTick: { show: false },
              axisLabel: {
                color: palette.muted,
                fontSize: 10,
                interval: Math.max(Math.floor(labels.length / 7) - 1, 0)
              }
            }
          ]
        : {
            type: "category",
            data: labels,
            boundaryGap: false,
            axisLine: { lineStyle: { color: palette.line } },
            axisTick: { show: false },
            axisLabel: {
              color: palette.muted,
              fontSize: 10,
              interval: Math.max(Math.floor(labels.length / 7) - 1, 0)
            }
          },
      yAxis: showVolume
        ? [
            {
              type: "value",
              min: yMin,
              max: yMax,
              axisLine: { show: false },
              axisTick: { show: false },
              splitLine: { lineStyle: { color: palette.line, opacity: 0.65 } },
              axisLabel: { color: palette.muted, fontSize: 10, formatter: (value: number) => value.toFixed(digits) }
            },
            {
              type: "value",
              gridIndex: 1,
              axisLine: { show: false },
              axisTick: { show: false },
              splitLine: { show: false },
              axisLabel: { color: palette.muted, fontSize: 9, showMinLabel: false, showMaxLabel: false }
            }
          ]
        : {
            type: "value",
            min: yMin,
            max: yMax,
            axisLine: { show: false },
            axisTick: { show: false },
            splitLine: { lineStyle: { color: palette.line, opacity: 0.65 } },
            axisLabel: { color: palette.muted, fontSize: 10, formatter: (value: number) => value.toFixed(digits) }
          },
      series
    };
  }, [labels, values, volumes, baseline, baselineLabel, digits, emptyText, average, area, showVolume, palette]);

  useEffect(() => {
    instance.current?.setOption(option, true);
  }, [option]);

  return <div className="chart" style={{ height }} ref={container} />;
}

export type CandlePoint = {
  label: string;
  open: number;
  close: number;
  low: number;
  high: number;
};

export function CandleChart({ candles, height = 320 }: { candles: CandlePoint[]; height?: number }) {
  const palette = usePalette();
  const { container, instance } = useChart();

  const option = useMemo<echarts.EChartsOption>(() => {
    if (candles.length === 0) {
      return {
        title: {
          text: "暂无 K 线",
          left: "center",
          top: "middle",
          textStyle: { color: palette.muted, fontSize: 13, fontWeight: "normal" }
        }
      };
    }
    return {
      animation: false,
      backgroundColor: "transparent",
      grid: { left: 62, right: 20, top: 20, bottom: 44 },
      tooltip: {
        trigger: "axis",
        axisPointer: { type: "cross" },
        backgroundColor: palette.tooltip,
        borderWidth: 0,
        textStyle: { color: "#f8fafc", fontSize: 12 },
        formatter: (params) => {
          const list = Array.isArray(params) ? params : [params];
          const index = (list[0] as { dataIndex: number }).dataIndex;
          const candle = candles[index];
          if (!candle) return "";
          return [
            `<b>${candle.label}</b>`,
            `开 ${candle.open.toFixed(2)}`,
            `高 ${candle.high.toFixed(2)}`,
            `低 ${candle.low.toFixed(2)}`,
            `收 ${candle.close.toFixed(2)}`
          ].join("<br/>");
        }
      },
      dataZoom: candles.length > 80
        ? [{ type: "inside", start: Math.max(0, 100 - (90 / candles.length) * 100), end: 100 }]
        : undefined,
      xAxis: {
        type: "category",
        data: candles.map((candle) => candle.label),
        axisLine: { lineStyle: { color: palette.line } },
        axisTick: { show: false },
        axisLabel: {
          color: palette.muted,
          fontSize: 10,
          interval: Math.max(Math.floor(candles.length / 6) - 1, 0)
        }
      },
      yAxis: {
        type: "value",
        scale: true,
        axisLine: { show: false },
        axisTick: { show: false },
        splitLine: { lineStyle: { color: palette.line, opacity: 0.65 } },
        axisLabel: { color: palette.muted, fontSize: 10 }
      },
      series: [
        {
          type: "candlestick",
          data: candles.map((candle) => [candle.open, candle.close, candle.low, candle.high]),
          itemStyle: {
            color: palette.up,
            color0: palette.down,
            borderColor: palette.up,
            borderColor0: palette.down
          }
        }
      ]
    };
  }, [candles, palette]);

  useEffect(() => {
    instance.current?.setOption(option, true);
  }, [option]);

  return <div className="chart" style={{ height }} ref={container} />;
}

export function MacdChart({
  labels,
  histogram,
  dif,
  dea,
  height = 190
}: {
  labels: string[];
  histogram: number[];
  dif: number[];
  dea: number[];
  height?: number;
}) {
  const palette = usePalette();
  const { container, instance } = useChart();
  const option = useMemo<echarts.EChartsOption>(() => {
    if (labels.length === 0) {
      return {
        title: {
          text: "MACD 数据不足",
          left: "center",
          top: "middle",
          textStyle: { color: palette.muted, fontSize: 13, fontWeight: "normal" }
        }
      };
    }
    return {
      animation: false,
      backgroundColor: "transparent",
      grid: { left: 56, right: 18, top: 20, bottom: 28 },
      tooltip: {
        trigger: "axis",
        backgroundColor: palette.tooltip,
        borderWidth: 0,
        textStyle: { color: "#f8fafc", fontSize: 11 }
      },
      xAxis: {
        type: "category",
        data: labels,
        axisLine: { lineStyle: { color: palette.line } },
        axisTick: { show: false },
        axisLabel: { color: palette.muted, fontSize: 9, interval: Math.max(Math.floor(labels.length / 5) - 1, 0) }
      },
      yAxis: {
        type: "value",
        axisLine: { show: false },
        axisTick: { show: false },
        splitLine: { lineStyle: { color: palette.line, opacity: 0.6 } },
        axisLabel: { color: palette.muted, fontSize: 9 }
      },
      series: [
        {
          name: "柱",
          type: "bar",
          data: histogram.map((value) => ({
            value,
            itemStyle: { color: value >= 0 ? palette.up : palette.down }
          })),
          barMaxWidth: 5
        },
        {
          name: "DIF",
          type: "line",
          data: dif,
          symbol: "none",
          lineStyle: { width: 1.2, color: "#d7a63a" }
        },
        {
          name: "DEA",
          type: "line",
          data: dea,
          symbol: "none",
          lineStyle: { width: 1.2, color: palette.brand }
        }
      ]
    };
  }, [labels, histogram, dif, dea, palette]);

  useEffect(() => {
    instance.current?.setOption(option, true);
  }, [option]);

  return <div className="chart" style={{ height }} ref={container} />;
}

export function ObservationChart({
  labels,
  nav,
  histogram,
  dif,
  dea,
  crossing,
  height = 420
}: {
  labels: string[];
  nav: number[];
  histogram: number[];
  dif: number[];
  dea: number[];
  crossing: number[];
  height?: number;
}) {
  const palette = usePalette();
  const { container, instance } = useChart();
  const option = useMemo<echarts.EChartsOption>(() => {
    if (labels.length === 0) {
      return {
        title: {
          text: "观察数据不足",
          left: "center",
          top: "middle",
          textStyle: { color: palette.muted, fontSize: 13, fontWeight: "normal" }
        }
      };
    }
    const interval = Math.max(Math.floor(labels.length / 5) - 1, 0);
    const axes = [
      {
        type: "category" as const,
        data: labels,
        gridIndex: 0,
        boundaryGap: false,
        axisLine: { lineStyle: { color: palette.line } },
        axisTick: { show: false },
        axisLabel: { show: false }
      },
      {
        type: "category" as const,
        data: labels,
        gridIndex: 1,
        boundaryGap: false,
        axisLine: { lineStyle: { color: palette.line } },
        axisTick: { show: false },
        axisLabel: { color: palette.muted, fontSize: 9, interval }
      }
    ];
    return {
      animation: false,
      backgroundColor: "transparent",
      grid: [
        { left: 56, right: 20, top: 24, height: "42%" },
        { left: 56, right: 20, top: "60%", bottom: 28 }
      ],
      tooltip: {
        trigger: "axis",
        confine: true,
        axisPointer: { type: "line", lineStyle: { color: palette.muted, type: "dashed" } },
        formatter: (params) => {
          const point = Array.isArray(params) ? params[0] : params;
          if (!point) return "";
          const index = point.dataIndex;
          const signal = crossing[index] > 0 ? " · 金叉" : crossing[index] < 0 ? " · 死叉" : "";
          return [
            echarts.format.encodeHTML(labels[index]) + signal,
            `净值 ${nav[index].toFixed(4)}`,
            `DIF ${dif[index].toFixed(4)}　DEA ${dea[index].toFixed(4)}`,
            `MACD 柱 ${histogram[index].toFixed(4)}`
          ].join("<br>");
        },
        backgroundColor: palette.tooltip,
        borderWidth: 0,
        textStyle: { color: "#f8fafc", fontSize: 11 }
      },
      axisPointer: { link: [{ xAxisIndex: "all" }] },
      xAxis: axes,
      yAxis: [
        {
          type: "value",
          gridIndex: 0,
          scale: true,
          name: "净值",
          nameTextStyle: { color: palette.muted, fontSize: 11 },
          nameGap: 9,
          axisLine: { show: false },
          axisTick: { show: false },
          splitLine: { lineStyle: { color: palette.line, opacity: 0.6 } },
          axisLabel: { color: palette.muted, fontSize: 9 }
        },
        {
          type: "value",
          gridIndex: 1,
          name: "MACD",
          nameTextStyle: { color: palette.muted, fontSize: 11 },
          nameGap: 9,
          axisLine: { show: false },
          axisTick: { show: false },
          splitLine: { lineStyle: { color: palette.line, opacity: 0.5 } },
          axisLabel: { color: palette.muted, fontSize: 9 }
        }
      ],
      series: [
        {
          name: "净值",
          type: "line",
          xAxisIndex: 0,
          yAxisIndex: 0,
          data: nav,
          symbol: "none",
          lineStyle: { width: 2, color: palette.brand }
        },
        {
          name: "金叉",
          type: "scatter",
          xAxisIndex: 0,
          yAxisIndex: 0,
          symbol: "triangle",
          symbolSize: 11,
          tooltip: { show: false },
          data: labels.flatMap((label, index) => crossing[index] > 0
            ? [{ value: [label, nav[index]], itemStyle: { color: palette.up } }]
            : [])
        },
        {
          name: "死叉",
          type: "scatter",
          xAxisIndex: 0,
          yAxisIndex: 0,
          symbol: "triangle",
          symbolRotate: 180,
          symbolSize: 11,
          tooltip: { show: false },
          data: labels.flatMap((label, index) => crossing[index] < 0
            ? [{ value: [label, nav[index]], itemStyle: { color: palette.down } }]
            : [])
        },
        {
          name: "柱",
          type: "bar",
          xAxisIndex: 1,
          yAxisIndex: 1,
          barMaxWidth: 9,
          markLine: {
            silent: true,
            symbol: "none",
            label: { show: false },
            lineStyle: { color: palette.muted, opacity: 0.65, type: "solid" },
            data: [{ yAxis: 0 }]
          },
          data: histogram.map((value) => ({
            value,
            itemStyle: { color: value >= 0 ? `${palette.up}b8` : `${palette.down}b8` }
          }))
        },
        {
          name: "DIF",
          type: "line",
          xAxisIndex: 1,
          yAxisIndex: 1,
          data: dif,
          symbol: "none",
          lineStyle: { width: 1.6, color: "#c79536" }
        },
        {
          name: "DEA",
          type: "line",
          xAxisIndex: 1,
          yAxisIndex: 1,
          data: dea,
          symbol: "none",
          lineStyle: { width: 1.6, color: "#7a59f5" }
        }
      ]
    };
  }, [labels, nav, histogram, dif, dea, crossing, palette]);

  useEffect(() => {
    instance.current?.setOption(option, true);
  }, [option]);

  return <div className="chart" style={{ height }} ref={container} />;
}
