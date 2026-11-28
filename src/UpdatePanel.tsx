import { useCallback, useEffect, useRef, useState } from "react";
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

const CHECK_INTERVAL = 24 * 60 * 60 * 1000;
const STARTUP_DELAY = 8000;

type UpdateRecord = {
  checkedAt: number;
  availableVersion: string | null;
};

function recordKey(version: string) {
  return `funddesk:update-check:${version}`;
}

function readRecord(version: string): UpdateRecord {
  try {
    const saved = JSON.parse(localStorage.getItem(recordKey(version)) ?? "null");
    if (saved && Number.isFinite(saved.checkedAt) && saved.checkedAt > 0) {
      return {
        checkedAt: saved.checkedAt,
        availableVersion: typeof saved.availableVersion === "string" ? saved.availableVersion : null
      };
    }
  } catch {
    // The current session can still check for updates if local storage is unavailable.
  }
  return { checkedAt: 0, availableVersion: null };
}

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

export function useAppUpdater() {
  const [version, setVersion] = useState("");
  const [phase, setPhase] = useState<Phase>("idle");
  const [update, setUpdate] = useState<Update | null>(null);
  const [message, setMessage] = useState("");
  const [record, setRecord] = useState<UpdateRecord>({ checkedAt: 0, availableVersion: null });
  const recordRef = useRef(record);
  const operationInProgress = useRef(false);
  const firstAutomaticCheck = useRef(Date.now() + STARTUP_DELAY);
  const [totalBytes, setTotalBytes] = useState(0);
  const [receivedBytes, setReceivedBytes] = useState(0);
  const updateRef = useRef<Update | null>(null);

  useEffect(() => {
    let active = true;
    void getVersion().then((currentVersion) => {
      if (!active) return;
      const saved = readRecord(currentVersion);
      recordRef.current = saved;
      setRecord(saved);
      setVersion(currentVersion);
    }).catch(() => undefined);
    return () => {
      active = false;
      void updateRef.current?.close().catch(() => undefined);
    };
  }, []);

  const saveRecord = useCallback((next: UpdateRecord) => {
    recordRef.current = next;
    setRecord(next);
    if (version) {
      try {
        localStorage.setItem(recordKey(version), JSON.stringify(next));
      } catch {
        // Retain the record in memory for this session.
      }
    }
  }, [version]);

  const checkNow = useCallback(async () => {
    if (operationInProgress.current || phase === "installed") return;
    operationInProgress.current = true;
    const checkedAt = Date.now();
    saveRecord({ ...recordRef.current, checkedAt });
    setPhase("checking");
    setMessage("");
    try {
      const next = await check({ timeout: 15000 });
      void updateRef.current?.close().catch(() => undefined);
      updateRef.current = next;
      setUpdate(next);
      saveRecord({ checkedAt, availableVersion: next?.version ?? null });
      setPhase(next ? "available" : "current");
    } catch (reason) {
      setMessage(errorText(reason));
      setPhase("error");
    } finally {
      operationInProgress.current = false;
    }
  }, [phase, saveRecord]);

  useEffect(() => {
    if (!version || phase === "installed") return;
    let timer: number;
    const schedule = () => {
      window.clearTimeout(timer);
      const now = Date.now();
      const lastCheck = recordRef.current.checkedAt;
      const nextCheck = lastCheck <= now ? lastCheck + CHECK_INTERVAL : now;
      timer = window.setTimeout(() => void checkNow(), Math.max(0,
        firstAutomaticCheck.current - now, nextCheck - now));
    };
    schedule();
    window.addEventListener("focus", schedule);
    document.addEventListener("visibilitychange", schedule);
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("focus", schedule);
      document.removeEventListener("visibilitychange", schedule);
    };
  }, [version, phase, record.checkedAt, checkNow]);

  const install = async () => {
    if (!update || phase === "installed" || operationInProgress.current) return;
    operationInProgress.current = true;
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
      saveRecord({ ...recordRef.current, availableVersion: null });
      setPhase("installed");
    } catch (reason) {
      setMessage(errorText(reason));
      setPhase("error");
    } finally {
      operationInProgress.current = false;
    }
  };

  return {
    version, phase, update, message, setMessage, record, totalBytes, receivedBytes,
    checkNow, install
  };
}

export default function UpdatePanel({ updater }: { updater: ReturnType<typeof useAppUpdater> }) {
  const { version, phase, update, message, setMessage, record, totalBytes, receivedBytes,
    checkNow, install } = updater;

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
            每 24 小时自动检查
            {record.checkedAt > 0 && ` · 上次检查 ${new Date(record.checkedAt).toLocaleString("zh-CN", {
              month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit"
            })}`}
          </small>
        </div>
        <button className="ghost small" onClick={() => void checkNow()} disabled={busy || !version || phase === "installed"}>
          {phase === "checking" ? "检查中…" : "检查更新"}
        </button>
      </div>

      {phase === "current" && (
        <p className="update-status ok">已是最新版本。</p>
      )}
      {!busy && phase !== "installed" && update && (
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
      {!update && record.availableVersion && (
        <p className="update-status">上次检查发现新版本 <b>{record.availableVersion}</b>。</p>
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
