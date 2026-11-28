import { useRef, useState } from "react";
import { api, type BoardView } from "./api";
import { holdingsHeader, parseHoldingsImport } from "./holdingsImport";

export default function HoldingsDataImport({
  board,
  onChange
}: {
  board: BoardView;
  onChange: (board: BoardView) => void;
}) {
  const [open, setOpen] = useState(false);
  const [input, setInput] = useState("");
  const [preview, setPreview] = useState<ReturnType<typeof parseHoldingsImport>>();
  const [overwrite, setOverwrite] = useState(false);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
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

  const existing = new Map(board.rows.map((row) => [row.code, row]));
  const existingCount = preview?.rows.filter(({ code }) => existing.has(code)).length ?? 0;

  return (
    <div className="holdings-transfer">
      <p className="hint">截取支付宝、天天基金等 App 的基金持仓详情，把截图和模板提示词发给豆包等 AI。导入生成的表格前，核对份额和每份成本。</p>
      <div className="section-actions">
        <button type="button" className="ghost" disabled={busy} onClick={() => void run(async () => {
          if (await api.saveHoldingsImportTemplate()) setNotice("AI 持仓导入模板已保存。");
        })}>下载 AI 导入模板</button>
        <button type="button" className="ghost" disabled={busy} onClick={() => void run(async () => {
          const text = await api.readHoldingsImportFile();
          if (text === null) return;
          setInput(text);
          setPreview(parseHoldingsImport(text));
          setOverwrite(false);
          setOpen(true);
        })}>导入持仓文件</button>
        <button type="button" className="ghost" disabled={busy} onClick={() => setOpen(true)}>粘贴持仓文本</button>
      </div>
      {open && (
        <form className="transfer-editor" onSubmit={(event) => {
          event.preventDefault();
          setNotice("");
          setError("");
          setPreview(parseHoldingsImport(input));
        }}>
          <label htmlFor="holdings-import-text">持仓表格文本</label>
          <textarea id="holdings-import-text" rows={5} spellCheck={false} value={input}
            disabled={busy} placeholder={holdingsHeader}
            onChange={(event) => {
              setInput(event.target.value);
              setPreview(undefined);
              setOverwrite(false);
              setNotice("");
              setError("");
            }} />
          <div className="section-actions">
            <button type="submit" className="ghost" disabled={busy || !input.trim()}>预览持仓</button>
            <button type="button" className="ghost" disabled={busy} onClick={() => setOpen(false)}>收起</button>
          </div>
          {preview && preview.errors.length > 0 && (
            <div className="error" role="alert">
              <p>有 {preview.errors.length} 处格式问题，修正后可重新预览。</p>
              <ul>{preview.errors.slice(0, 20).map((message) => <li key={message}>{message}</li>)}</ul>
              {preview.errors.length > 20 && <p>已显示前 20 处问题。</p>}
            </div>
          )}
          {preview && preview.errors.length === 0 && (
            <>
              <p className="hint" role="status">
                共 {preview.rows.length} 只基金，新增 {preview.rows.length - existingCount} 只，已有 {existingCount} 只。
                请对照截图核对代码、份额和每份成本。空白字段跳过。
              </p>
              <div className="holdings-import-preview" tabIndex={0} role="region" aria-label="持仓导入预览">
                <table>
                  <thead>
                    <tr><th scope="col">代码 / 名称</th><th scope="col">导入份额</th><th scope="col">导入每份成本</th><th scope="col">当前份额</th><th scope="col">当前每份成本</th></tr>
                  </thead>
                  <tbody>{preview.rows.map((row) => {
                    const current = existing.get(row.code);
                    return (
                      <tr key={row.code}>
                        <td>{row.code} {row.name ?? current?.name} {current ? "（已有）" : "（新增）"}</td>
                        <td>{row.shares ?? "—"}</td><td>{row.cost ?? "—"}</td>
                        <td>{current?.shares ?? "—"}</td><td>{current?.cost ?? "—"}</td>
                      </tr>
                    );
                  })}</tbody>
                </table>
              </div>
              {existingCount > 0 && (
                <>
                  <label className="transfer-checkbox">
                    <input type="checkbox" checked={overwrite} disabled={busy}
                      onChange={(event) => setOverwrite(event.target.checked)} />
                    用表格中已填写的份额和成本覆盖同代码基金
                  </label>
                  <p className="hint">默认只补齐空白字段。同一基金分布在多个平台时，请先核实合计持仓。</p>
                </>
              )}
              <div className="section-actions">
                <button type="button" className="primary" disabled={busy} onClick={() => void run(async () => {
                  const { board: updated, report } = await api.importHoldings(
                    preview.rows, existingCount > 0 && overwrite
                  );
                  onChange(updated);
                  setNotice(`持仓导入完成，新增 ${report.added} 只，更新 ${report.updated} 只，${report.unchanged} 只无变化。`);
                  setOpen(false);
                  setInput("");
                  setPreview(undefined);
                  setOverwrite(false);
                })}>确认导入持仓</button>
              </div>
            </>
          )}
        </form>
      )}
      {busy && <p className="hint" role="status">正在处理持仓导入…</p>}
      {notice && <p className="hint" role="status">{notice}</p>}
      {error && <p className="error" role="alert">{error}</p>}
    </div>
  );
}
