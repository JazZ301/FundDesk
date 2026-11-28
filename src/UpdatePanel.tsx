import { useEffect, useRef, useState } from "react";
import { getVersion } from "@tauri-apps/api/app";
import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";

type Phase =
  | "idle"
  | "checking"
  | "current"
  | "available"
  | "downloading"
  | "installing"
  | "installed"
  | "error";

const RELEASE_PAGE = "https://github.com/JazZ301/FundDesk/releases";

function formatDate(value?: string) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleDateString("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  });
}

function formatSize(value?: number) {
  if (!value || !Number.isFinite(value) || value <= 0) return "";
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(0)} KB`;
  return `${(value / 1024 / 1024).toFixed(1)} MB`;
}

function errorText(reason: unknown) {
  const text = String(reason);
  if (text.includes("Could not fetch a valid release JSON from the remote")) {
    return "暂时没有可用的更新清单。";
  }
  if (/timeout|timed out/i.test(text)) {
    return "检查更新超时，请稍后重试。";
  }
  return text || "检查更新失败，请稍后重试。";
}

export default function UpdatePanel() {
  const [version, setVersion] = useState("");
  const [phase, setPhase] = useState<Phase>("idle");
  const [update, setUpdate] = useState<Update | null>(null);
  const [message, setMessage] = useState("");
  const [checkedAt, setCheckedAt] = useState<Date | null>(null);
  const [totalBytes, setTotalBytes] = useState(0);
  const [receivedBytes, setReceivedBytes] = useState(0);
  const updateRef = useRef<Update | null>(null);

  useEffect(() => {
    void getVersion().then(setVersion).catch(() => setVersion(""));
    return () => {
      void updateRef.current?.close().catch(() => undefined);
    };
  }, []);

  const replaceUpdate = async (next: Update | null) => {
    if (updateRef.current && updateRef.current !== next) {
      await updateRef.current.close().catch(() => undefined);
    }
    updateRef.current = next;
    setUpdate(next);
  };

  const checkNow = async () => {
    if (phase === "checking" || phase === "downloading" || phase === "installing") return;
    setPhase("checking");
    setMessage("");
    setTotalBytes(0);
    setReceivedBytes(0);
    try {
      await replaceUpdate(null);
      const next = await check({ timeout: 15000 });
      await replaceUpdate(next);
      setCheckedAt(new Date());
      setPhase(next ? "available" : "current");
    } catch (reason) {
      const text = errorText(reason);
      setCheckedAt(new Date());
      setMessage(text);
      setPhase(text.startsWith("暂时没有") ? "current" : "error");
    }
  };

  const install = async () => {
    if (!update || phase === "downloading" || phase === "installing") return;
    setPhase("downloading");
    setMessage("");
    setTotalBytes(0);
    setReceivedBytes(0);
    let downloaded = 0;
    try {
      await update.downloadAndInstall((event) => {
        if (event.event === "Started") {
          setTotalBytes(event.data.contentLength ?? 0);
        } else if (event.event === "Progress") {
          downloaded += event.data.chunkLength;
          setReceivedBytes(downloaded);
        } else if (event.event === "Finished") {
          setPhase("installing");
        }
      });
      setPhase("installed");
    } catch (reason) {
      setMessage(errorText(reason));
      setPhase("error");
    }
  };

  const progress = totalBytes > 0
    ? Math.min(100, Math.round((receivedBytes / totalBytes) * 100))
    : 0;
  const busy = phase === "checking" || phase === "downloading" || phase === "installing";
  const notes = update?.body?.trim() ?? "";

  return (
    <section className="settings-card update-card">
      <h3><span className="settings-icon update-icon">↻</span>版本与更新</h3>
      <div className="update-head">
        <div>
          <strong>基金看板 {version || "—"}</strong>
          <small>
            {checkedAt
              ? `上次检查 ${checkedAt.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })}`
              : "手动检查新版本"}
          </small>
        </div>
        <button className="ghost small" onClick={() => void checkNow()} disabled={busy}>
          {phase === "checking" ? "检查中…" : "检查更新"}
        </button>
      </div>

      {phase === "current" && (
        <p className={message ? "update-status" : "update-status ok"}>
          {message || "已是最新版本。"}
        </p>
      )}
      {phase === "available" && update && (
        <>
          <p className="update-status">
            发现新版本 <b>{update.version}</b>
            {update.date ? `，发布于 ${formatDate(update.date)}` : ""}。
          </p>
          {notes && <div className="update-notes">{notes}</div>}
          <div className="update-actions">
            <button className="primary small" onClick={() => void install()}>下载并安装</button>
          </div>
        </>
      )}
      {(phase === "downloading" || phase === "installing") && (
        <div className="update-progress">
          <div className="update-progress-head">
            <span>{phase === "installing" ? "正在安装，完成后需要重启" : "正在下载更新"}</span>
            <span>{phase === "downloading" ? `${progress}%` : ""}</span>
          </div>
          <div className="update-progress-track">
            <span style={{ width: phase === "installing" ? "100%" : `${progress}%` }} />
          </div>
          {phase === "downloading" && totalBytes > 0 && (
            <small>{formatSize(receivedBytes)} / {formatSize(totalBytes)}</small>
          )}
        </div>
      )}
      {phase === "installed" && (
        <div className="update-actions">
          <p className="update-status ok">更新已安装，重启后使用新版本。</p>
          <button className="primary small" onClick={() => void relaunch()}>立即重启</button>
        </div>
      )}
      {phase === "error" && (
        <>
          <div className="update-actions">
            <p className="update-status error-text">{message}</p>
            <button
              className="ghost small"
              type="button"
              onClick={() => {
                void navigator.clipboard
                  ?.writeText(RELEASE_PAGE)
                  .then(() => setMessage("发布页地址已复制。"))
                  .catch(() => setMessage("请手动复制发布页地址。"));
              }}
            >
              复制发布页地址
            </button>
          </div>
          <p className="update-fallback">也可以访问 {RELEASE_PAGE} 手动下载。</p>
        </>
      )}
    </section>
  );
}
