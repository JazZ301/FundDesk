import { useLayoutEffect, useRef, useState } from "react";
import { api } from "./api";
import { holdingsHeader } from "./holdingsImport";
import "./usage-guide.css";

const exampleFields = ["000001", "示例基金", "1000.00", "1.2000"];

export default function UsageGuide({
  onClose,
  onImport
}: {
  onClose: () => void;
  onImport?: () => void;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const savingTemplate = useRef(false);
  const [templateStatus, setTemplateStatus] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const nativeDialog = typeof HTMLDialogElement !== "undefined"
    && typeof HTMLDialogElement.prototype.showModal === "function";

  useLayoutEffect(() => {
    const dialog = dialogRef.current;
    if (nativeDialog) {
      dialog?.showModal();
      return () => dialog?.close();
    }
    dialog?.querySelector("button")?.focus();
  }, [nativeDialog]);

  async function saveTemplate() {
    if (savingTemplate.current) return;
    savingTemplate.current = true;
    setTemplateStatus("saving");
    try {
      const saved = await api.saveHoldingsImportTemplate();
      setTemplateStatus(saved ? "saved" : "idle");
    } catch {
      setTemplateStatus("error");
    } finally {
      savingTemplate.current = false;
    }
  }

  function dismiss(action: () => void) {
    if (nativeDialog) dialogRef.current?.close();
    action();
  }

  const content = (
    <dialog className="modal usage-guide" ref={dialogRef} open={!nativeDialog}
      role="dialog" aria-modal="true" aria-labelledby="usage-guide-title"
      onCancel={(event) => {
        event.preventDefault();
        dismiss(onClose);
      }}
      onKeyDown={(event) => {
        if (nativeDialog) return;
        if (event.key === "Escape") dismiss(onClose);
        if (event.key === "Tab") {
          const buttons = event.currentTarget.querySelectorAll<HTMLButtonElement>("button:not(:disabled)");
          const first = buttons[0];
          const last = buttons[buttons.length - 1];
          if (event.shiftKey ? document.activeElement === first : document.activeElement === last) {
            event.preventDefault();
            (event.shiftKey ? last : first).focus();
          }
        }
      }}>
      <header className="sheet-head usage-guide-head">
        <h2 id="usage-guide-title">使用向导</h2>
        <button type="button" className="sheet-done" onClick={() => dismiss(onClose)} autoFocus>完成</button>
      </header>
      <div className="usage-guide-body">
        <section aria-labelledby="guide-import-title">
          <h3 id="guide-import-title">三步批量导入持仓</h3>
          <ol className="guide-steps">
            <li>
              <h4><span className="guide-step-number">1</span>截图整理基金持仓</h4>
              <div className="guide-visual guide-capture" aria-hidden="true">
                <div className="guide-capture-frame">
                  <strong>持仓详情</strong><span>演示</span>
                  <dl>
                    <dt>持有份额</dt><dd>1,000.00 份</dd>
                    <dt>成本单价</dt><dd>¥1.2000</dd>
                  </dl>
                </div>
              </div>
              <p>在支付宝、天天基金等 App 打开基金持仓详情，截下持有份额和成本单价。</p>
              <p>
                <button type="button" className="guide-template-link" aria-disabled={templateStatus === "saving"}
                  onClick={() => void saveTemplate()}>下载 AI 导入模板</button>
                ，把模板里的提示词和截图发给豆包等 AI 生成表格。
              </p>
              <p className="guide-template-status" role="status">
                {templateStatus === "saved" && "模板已保存。"}
                {templateStatus === "error" && "模板保存失败，请重试。"}
              </p>
            </li>
            <li>
              <h4><span className="guide-step-number">2</span>粘贴并预览</h4>
              <div className="guide-visual guide-paste" role="img" aria-label="生成的表格有四列：基金代码、基金名称、持有份额和每份成本">
                <table aria-hidden="true">
                  <thead><tr>{holdingsHeader.split("\t").map((label) => <th key={label}>{label}</th>)}</tr></thead>
                  <tbody><tr>{exampleFields.map((field) => <td key={field}>{field}</td>)}</tr></tbody>
                </table>
                <span className="guide-control" aria-hidden="true">预览持仓</span>
              </div>
              <p>点「粘贴持仓文本」，贴上 AI 生成的表格，再点「预览持仓」。已有 TSV 或 TXT 文件可点「导入持仓文件」。</p>
            </li>
            <li>
              <h4><span className="guide-step-number">3</span>核对并确认</h4>
              <div className="guide-visual guide-confirm" aria-hidden="true">
                <strong><span>✓</span> 000001 · 示例基金</strong>
                <div>份额 1,000.00 · 每份成本 ¥1.2000</div>
                <span className="guide-control">确认导入持仓</span>
              </div>
              <p>对照截图核对六位代码（保留开头的 0）、份额和每份成本。点「确认导入持仓」，再去「我的持仓」查看。</p>
            </li>
          </ol>
          <p className="guide-import-note">已有基金默认只补齐空白字段。需要更新已有份额或成本时，可在预览后勾选覆盖。</p>
        </section>
        <section className="guide-basics" aria-labelledby="guide-basics-title">
          <h3 id="guide-basics-title">日常怎么用</h3>
          <dl>
            <div><dt>手动录入</dt><dd>右上角「添加基金」，再点基金名称进入详情，选择「编辑持仓」。</dd></div>
            <div><dt>看收益与行情</dt><dd>「我的持仓」看持有金额和收益，「行情中心」看市场指数、板块和资金流。</dd></div>
          </dl>
        </section>
      </div>
      <footer className="usage-guide-footer">
        <button type="button" className="primary" disabled={!onImport}
          onClick={() => onImport && dismiss(onImport)}>前往批量导入持仓</button>
      </footer>
    </dialog>
  );
  return nativeDialog ? content : <div className="modal-backdrop usage-guide-fallback">{content}</div>;
}
