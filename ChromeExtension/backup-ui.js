import {backupPreview, decodeBackup, exportBackup, exportPortable} from "./backup.js";
import {exportCSV, groups, mergeBoard, mergeInput} from "./imports.js";
import {applyObservations, observeFolder} from "./observations.js";
import {positive} from "./holdings.js";
import {contentRevision, loadState, restoreBackup, restorePrevious, updateState} from "./store.js";
import {button, download, errorMessage, node, show} from "./ui.js";

export function backupPanel(state, changed) {
  const message = node("output", {ariaLive:"polite"});
  const preview = node("div", {className:"stack", hidden:true});
  const restore = fileInput("选择 JSON 备份", ".json,application/json", async file => {
    const backup = decodeBackup(await file.text());
    const current = await loadState();
    const metrics = backupPreview(current.board, backup.board);
    const count = (board, type) => board.holdings.filter(row => type === "position" ? positive(row.shares) : row.groups?.includes(type)).length;
    show(preview, node("div", {className:"notice stack"},
      node("strong", {}, `v${backup.version} 备份 · ${metrics.count} 只基金`),
      node("p", {}, `新增 ${metrics.added} · 覆盖 ${metrics.replaced} · 移出 ${metrics.removed}`),
      node("small", {}, [["我的持仓","position"],...Object.entries(groups).map(([key,label]) => [label,key])]
        .map(([label,key]) => `${label} ${count(current.board,key)} → ${count(backup.board,key)}`).join(" · ")),
      node("p", {}, "恢复将替换当前看板，并保存恢复前的版本。")
    ), node("div",{className:"row"},
      button("确认恢复",async event => {
        event.currentTarget.disabled = true;
        try {
          changed(await restoreBackup(backup,contentRevision(current)),"已恢复完整备份");
        } catch (error) {
          message.textContent = errorMessage(error);
          preview.hidden = true;
        }
      },"primary"),
      button("取消",() => {preview.hidden = true;})
    ));
    preview.hidden = false;
  });
  const merge = fileInput("选择 CSV 或 JSON", ".csv,.json,text/csv,application/json", async file => {
    const incoming = await mergeInput(file);
    const current = await loadState();
    const result = mergeBoard(current.board,incoming);
    show(preview, node("div", {className:"notice"},
      `可新增 ${result.added} 只 · 跳过重复 ${result.duplicates} 只 · 无效 ${result.invalid} 条`),
      node("div",{className:"row"},
        button("确认合并",async event => {
          event.currentTarget.disabled = true;
          try {
            const next = await updateState(last => {
              if (contentRevision(last) !== contentRevision(current)) throw new Error("看板已更新，请重新预览导入。");
              return {...last,board:mergeBoard(last.board,incoming).board};
            });
            changed(next,`已导入 ${result.added} 只基金`);
          } catch (error) {message.textContent = errorMessage(error);}
        },"primary"),
        button("取消",() => {preview.hidden = true;})
      ));
    preview.hidden = false;
  });
  const folder = node("input",{type:"file",hidden:true,webkitdirectory:true,multiple:true});
  folder.addEventListener("change",async () => {
    if (!folder.files.length) return;
    const files = [...folder.files];
    folder.value = "";
    preview.hidden = true;
    message.textContent = "正在读取观察资料…";
    try {
      const {rows,warnings} = await observeFolder(files);
      const count = new Set(rows.map(item => item.fund.code)).size;
      const caption = `可导入或更新 ${count} 只基金${warnings.length ? " · 未解析 " + warnings.join(" / ") : ""}`;
      show(preview,node("p",{className:"notice"},caption),node("div",{className:"row"},
        button("确认导入观察数据",async event => {
          event.currentTarget.disabled = true;
          try {
            changed(await updateState(last => ({...last,board:applyObservations(last.board,rows)})),
              `已更新 ${count} 只观察基金${warnings.length ? " · 未解析 " + warnings.join(" / ") : ""}`);
          } catch (error) {message.textContent = errorMessage(error);}
        },"primary"),button("取消",() => {preview.hidden = true;})
      ));
      message.textContent = "";
      preview.hidden = false;
    } catch (error) {message.textContent = errorMessage(error);}
  });
  function fileInput(label, accept, handle) {
    const input = node("input", {type:"file",accept,hidden:true});
    input.addEventListener("change", async () => {
      const file = input.files[0];
      if (!file) return;
      input.value = "";
      preview.hidden = true;
      message.textContent = "正在读取文件…";
      try { await handle(file); message.textContent = ""; }
      catch (error) { message.textContent = errorMessage(error); }
    });
    return node("span", {}, button(label,() => input.click()), input);
  }
  const previous = state.restorePoint ? button("恢复上次恢复前的数据", async event => {
    if (!confirm("恢复上次恢复前的看板数据？")) return;
    event.currentTarget.disabled = true;
    try {changed(await restorePrevious(),"已还原上次恢复前的数据");}
    catch (error) {message.textContent = errorMessage(error);}
  }) : null;
  return node("section",{className:"panel stack"},node("h3",{},"备份与恢复"),
    node("div",{className:"row"},
      button("导出 v4 完整备份",() => download("基金看板完整备份.json",exportBackup(state.board))),
      button("导出 v3 轻量备份",() => download("基金看板轻量备份.json",exportPortable(state.board))),
      restore,previous
    ),node("h3",{},"自选与持仓"),
    node("div",{className:"row"},button("导出 CSV",() => download("自选与持仓.csv",exportCSV(state.board.holdings),"text/csv")),merge),
    node("div",{className:"row"},button("导入观察数据文件夹",() => folder.click()),folder),
    preview,message
  );
}
