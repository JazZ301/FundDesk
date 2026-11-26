import {emptyBoard} from "./backup.js";

let connection;
function database() {
  connection ??= new Promise((resolve, reject) => {
    const request = indexedDB.open("FundDesk", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("data");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  return connection;
}

const initialState = () => ({board: emptyBoard(), restorePoint: null, revision: 0, contentRevision: 0, restoreRevision: 0});

export async function loadState() {
  const db = await database();
  return new Promise((resolve, reject) => {
    const request = db.transaction("data").objectStore("data").get("board");
    request.onsuccess = () => resolve(request.result ?? initialState());
    request.onerror = () => reject(request.error);
  });
}

export async function updateState(transform, {snapshotOnly = false} = {}) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction("data", "readwrite");
    const store = transaction.objectStore("data");
    const request = store.get("board");
    let next, failure;
    request.onsuccess = () => {
      try {
        const state = request.result ?? initialState();
        const transformed = transform(state);
        next = transformed === state ? state : {
          ...transformed,
          revision: state.revision + 1,
          contentRevision: contentRevision(state) + Number(!snapshotOnly)
        };
        store.put(next, "board");
      } catch (error) {
        failure = error;
        transaction.abort();
      }
    };
    transaction.oncomplete = () => resolve(next);
    transaction.onabort = () => reject(failure ?? transaction.error ?? new Error("保存失败"));
  });
}

export const contentRevision = state => state.contentRevision ?? state.revision;

export function restoreBackup(backup, expectedRevision) {
  return updateState(state => {
    if (contentRevision(state) !== expectedRevision) throw new Error("看板已更新，请重新预览备份。");
    let board = backup.board;
    if (backup.version === 1) {
      const codes = new Set(board.holdings.map(({fund}) => fund.code));
      board = {...state.board, ...board, snapshots: Object.fromEntries(
        Object.entries(state.board.snapshots).filter(([code]) => codes.has(code))
      )};
    }
    return {...state, board, restorePoint: state.board, restoreRevision: state.revision + 1};
  });
}

export function restorePrevious() {
  return updateState(state => {
    if (!state.restorePoint) throw new Error("没有可用的恢复点。");
    return {...state, board: state.restorePoint, restorePoint: state.board, restoreRevision: state.revision + 1};
  });
}

export async function loadMarket(key) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const request = db.transaction("data").objectStore("data").get("market:" + key);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export async function saveMarket(key, value) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction("data", "readwrite");
    transaction.objectStore("data").put({value, updatedAt: Date.now()}, "market:" + key);
    transaction.oncomplete = () => resolve();
    transaction.onabort = () => reject(transaction.error);
  });
}
