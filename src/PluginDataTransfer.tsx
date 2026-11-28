import { useRef, useState } from "react";
import { api, type BoardView } from "./api";

type TransferMode = "import" | "export";

export default function PluginDataTransfer({ onChange }: { onChange: (view: BoardView) => void }) {
  const [mode, setMode] = useState<TransferMode | null>(null);
  const [input, setInput] = useState("");
  const [output, setOutput] = useState("");
  const [overwrite, setOverwrite] = useState(false);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const outputRef = useRef<HTMLTextAreaElement>(null);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");

  async function run(action: () => Promise<void>) {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setNotice("");
    setError("");
    try {
      await action();
    } catch (reason) {
      setError(String(reason));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }

  function openImport() {
    if (busyRef.current) return;
    setMode("import");
    setNotice("");
    setError("");
  }

  return (
    <section className="panel plugin-transfer" aria-labelledby="plugin-transfer-title">
      <h3 id="plugin-transfer-title">数据导入与导出</h3>
      <p className="hint">与自选基金助手交换基金列表、持有份额、每份成本及同名观察分组。看板流水、行情和设置保存在本机。</p>
      <div className="section-actions">
        <button type="button" className="ghost" disabled={busy} onClick={() => void run(async () => {
          const text = await api.readPluginConfigFile();
          if (text !== null) {
            setInput(text);
            setMode("import");
          }
        })}>导入配置文件</button>
        <button type="button" className="ghost" disabled={busy} onClick={openImport}>粘贴配置文本</button>
        <button type="button" className="ghost" disabled={busy} onClick={() => void run(async () => {
          if (await api.exportPluginConfigFile()) setNotice("配置文件已保存。");
        })}>导出配置文件</button>
        <button type="button" className="ghost" disabled={busy} onClick={() => void run(async () => {
          setOutput(await api.exportPluginConfigText());
          setMode("export");
        })}>导出配置文本</button>
      </div>
      {mode === "import" && (
        <form className="transfer-editor" onSubmit={(event) => {
          event.preventDefault();
          if (!input.trim()) return;
          void run(async () => {
            const { board, report } = await api.importPluginConfig(input, overwrite);
            onChange(board);
            setNotice(
              `导入完成，新增 ${report.added} 只，更新 ${report.updated} 只，${report.unchanged} 只已有基金无变化。` +
              (report.invalid ? ` 已跳过 ${report.invalid} 条无效记录。` : "") +
              (report.conflicts ? ` ${report.conflicts} 只基金在配置内有不同持仓数据，采用各字段首个非零值。` : "")
            );
            setInput("");
            setOverwrite(false);
            setMode(null);
          });
        }}>
          <label htmlFor="plugin-import-text">自选基金助手配置 JSON</label>
          <textarea id="plugin-import-text" value={input} onChange={(event) => setInput(event.target.value)}
            disabled={busy} spellCheck={false} placeholder="粘贴插件导出的 JSON 文本" rows={5} />
          <label className="transfer-checkbox">
            <input type="checkbox" checked={overwrite} disabled={busy}
              onChange={(event) => setOverwrite(event.target.checked)} />
            用配置中已填写的份额和成本覆盖同代码基金
          </label>
          <p className="hint">默认保留看板已有的份额和成本，补齐空白字段。插件自定义分组里的基金会汇入全部自选。</p>
          <div className="section-actions">
            <button type="submit" className="primary" disabled={busy || !input.trim()}>确认导入</button>
            <button type="button" className="ghost" disabled={busy} onClick={() => setMode(null)}>收起</button>
          </div>
        </form>
      )}
      {mode === "export" && (
        <div className="transfer-editor">
          <label htmlFor="plugin-export-text">自选基金助手配置 JSON</label>
          <textarea id="plugin-export-text" ref={outputRef} value={output} readOnly spellCheck={false} rows={5} />
          <div className="section-actions">
            <button type="button" className="primary" disabled={busy} onClick={() => void run(async () => {
              try {
                await navigator.clipboard.writeText(output);
              } catch {
                outputRef.current?.focus();
                outputRef.current?.select();
                if (!document.execCommand("copy")) throw new Error("配置文本已选中，可使用系统快捷键复制。");
              }
              setNotice("配置文本已复制。");
            })}>复制配置文本</button>
            <button type="button" className="ghost" disabled={busy} onClick={() => setMode(null)}>收起</button>
          </div>
        </div>
      )}
      {busy && <p className="hint" role="status">正在处理配置…</p>}
      {notice && <p className="hint" role="status">{notice}</p>}
      {error && <p className="error" role="alert">{error}</p>}
    </section>
  );
}
