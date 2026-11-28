import { useEffect, useState } from "react";
import { api, type DataSourceStatus } from "./api";

export default function DataSourceDialog({
  status,
  onSaved,
  onClose
}: {
  status: DataSourceStatus;
  onSaved: (status: DataSourceStatus) => void;
  onClose: () => void;
}) {
  const [current, setCurrent] = useState(status);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    setBusy(true);
    Promise.all([api.dataSources(), api.dataSourcesText()])
      .then(([next, body]) => {
        setCurrent(next);
        setText(body);
        setError("");
      })
      .catch((reason) => setError(String(reason)))
      .finally(() => setBusy(false));
  }, []);

  const save = async () => {
    setBusy(true);
    setNotice("");
    setError("");
    try {
      const next = await api.saveDataSources(text);
      setCurrent(next);
      onSaved(next);
      setNotice("已保存并应用。下一次刷新会使用新的数据源。");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  const clear = async () => {
    if (!window.confirm("清空数据源配置？清空后看板不会继续获取行情，直到重新导入配置。")) return;
    setBusy(true);
    setNotice("");
    setError("");
    try {
      const next = await api.clearDataSources();
      setCurrent(next);
      onSaved(next);
      setText(await api.dataSourcesText());
      setNotice("已清空数据源配置。");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  const restoreDefaults = async () => {
    if (!window.confirm("用安装包内置的接口配置覆盖当前配置？")) return;
    setBusy(true);
    setNotice("");
    setError("");
    try {
      const next = await api.resetDataSources();
      setCurrent(next);
      onSaved(next);
      setText(await api.dataSourcesText());
      setNotice("已恢复内置默认配置，并立即应用。");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal transfer-modal data-source-modal" onClick={(event) => event.stopPropagation()}>
        <header className="sheet-head">
          <h2>数据源配置</h2>
          <button className="sheet-done" onClick={onClose}>完成</button>
        </header>

        <div className={`data-source-state ${current.configured ? "ok" : "warn"}`}>
          <strong>{current.configured ? "已配置" : "尚未配置"}</strong>
          <span>{current.label || "未命名配置"}</span>
          {!current.configured && current.missing.length > 0 && (
            <em>缺少 {current.missing.length} 项地址</em>
          )}
        </div>

        <p className="hint data-source-path">配置文件：{current.path}</p>
        {current.error && <p className="error">{current.error}</p>}

        <p className="data-source-warning">
          数据源地址决定请求发往哪里。只使用你信任的配置；不要导入带有未知代理、登录凭据或要求关闭系统安全设置的文件。
        </p>

        <div className="transfer-editor">
          <label htmlFor="data-source-text">data-sources.json</label>
          <textarea
            id="data-source-text"
            value={text}
            onChange={(event) => setText(event.target.value)}
            disabled={busy}
            spellCheck={false}
            rows={13}
            placeholder="粘贴数据源 JSON，或选择配置文件"
          />
        </div>

        <div className="section-actions">
          {current.defaultAvailable && (
            <button type="button" className="ghost" disabled={busy} onClick={() => void restoreDefaults()}>
              恢复内置默认
            </button>
          )}
          <button
            type="button"
            className="ghost"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              setError("");
              api.readDataSourceFile()
                .then((value) => {
                  if (value !== null) setText(value);
                })
                .catch((reason) => setError(String(reason)))
                .finally(() => setBusy(false));
            }}
          >
            选择配置文件
          </button>
          <button type="button" className="primary" disabled={busy || !text.trim()} onClick={() => void save()}>
            保存并应用
          </button>
          <button type="button" className="ghost danger-text" disabled={busy} onClick={() => void clear()}>
            清空配置
          </button>
        </div>

        {notice && <p className="hint" role="status">{notice}</p>}
        {error && <p className="error" role="alert">{error}</p>}
        {!current.configured && current.missing.length > 0 && (
          <details className="data-source-missing">
            <summary>查看缺少的地址</summary>
            <p>{current.missing.join("、")}</p>
          </details>
        )}
      </div>
    </div>
  );
}
