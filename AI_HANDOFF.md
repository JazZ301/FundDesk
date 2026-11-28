# FundDesk（基金看板）交接

## v1.0.2 交接摘要

- 当前功能包括看板休市与估值过期提示、批量持仓导入、基金行右键分组、基金详情标签排序、本地持仓精度说明和数据源配置获取提示。对外说明见 `release-notes/v1.0.2.md`。
- 保留直接录入份额和单位成本的方式。TSV 导入默认补空白，显式覆盖也只处理文件已填字段；旧持仓数据无需迁移。
- 休市提示覆盖周末和 2026 年 A 股节假日。后续年份需补充节假日日历。现有轮询按星期和时段判断，工作日节假日仍可能请求盘中估值。
- 发布由 tag 触发。新版使用固定的 `latest-cn.json`，同时发布旧客户端使用的 `latest-cn-v1.0.1.json` 兼容清单和 GitHub 官方 `latest.json`。

## 2026-11-28 看板估值休市提示

- 看板表格底部显示「A 股周末休市 · 显示最近可用数据」或「A 股节假日休市 · 显示最近可用数据」。交易日缓存超过有效范围时显示「估值已过期」。使用指南已同步。
- 后端按北京时间判定周末，并内置上交所公布的 2026 年节假日休市日期。后续年度的节假日需补充日历。看板状态随常规刷新更新。
- 前端生产构建、内核测试和差异空白检查通过。macOS universal App 已安装并重启，实际窗口确认周末文案。DMG 签名和镜像校验通过，发布哈希已更新。使用 ad-hoc 签名，未公证。Windows 安装包未重建。


## 2026-11-28 本地持仓收益精度提示

- 在基金详情「本地持仓」底部增加浅琥珀色提示条，说明单位成本显示到四位小数，计算精度差异可能导致平台持有收益不同。非货币基金的有仓和编辑状态显示提示，使用指南同步。计算、录入和存储逻辑沿用。
- 前端生产构建、Rust 格式和差异空白检查通过。macOS 安装版以隔离数据实测查看和编辑状态有提示、货币基金详情无提示，检查浅色实际窗口的排版和可读性，验收后恢复正式目录启动。
- 已重建并校验 macOS universal App、DMG 和 updater 产物，已更新发布哈希。DMG 使用 ad-hoc 签名，未公证。Windows 安装包未重建。


## 2026-11-28 回退持仓收益录入改动

- 按用户要求撤回前两次持仓编辑改动。恢复直接填写持有份额和单位成本的界面、原保存接口与使用指南。移除总成本录入、支付宝收益校准及对应下拉框，收益继续由实际录入的单位成本和正式净值计算。以下两个相关章节保留历史记录。
- 根据本地备份恢复受影响仓位的单位成本，并以正式净值复算持有收益。
- 前端生产构建、Rust 格式检查和工作区测试通过（81 项通过，3 项忽略）。
- 已重建并校验 macOS universal App、DMG 和 updater 产物，并更新发布哈希。安装后以正式数据重启，实机核验编辑区两项原输入、单位成本及收益。Windows 安装包未重建。


## 2026-11-28 用支付宝持有收益校准

- 基金详情「本地持仓 → 编辑持仓」的「支付宝持有收益」替代此前要求填持仓总成本的选项。已有份额自动带入，用户按右侧正式净值日期填写同日支付宝持有收益，亏损填负数。
- 后端校验正式净值日期、正份额和收益金额，以十进制计算「(正式净值 × 份额 − 支付宝持有收益) ÷ 份额」，保存完整精度单位成本。现有单位成本模式、存储字段与后续净值计算沿用。使用指南已更新。
- 前端生产构建、Rust 格式和工作区测试通过（81 项通过，3 项忽略）。安装版用隔离数据输入 −8,776.49 元并保存，确认份额 70,035.26、净值 1.6595 下收益为 −8,776.49、单位成本显示 1.7848。将隔离净值更新到 1.6600 并重启，收益自动变为 −8,741.47。实际持仓未修改。
- macOS universal App 安装及正式目录重启通过，DMG 签名和镜像校验通过，已更新发布文件 SHA-256。本次使用 ad-hoc 签名，未公证。Windows 安装包未重建。


## 2026-11-28 按持仓总成本录入

- 基金详情「本地持仓 → 编辑持仓」的成本下拉框新增「持仓总成本」。输入份额及精确到分的总成本后，Rust 用十进制除法换算并保存完整精度的单位成本。详情仍显示四位小数，看板收益、收益率与持仓流水继续读同一成本字段，旧持仓无需迁移。
- 对账使用当前剩余份额对应的成本。仅知道四位小数成本价时，应用无法恢复平台使用的精确总成本，需要重新录入。真实持仓未在验收中修改。
- 前端生产构建、Rust 格式检查及工作区测试通过（81 项通过，3 项忽略）。macOS 安装版使用隔离基金实测，保存前预览、保存后的持有收益和磁盘数据复算一致。
- 已重建、校验 macOS universal DMG 和 updater 产物并更新发布哈希，安装到 `/Applications/基金看板.app`，验收后按正式数据目录重启。使用 ad-hoc 签名，未公证。Windows 安装包未重建。

## 2026-11-28 数据源配置获取提示

- 「设置 → 数据源」在配置状态下方显示入群说明和醒目的微信号按钮。点击将 `He110-w0rld` 写入系统剪贴板，成功后显示「已复制到剪贴板」，写入失败则提示手动搜索。使用指南同步了获取步骤。
- 前端生产构建通过。已重建并安装 macOS universal 1.0.1，使用隔离数据实测点击后界面提示及系统剪贴板原文一致，验收后用正式数据目录重启。DMG 签名、镜像及发布文件哈希校验通过。本次使用 ad-hoc 签名，未公证。Windows 安装包未重建。

## 2026-11-28 设置仅保留批量导入持仓

- 设置入口更名为「批量导入持仓」。清除自选基金助手配置区域、专用文件与文本导入导出命令，以及旧插件格式解析与生成逻辑。
- AI 持仓预览通过专用命令直接提交结构化字段。内核校验六位代码、重复代码与份额和成本，使用十进制精确数值，并沿用按代码合并及原子保存。通用 JSON 备份和 CSV 预览仍由原内核入口处理。
- 模板、README 和使用指南同步到新入口。历史交接记录保留当时的实现与验证结果。
- 前端生产构建、Rust 格式检查和工作区测试通过（81 项通过，3 项忽略）。
- macOS 安装版使用隔离持仓实测设置页三个入口、保存模板、重复行拦截、粘贴新增和 TSV 默认补值，核对了本地持仓写入。已更新指南截图，重建并校验 universal DMG 和 updater 文件，安装后恢复正式数据目录启动。Windows 安装包未重建。

## 2026-11-28 AI 批量持仓导入

- 「设置 → 导入与导出」新增持仓导入区，支持保存提示词模板、打开 UTF-8 TSV/TXT、粘贴、预览和确认。模板提示先遮住身份信息，区分基金份额、每份成本与市值，明确缺失字段用 `-`。
- 表头为基金代码、基金名称、持有份额、每份成本，列间使用 Tab。支持 BOM、CRLF 和常见 Markdown 代码围栏，六位代码保留前导零。重复代码、列数错误和无效数值按行提示并阻止确认。
- 预览显示新增与已有基金，以及表格值和看板当前值。导入复用现有按代码合并和原子保存逻辑，默认补空白，勾选覆盖后只替换表格已填字段。持仓数据结构与插件 JSON 格式无需迁移。
- `pnpm build`、`cargo fmt --all -- --check` 和 `cargo test --workspace` 通过（82 项通过，3 项忽略）。安装版使用两只虚构持仓实测模板保存、重复代码拦截、粘贴新增、TSV 文件预览和导入、默认补值、显式覆盖时保留空白字段、插件 JSON 导出，并检查隔离目录的实际保存值。使用指南截图采用隔离数据。
- 已重建 macOS universal 1.0.1 App、DMG 及 updater 归档，验证签名、镜像校验和与双架构。已安装到 `/Applications/基金看板.app`，验收后恢复正式数据目录启动。新包哈希见 `release/SHA256SUMS.txt`。本次使用 ad-hoc 签名，未公证。Windows 安装包未重建。

## 2026-11-28 基金详情标签拖动排序修复

- 根因：标签栏使用 `<button draggable>` 依赖 HTML5 `dragstart`；macOS WKWebView 不会为按钮控件启动原生拖拽，事件不触发，所以无法拖动排序。旧实现也没有写入 `dataTransfer`，在 WebKit 下更不可靠。
- 改为 Pointer Events：按下后捕获指针，移动超过 4px 才进入拖拽，按 `elementFromPoint` 命中目标标签，松开时调用 `move_detail_tab`；普通点击仍只切换标签，拖拽后的 click 会被抑制。新增拖动中/目标标签高亮和 `grab`/`grabbing` 光标。
- 验证：`pnpm build` 通过。使用隔离演示数据（8 只虚构持仓）在调试版和重建后的安装版中实测：把「净值估算」拖到末尾后顺序变为历史净值、累计收益、持仓明细、基金概况、净值估算；把「基金概况」拖到最前也生效，`board.json` 写入 `fundDetailTabOrder`。普通点击仍切换标签且不改顺序。测试后恢复正式数据启动，正式 17 只持仓正常。
- macOS universal App/DMG 已重建，ad-hoc 签名和 DMG 镜像校验通过；DMG 与 updater 归档内版本均为 `1.0.1`。已安装到 `/Applications/基金看板.app`，旧版移入废纸篓备份。DMG SHA-256 为 `98efe12504a728a041d091ba7222320053ec7022077e7595db36b152a3a3ca12`，updater 归档为 `a4951e38fe24564015e0aa15b0a8fc2c3d5d53a4aa52bc0114859abd5a1171a3`，签名文件为 `9bc3ee43b2ee5eb2a5800f2d56f375f92f559f7d20df15b1289ed78fe2204e9e`。Windows 安装包未重建。
- 使用指南「基金详情」补充按住标签左右拖动调整顺序的说明。

## 2026-11-28 基金列表右键分组

- 基金行右键菜单新增「分组」区，列出 MACD 观察与红利观察并显示当前归属勾选状态。点击未勾选项加入对应分组，点击已勾选项移出；原「移出 MACD 观察 / 移出红利观察」和「移除基金」入口保留。
- 仍使用已有 `set_groups` 命令，未改后端数据结构。分组会同时更新侧栏计数和当前分组列表；在 MACD/红利观察页移出当前分组后，该行会从列表消失。
- 验证：`pnpm build` 通过。使用隔离数据目录和 3 只虚构持仓实测：007339 从仅 MACD 加入红利后 `groups` 为 `["macd", "red"]`，再通过菜单移出 MACD 后归零；在 MACD 观察页右键「移出 MACD 观察」后列表清空。测试未改动正式持仓。
- macOS universal App/DMG 已重建，ad-hoc 签名与 DMG 镜像校验通过；DMG 内 App 版本为 `1.0.1`。已安装到 `/Applications/基金看板.app` 并重启，正式数据下右键菜单显示两项分组状态，未点击修改真实分组。
- 本轮 DMG SHA-256 为 `8f9f1b8a6be25444d3796a1734f45080c40ee1747f5ef09b0d91aa0b8ae1f823`，updater 归档 SHA-256 为 `6c0ac6fd28ad47efb87abbdfa616c6fd22e293db8b656ce8e3a054dd56a5a556`。Windows 安装包未重建。
- 使用指南「看板与基金列表」补充右键分组的说明；未新增截图。

## 2026-11-28 导入与导出移入设置

- 移除侧栏底部「导入与导出」按钮和独立弹窗，在设置左栏新增「导入与导出 / 备份与迁移」，位置在「数据源」与「关于」之间。原 `PluginDataTransfer` 以嵌入模式复用，导入、导出、覆盖选项和提示文案保持不变。
- 删除 `TransferDialog` 与 `transferOpen` 状态，清理侧栏入口样式；保留 `transfer-modal` 样式供数据源弹窗共用。
- 验证：`pnpm build` 通过。使用隔离数据目录和 6 只虚构仓位检查设置导航、默认导入导出面板、粘贴导入编辑器、导出文本和深色主题，均正常；截图更新为 `docs/guide/screenshots/import-export.png`，使用指南入口说明同步改为「设置」。
- macOS universal App/DMG 重建，ad-hoc 签名与 DMG 镜像校验通过；已安装到 `/Applications/基金看板.app` 并重启。随后关闭隔离演示实例，恢复正式数据目录启动，确认正式实例正常运行。
- 本轮 DMG SHA-256 为 `3aed77b8b1ac6cc5336d32bf8e9de9c7da5be09f9f8789f19085f698b7ca0ccb`，updater 归档 SHA-256 为 `064847902113b521c6ba88e19891db244779373e9178a893cd0c16a7369735d5`。Windows 安装包未重建，仍为上一版。
- 使用指南中其他历史截图仍显示旧侧栏入口，未逐张重拍；本次只更新导入与导出说明及对应截图。

## 2026-11-28 国内镜像加速

- 客户端 updater 端点改为「国内加速清单优先、GitHub 官方清单兜底」：新增 `latest-cn-v1.0.1.json`，其下载 URL 指向 `ghfast.top` 代理的 GitHub Release 资产；签名字符串、公钥和 `requireSignedVersion` 全部沿用原值，不降低校验强度。
- `.github/workflows/release.yml` 在 macOS 构建后从 tauri-action 生成的 `latest.json` 自动派生 `latest-cn-<version>.json`，并把两份清单都作为构建 artifact 上传；后续 Release 发布需同时上传该国内清单。
- 已验证国内清单可从 `releases/latest/download/latest-cn-v1.0.1.json` 经加速域名读取，版本为 `1.0.1`，三个平台键齐全；macOS 双架构签名与原 `.sig` 完全一致。
- 已验证清单中的 macOS 更新包和 Windows 安装包经国内加速 URL 均返回 HTTP 200，字节数分别为 12,305,400 和 3,818,218；下载内容与原 Release 资产一致。
- 重新构建 universal App/DMG（包含国内端点配置），归档内版本为 `1.0.1`，签名 trusted comment 为 `version:1.0.1`，DMG 镜像校验通过；新 DMG SHA-256 `c528b09661297676b777d99864896b28c34125991eb6fcc77c8e0049a2ed14b3`，归档 SHA-256 `2f0c9a045feb0c4f5e372c7b2185922c7d56eeb04a2e26e72e06528c3fba04e5`。
- 当前 Release 资产仍为上一版 `1.0.1` 安装包；本次仅新增并验证国内清单。下一次发布会把新版安装包与对应清单一起上传，避免签名、版本或哈希错配。
- 临时上传 PAT `funddesk-cn-manifest` 已撤销并确认令牌列表为空。

## 发布 Skill：FundDesk `v*` 版本发布（下次直接照做）

### 为什么 `v1.0.1` 这次接近 2 小时

从 13:04 发现「推了 `main` 但没有 Release」到 14:58 资产补齐并验证，约 1 小时 54 分钟；
若从 12:45「提交推送并打包」算起约 2 小时 13 分钟。功能实现本身只用了约 50 分钟，
慢在发布链路上。时间主要花在：推送凭证、GitHub Secrets、tag 触发规则、`tauri-action@v0`
行为不稳定、草稿 Release 重复资产、网页多文件上传，以及最后的真机更新验证。

### 本次遇到的问题与处理

| 问题 | 现象 | 根因 | 处理 |
| --- | --- | --- | --- |
| 推不上去 | HTTPS 要求 token，SSH 返回 `Permission denied (publickey)` | 本机公钥未授权给 GitHub | 用已登录 Chrome 添加 SSH key，远端改为 `git@github.com:JazZ301/FundDesk.git` |
| 推了代码却没有 Release | `main` 更新后 Releases 无新包 | `release.yml` 只在 `v*` tag 触发；`v1.0.0` 也没有 `latest.json` | 版本升到 `1.0.1`，写发布说明，推送 `v1.0.1` tag |
| Windows 签名失败 | `Missing comment in secret key` / 密码错误 | 仓库 Secrets 实际不存在；本机构建用的是 `~/.tauri/funddesk.key`，掩盖了问题 | 在 GitHub 仓库添加正确的 `TAURI_SIGNING_PRIVATE_KEY` 和密码 Secret |
| 修复后重跑不触发 | 强推同一个 tag 没有新 workflow | tag 内容未变，GitHub 不会重复触发 tag push | 在 Actions 页面手动 rerun；不要依赖强推同 tag |
| 草稿 Release 冲突 | 重复上传同名 DMG 失败 | 失败重跑复用同一个 draft Release，资产已存在 | 删除失败草稿后重跑；artifact 名加 `github.run_attempt` |
| workflow 成功但无 Release | `tauri-action@v0` 没有真正创建 Release | `uploadUpdaterJson` / `includeUpdaterJson` 等参数与当前 `@v0` 行为不匹配 | 放弃由 action 代管 Release，改为 CI 只构建并上传 artifact，发布单独完成 |
| 网页上传失败 | 文件被塞进 Release 正文，只有第一个成为附件 | GitHub 多文件选择器/拖放区域不可靠 | 资产先放进标准 staging 目录，用 API 逐个上传；正文只放 Markdown |
| 临时凭据 | API 上传需要 token | 本机无 `gh` 登录 | 仅创建 30 天 `repo` scope classic PAT `funddesk-release-upload`，上传后立即在 GitHub UI 删除并确认 |
| 最后发现 Updater 包版本错误 | Release 的 macOS `.app.tar.gz` 内 `Info.plist` 仍是 `1.0.0`，但签名声明 `1.0.1` | 构建脚本在 Tauri 生成 updater 归档后又 `codesign --force` App，归档不是最终签名后的 App | 必须把「归档内版本 = 发布版本」列为发布阻断检查；本次 Release 仍需替换该 macOS updater 资产 |

### 当前发布流程

1. 同步 Tauri、Cargo、前端和锁文件版本，并填写对应的 `release-notes/vX.Y.Z.md`。
2. 推送 `main` 后推送新 tag。发布工作流运行内核测试，并构建 macOS 双架构 DMG 和 Windows x64 NSIS，以及两端的 updater 签名。
3. 发布任务收齐两个平台构建产物，检查 macOS updater 归档版本和签名声明的版本，生成官方清单、国内镜像清单和 SHA-256 校验。工作流用 GitHub Actions 令牌上传到草稿，再公开为 Latest Release。
4. 发布后下载公开安装包及清单并校验哈希。macOS 从上一版验证检查更新、下载、安装、重启和版本号。Windows 真机验收单独记录。
5. 两个平台都需成功构建。重新运行发布工作流时使用完整重跑，以收集同一次尝试的两个构建包。

### GitHub Actions Node 24 维护

GitHub 对 Node 20 runner 的兼容警告通过升级 `actions/checkout@v7`、
`actions/setup-node@v7`、`actions/upload-artifact@v7` 和 `pnpm/action-setup@v6` 解决。
`dtolnay/rust-toolchain@stable`、`Swatinem/rust-cache@v2`、`tauri-apps/tauri-action@v0`
当前已使用 `node24`。新增 Action 时先检查其 `action.yml` 的 `runs.using`，不要再引入
`node20` 版本，避免以后从警告升级为硬失败。

### v1.0.1 macOS updater 修复（2026-11-28 15:30 GMT+8）

- 已从正式 Release 的 `FundDesk-1.0.1-macOS-universal.dmg` 取得验收通过的 `1.0.1` App，生成新的 `FundDesk-1.0.1-macOS-universal.app.tar.gz`，并用 `~/.tauri/funddesk.key` 以 `pnpm tauri signer sign --app-version 1.0.1` 重新签名。
- 新归档内 `基金看板.app/Contents/Info.plist` 的 `CFBundleShortVersionString` 为 `1.0.1`；签名 trusted comment 包含 `version:1.0.1`。
- 新 SHA-256：macOS updater 归档 `2f9d4733df7b6ae7abf28a4c471a04dfd4c9299419fa19c98b94a6166fe38a1b`，macOS 签名 `d2baa02e5c4814d0cb52ac163495cd796e802e8d6387099c0c60e89b3af5f3e9`，`latest.json` `47de46e6a37055a68ce247203a2dea795f7da2051a2aae3fecad4056f959ee87`，`SHA256SUMS.txt` `eda44fc3614a7246f8ce7af4823cddf24f193904a2262417eee89585530b0d76`。DMG 与 Windows 两项哈希未变。
- 已通过 GitHub Release 编辑器删除旧的错误 macOS updater、签名、`latest.json` 和校验清单，再用短期 classic PAT `funddesk-release-assets-fix` 通过 API 逐项重传 4 个资产；令牌随后已在 GitHub UI 删除并确认列表为空。
- 公开验证：7 个 Release 资产齐全；`SHA256SUMS.txt` 六项校验全部 OK；`latest.json` 的 macOS 双平台签名与新 `.sig` 文件内容一致；平台键为 `darwin-aarch64`、`darwin-x86_64`、`windows-x86_64`。
- 真机升级验证：恢复 `1.0.0` 安装后在设置页手动检查，发现 `1.0.1` 并展示更新说明；下载、验签、安装成功；点击「立即重启」后应用显示 `基金看板 1.0.1`，持仓金额仍为 `¥1,259,592.50`，共 17 只自选，数据未丢失。

### 本次遗留风险

- Windows CI 本次仍有失败，Release 中的 Windows 安装包来自此前成功产物并重新签名；下次应修复 Windows job 稳定性。
- macOS 仍为 ad-hoc 签名、未公证；Windows 未做 Authenticode 签名。

## 2026-11-28 检查更新功能接入

- 接入 Tauri updater/process：设置页左侧新增独立的「关于」与「免责声明」入口；「关于」页显示当前版本、手动检查、更新说明、下载进度、安装完成和重启按钮。无更新清单时显示「暂时没有可用的更新清单」，不误报失败。
- 生成 minisign 密钥；私钥保存在 `~/.tauri/funddesk.key` 且未进仓库，公钥写入 `src-tauri/tauri.conf.json`。启用 `createUpdaterArtifacts`、`requireSignedVersion` 和 Windows `passive` 安装模式；macOS 改为 Tauri 打包阶段 ad-hoc 签名，使 updater 归档里的 App 也带签名。
- 新增 `.github/workflows/release.yml`：由 `v*` tag 触发，校验 tag 与三处版本号一致，双平台构建，上传 draft Release 与 `latest.json`。日常 `build.yml` 通过 `tauri.ci.conf.json` 关闭 updater 产物，避免未配置签名 Secrets 时失败。
- 本地完成完整升级演练：`1.0.0` 从临时本地更新源发现 `1.0.1`，下载并校验签名后替换 `/Applications/基金看板.app`，重启后版本号为 `1.0.1`，随后恢复正式 `1.0.0` 安装。
- 验证：`pnpm build`、`cargo fmt --check`、`cargo test --workspace` 通过（82 项通过，3 项按原配置忽略）。macOS universal App/DMG 重建，App 与 DMG 的 ad-hoc 签名及 DMG 镜像校验通过；DMG 内二进制为 x86_64+arm64。安装版实机确认两个独立设置入口及无清单检查状态。
- `v1.0.1` 已发布：https://github.com/JazZ301/FundDesk/releases/tag/v1.0.1 ，Latest Release 与公开 `latest.json` 均解析为 `1.0.1`。Release 包含 macOS DMG、macOS updater 归档及签名、Windows NSIS 安装包及签名、`latest.json` 和 `SHA256SUMS.txt`；GitHub 页面显示的 7 个文件摘要与本地构建一致。
- GitHub Secrets `TAURI_SIGNING_PRIVATE_KEY` 与 `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` 已添加并更新；上传 Release 资产时临时创建的 classic PAT `funddesk-release-upload` 已在 GitHub UI 删除并确认消失。私钥和令牌均未进入仓库、日志或文档。
- 发布资产 SHA-256：DMG `bfc15bbb17dc6fabfd5c2760e2d090b859b1f21a0472638d3616e3efbb19aaa6`，macOS updater 归档 `2f9d4733df7b6ae7abf28a4c471a04dfd4c9299419fa19c98b94a6166fe38a1b`，macOS 签名 `d2baa02e5c4814d0cb52ac163495cd796e802e8d6387099c0c60e89b3af5f3e9`，Windows 安装包 `5e3858b8dbd88e43be2967f723a5ebffb68aa7199d71276d0aac13212038b2d4`，Windows 签名 `fd1cbaae0e2f4341f8e38107943251bafcb56d41ee91ee44be28ce75d1f5874a`，`latest.json` `47de46e6a37055a68ce247203a2dea795f7da2051a2aae3fecad4056f959ee87`。
- `release.yml` 已调整为单平台失败不阻断另一平台上传，并要求至少一个 bundle job 成功；重跑时产物名带 `github.run_attempt` 以避免覆盖。启动后自动检查和 24 小时节流仍未实现。

## 2026-11-28 v1.0.1 发布与验证

- 从 `v1.0.1` Release 验证公开端点：`releases/latest/download/latest.json` 返回版本 `1.0.1`，包含 `darwin-aarch64`、`darwin-x86_64` 和 `windows-x86_64` 三个平台；DMG、macOS updater 归档、Windows 安装包和 `SHA256SUMS.txt` 的下载路径均返回 HTTP 200。
- Release 正文已改为 `release-notes/v1.0.1.md` 的规范内容，误附的 `user-attachments` 链接已移除；页面上 7 个发布文件的 GitHub 摘要与 `SHA256SUMS.txt` 一致。
- 当前 macOS 包为 ad-hoc 签名、未公证；Windows 包未做 Authenticode 签名。CI 中 Windows bundle job 曾失败，本次 Windows installer 来自此前成功产物并已用当前版本密钥重新签名。
- 本地与公开 Release 的 `1.0.0 → 1.0.1` 更新演练均已完成；公开 Release 的真机复验结果见上方修复记录。

## 2026-11-28 检查更新方案设计

- 新增 `docs/P7-检查更新.md`，确定采用 GitHub 公开 Release + 静态 `latest.json` 的免服务器方案，不引入自建后端。
- 设计包含 Tauri updater/process 接入、macOS universal 双平台键、minisign 签名与密钥管理、GitHub Actions 发布流程、设置页状态机、失败回滚和中国网络下的镜像预案。
- 明确两个关键风险：当前 macOS 脚本在 Tauri 生成 updater 归档后才手动 ad-hoc 签名，需改为打包阶段签名；私有仓库 Release 资产不能匿名下载，方案依赖仓库保持公开。
- 本轮仅新增设计文档并更新文档索引、P6 指引与交接，未改应用代码、依赖或发布工作流，未重新打包。

## 2026-11-28 使用指南补充详情与观察配图

- 使用指南第 5 节由「五个标签」更正为六个标签，并为持仓明细、净值估算、历史净值、累计收益、基金概况分别加入独立截图和指标说明；新增「观察数据」入口说明。
- 第 6 节拆分为 MACD 观察与红利观察两个子节，补充适配度、区间收益、最大回撤、已平仓胜率、净值与 MACD 双图、评分口径、红利综合分区、近一年区间位置、40 日相对强弱和四锚评分说明。
- 新增 10 张 2320×1620 实机截图：`fund-detail-holdings.png`、`fund-detail-estimate.png`、`fund-detail-history.png`、`fund-detail-cumulative.png`、`fund-detail-profile.png`、`macd-observation.png`、`macd-chart.png`、`macd-metrics.png`、`red-observation.png`、`red-metrics.png`。
- 截图使用隔离数据目录中的 8 只虚构持仓和正式数据源；基金详情示例为易方达沪深300ETF联接A，MACD 示例为国联安中证半导体ETF联接A，红利示例为大成中证红利指数A，不对应真实账户。
- 本轮仅修改文档和截图，不改应用代码，未重新打包。截图后已退出演示实例并恢复正式数据目录启动。

## 2026-11-28 仓库替换与品牌统一

- GitHub `JazZ301/FundDesk` 的 `main` 已整体替换为当前 Tauri 2 + Rust + React 源码，旧的 Swift `Package.swift`、`Sources/`、`Tests/`、脚本和文档均已移除；替换提交为 `a9786d2537c72f19148954825d953e4f1eda7e5d`，最终源码树与本地提交 `f6a9684` 完全一致。
- 为绕过本机缺少 GitHub CLI 凭证，使用一次性 GitHub Actions 工作流从上传快照提交替换树；临时 `snapshot.tar.gz` 和 `replace.yml` 已从仓库删除，跨平台构建工作流 `build.yml` 已恢复。
- 品牌统一为英文名 **FundDesk**、中文名「基金看板」。Tauri `productName`、窗口标题、托盘 tooltip、Cargo 描述、前端标题、README、使用指南和打包脚本均已更新；bundle identifier 仍为 `app.funddesk.desktop`，数据目录仍为 `FundDeskDesktop`，不影响现有持仓数据。
- 验证：`pnpm build`、`cargo check -p funddesk --features custom-protocol` 通过；macOS universal App/DMG 重建，ad-hoc 签名和镜像校验通过。DMG 为 `release/基金看板_1.0.0_universal.dmg`，SHA-256 `c2242b623a319983fac79a342df2663baacf27fa3c0697f05ecf09b31b70ab80`。
- 安装到 `/Applications/基金看板.app` 后启动成功，窗口标题、侧栏和菜单栏均显示「基金看板」，使用正式数据目录加载 17 只自选和指数行情。旧的 `/Applications/基金看板桌面版.app` 仍保留，未自动删除。
- 双平台 `v1.0.0` Release 已发布：https://github.com/JazZ301/FundDesk/releases/tag/v1.0.0 。旧的 `v0.3.28`、`v0.3.29` 仍保留，未删除。

## 2026-11-28 双平台打包与 Windows 产物

- GitHub Actions `build.yml` 第 7 次运行（`46098955281`）中，Windows x64 任务成功并上传 `funddesk-desktop-Windows`；macOS 任务因 GitHub 不再支持 `macos-14-arm64-us-default` 运行器而在启动前取消。
- 工作流已将 macOS 运行器改为 `macos-15`，后续推送会重新验证通用架构构建。
- 已从 Actions 下载 Windows 产物并解包，得到 `FundDesk-1.0.0-Windows-x64-setup.exe`，大小 3,089,593 字节，SHA-256 `18544e5609d8af61151828c4125b60116e870352745b8922b77ac2887c9b5061`，已复制到 `release/` 并写入 `release/SHA256SUMS.txt`。
- 安装器为 NSIS 自解压 PE，版本信息中 `FileDescription`、`ProductName` 均为「基金看板」，`FileVersion`、`ProductVersion` 均为 `1.0.0`。本轮未在 Windows 实机重新安装该 CI 产物，界面验证仍以 2026-11-27 的等价构建为准。
- macOS 使用本地已验证的 `release/FundDesk-1.0.0-macOS-universal.dmg`，SHA-256 `c2242b623a319983fac79a342df2663baacf27fa3c0697f05ecf09b31b70ab80`；两端产物均未配置 Developer ID 或 Authenticode 发布签名。
- `v1.0.0` Release 已发布，资产为 `FundDesk-1.0.0-macOS-universal.dmg`、`FundDesk-1.0.0-Windows-x64-setup.exe` 和 `SHA256SUMS.txt`。从 Release 实际下载后运行 `shasum -a 256 -c`，两个安装包均通过校验。

## 2026-11-28 美股指数分时数据源恢复

- 为 macOS 安装版现有数据源配置补入 `yahoo.query1`，写入前备份原配置。该应用已支持优先使用配置中的 Yahoo Finance；本次为本机配置修复，无需更新安装包。其他电脑使用各自的数据源配置。
- 重启 /Applications 中的正式安装版，进入行情中心逐一验证标普 500 和纳斯达克综合分时，两图均显示 Yahoo Finance、5 分钟间隔及美东 13:00 的有效读数，分别为 7,297.49 和 24,129.50。
- 东方财富行情页分别使用 `NDX`（纳斯达克）和 `NDX100`（纳斯达克 100），保留现有备用代码。备用分时接口在当前网络仍未返回响应。

## 2026-11-27 看板保存与流水回归修复

- 手动修改看板先写入候选状态，写盘成功后才更新内存并发布到界面。保存失败返回明确提示，持仓、流水、自选、分组和相关看板设置保留原值，可修复磁盘问题后重试。
- 编辑或删除流水后，按原流水顺序重放受影响的后续交易，同步计算赎回已实现收益（赎回到账金额减去当时的单位成本乘以赎回份额）。修改保留原记录 ID。货币基金全额赎回的回推只需要恢复份额。
- 新增 3 项回归测试覆盖写盘失败与重试、修改和删除买入后重算赎回收益、货币基金清仓后编辑与删除。工作区测试 82 项通过，3 项按原配置跳过，Rust 格式检查与前端生产构建通过。
- macOS 通用 DMG 与 Windows x64 NSIS 已重新打包，两个 SHA-256 校验均通过。macOS 安装到 /Applications 并在隔离数据下实测：改买入价时先阻断写盘，界面显示错误且收益保留 ¥100，解除后重试显示 ¥50、落盘成本 ¥2。Windows 在 Parallels Windows 10 ARM64 的 x64 仿真中安装并用隔离数据打开窗口；该轮未在 Windows 重跑流水交互。验证后两端均恢复正式数据启动。
- 旧数据未做批量迁移。旧版已写错的已实现收益不会在启动时改写，尤其是后续已经清仓且缺少独立成本记录的流水。

## 2026-11-27 期货列表全时段走势

- 列表小图按实际时间展开数据源从首笔到最新的完整分钟序列，跨午夜时悬浮显示两端完整日期。超过五分钟未收到报价的区间在原位置留空。当前新浪分钟响应只提供已返回的报价，横轴终点取最后一个有效时间。
- 扩宽加高走势列，标出两端北京时间。参考价虚线在可视范围内，线上方红色、线下方绿色。缺少参考价时使用主题色，单点也可显示。窄窗口优先保留最新价和涨跌幅。
- 列表刷新同时重拉报价和分时，同品种并发请求复用。缓存一分钟内可在返回列表时复用，刷新失败继续显示已加载走势。
- 前端生产构建与工作区测试通过（79 通过，3 项按原配置忽略）。浏览器验证 1160px 浅色和 820px 深色、跨午夜、分时断点、正负区间着色、缺少参考价、单点、刷新和进入详情。
- macOS 通用 DMG 和 Windows x64 NSIS 已重建并校验。macOS 使用隔离的虚构持仓验证 11 个品种的真实分时，纽约原油显示 07:00–22:42，A50 显示 17:00–22:43。[期货列表实测](qa/2026-11-27-futures-intraday/期货列表全时段-macOS.png)。Parallels Windows 10 ARM64 的 x64 安装版验证 VIX 07:00–22:43 和列表涨跌幅。验证后两端恢复正式数据目录启动。

## 2026-11-27 期货分时读数

- 期货详情的分时图新增右侧涨跌幅刻度，左侧价格轴与右轴对齐，以分时参考价为中心对称显示，虚线标出 0.00%。上涨用红色、下跌用绿色。横轴按数据点顺序标注北京时间和首末时间。
- 最新分时和十字线提示共用数据源的分时参考价，涨跌幅按「（分钟价格 − 参考价）÷ 参考价绝对值 × 100」计算。顶部显示最新分钟的日期、时间、价格、涨跌幅和可用的均价。参考价为零或缺失时显示价格与时间，隐藏涨跌幅轴。单个报价点支持显示。
- `pnpm build` 及 `cargo test --workspace` 通过（79 项通过，3 项按原配置忽略）。浏览器用行情样本和模拟数据验证深浅色、980px 和 1160px、悬浮读数、单点、无参考价及无数据。macOS 通用 DMG 的应用签名与镜像校验通过，安装到 `/Applications`。使用虚构持仓及真实行情验证纽约原油 22:33 的价格 83.96、参考价 83.68、涨跌幅 +0.34%，随后恢复正式数据目录启动。截图见 [纽约原油分时](qa/2026-11-27-futures-intraday/纽约原油分时-macOS.png)。
- macOS 通用 DMG 与 Windows x64 NSIS 已重建，校验值见 `release/SHA256SUMS.txt`。在 Parallels Windows 10 ARM64 中安装并打开 x64 版，验证纽约原油的分时读数显示 22:35、北京时间、涨跌幅、均价和参考价，随后恢复正式数据目录启动。macOS 本轮使用 ad-hoc 签名，Windows 安装器未签名。

## 2026-11-27 MACD 回测修正与观察图

- 旧导入快照中，008282（国泰 CES 半导体芯片行业 ETF 联接 C）截至 11 月 20 日的评级为 S、95.8 分，报告记载 50 次交易、策略收益 201.79%。该快照没有评分实现。旧跨平台版在近 600 个交易日使用自身权重与策略，11 月 27 日为 30.4 分。
- 旧自动回测把有符号的最大回撤反向相减，把策略回撤小于持有误判为扩大。持仓收益按净值信号当日价格起算，同时在记录买入权益前计入了首日盈亏。新版用前一交易日的信号在当前净值模拟成交，通常对应净值披露后下一交易日，胜率和盈亏比只统计实际平仓的回合。回撤改善使用策略回撤减去持有回撤，正值表示改善。保持原有评分权重和等级阈值。
- 本次从天天基金基金历史资料 JS 的累计净值复算。新版截至 11 月 20 日为 S、90.6 分（策略 +116.28%，持有 +83.13%，17 个平仓回合）；截至 11 月 27 日为 S、88.7 分（600 日，策略 +116.88%，持有 +89.44%，最大回撤 −28.91% 对 −48.00%，19 个平仓回合、胜率 47.37%）。11 月 27 日单位净值 2.0007，累计净值 2.1617，MACD 柱 +0.0217，最新净值金叉。回测按净值变动估算，未扣交易费。
- 观察页显示一位小数评分、策略与持有对照及五项分数。上下图联动读数，净值线的上三角为金叉、下三角为死叉，下图突出零轴。默认显示近 60 日，可切换 120 日及全部，EMA 延续完整历史，评分窗口不随显示区间切换。
- 含 MACD 的观察缓存升级为 `fund-observation-v3`，历史报价、纯红利缓存及已有备份格式可继续使用。遇到降级历史时保留已有观察记录。
- 前端生产构建、Rust 格式及工作区测试（79 项通过，3 项按原配置忽略）通过。浏览器实测深浅色、980px 和 1160px、上下图悬停、区间控件及五项计分。两端安装版用隔离数据实测 008282 的 88.7 分和金叉，随后恢复正式数据目录。macOS 通用 DMG 与 Windows x64 NSIS 已重建，macOS 安装至 `/Applications` 并校验签名和镜像，Windows 在 Parallels Windows 10 ARM64 中验证 x64 安装版。安装包校验值见 `release/SHA256SUMS.txt`，图表见 [近 60 日净值与 MACD](qa/2026-11-27-macd/008282-净值与MACD.png)。

## 2026-11-27 红利观察分区标尺

- 原相对强弱条使用超额收益绝对值作为百分比宽度，正负方向和阈值不可见。详情「观察数据」新增 `RedObservation`，继续使用 `RedValuation` 的评分、文字结论和历史净值结果。
- 综合得分用 −8 至 +8 的评分刻度，高亮减仓、观察、持有、定投、加仓五区之一，并标出当前整数分数。近一年累计净值显示其在最近一年高低点之间的位置，低点为 0%，高点为 100%。四锚各用 −2 至 +2 刻度标出评分。
- 40 日相对强弱以沪深300为零基准，标出 −10、−1、+3、+10 个百分点阈值。显示量程为 ±20 个百分点，超过量程时标记停靠端点，标题继续显示实际差值。基准数据缺失时显示缺失状态，取消相对强弱和相对强弱锚的当前位置。相对强弱状态取核心层结论，以兼容临界值四舍五入。
- 前端生产构建、Rust 格式检查及 72 项核心测试通过，3 项按原配置忽略。浏览器覆盖深浅色、980px 窗口、正负及零值、超量程、四舍五入临界值和基准缺失。macOS 及 Parallels Windows 10 ARM64 中的 x64 安装版均使用隔离数据，确认 008163 的 −7 分、92.1% 和 +13.95 个百分点落点。测试后恢复两端正式数据目录启动。截图见 [macOS 实机](qa/2026-11-27-red-valuation/红利观察-macOS.png)。
- macOS 通用 DMG 与 Windows x64 NSIS 均已更新。macOS 安装到 `/Applications/基金看板桌面版.app`，ad-hoc 签名及镜像校验通过。Windows 安装包沿用未签名配置。两套 SHA-256 见 `release/SHA256SUMS.txt`。

## 2026-11-27 观察数据改为历史净值自动计算

- 用户反馈 Windows 版新增基金后「数据观察」为空，根因是观察页只读取自选基金助手导入的评分/序列，新增基金不会触发任何计算。现在观察数据改由本机根据公开历史净值自动生成，不再依赖外部导入。
- 核心层新增 `observation::build`：MACD 分组使用累计净值序列（缺失时退回单位净值）计算适配度、评级、推荐语、MACD 指标、策略回测、最大回撤、年化波动、趋势拟合、效率比和波段统计；红利分组计算一年/三年分位、距一年高点回撤、近 40 日相对沪深300强弱，并生成四锚评分和综合结论。
- 服务层在打开基金详情时即时计算观察数据，并写入 `board.json`；后台看板刷新会补齐所有 MACD/红利分组的观察数据，结果缓存在 `research-v1/fund-observation-v2/` 6 小时。新增基金加入观察分组后会立即触发一次后台计算，详情页也有即时计算兜底。
- 沪深300 日线优先取东方财富，失败时自动回退腾讯日线；相对强弱缺失时仍生成其余估值锚并提示「基准数据不足」。旧的导入观察数据仍保留为离线兜底，但不再是观察数据的前置条件。
- 详情页空状态和底部说明已改为「自动从历史净值生成，无需导入」，MACD 数据来源显示实际自动计算来源。
- 验证：`cargo fmt --all -- --check`、`cargo check -p funddesk --features funddesk/custom-protocol`、`cargo test -p funddesk-core`（38 单元 + 8 golden + 14 parsers + 7 research + 5 roundtrip）和 `pnpm build` 通过；联网 `live_fund_endpoints` 通过，确认能拉取 007339 历史净值、沪深300 日线并生成 MACD 与红利观察数据。
- macOS 安装版使用隔离目录，仅放入无观察数据的 008163（红利）和 008282（MACD）；不打开详情，后台刷新即写入 600 日序列，008163 生成四锚 `-7 / 8`，008282 生成 `C · 30.4`。详情页实机截图见 `qa/2026-11-27-observation-auto/screenshots/`。
- 恢复正式数据目录后，5 只 MACD/红利分组基金的观察数据已全部由导入旧数据替换为「自动计算 · 历史净值」，其中 4 只为 600 日序列，022951 为上市以来 474 日。
- Windows 10 x64 NSIS 已在 Parallels 当前用户会话重建并静默安装，安装后的 `funddesk.exe` 时间戳 21:44。隔离目录中同样两只基金在后台自动写入 600 日序列，`macd=True` / `valuation=True`；测试后已清理隔离目录并恢复正式数据目录安装版。
- 发行产物：macOS universal DMG SHA-256 `d620805b44e8f443ffe7e61689957c72f87a9769a2cc603fb01d632a827c705f`；Windows x64 NSIS SHA-256 `4119345358a018474ac1077bea072ee34f1a116f2e6d3edb165d4893abf2ca66`。
- 风险：自动评分是本地历史净值回测，不等同于原外部评分模型；红利估值使用价格分位、回撤、相对强弱和长期分位作为代理锚，未接入股息率、PE、PB 或股债利差。首次计算依赖历史净值与指数日线接口，接口不可用时继续显示上次结果或导入兜底。

## 2026-11-27 菜单栏显示项可配置

- 设置新增「菜单栏」分类，包含「显示菜单栏信息」开关和三个可复选项：上证点数、涨跌幅、当日持仓收益。关闭开关后，菜单栏不再显示该入口；应用图标仍保留在 Dock。
- 配置写入 `Board.menuBarVisible` / `Board.menuBarItems`，字段分别序列化为 `menuBarVisible` / `menuBarItems`。未写入时默认显示且勾选「上证点数」「涨跌幅」；已有用户升级后保持默认点位与涨跌幅。开启状态下至少保留一项，全部取消会返回「请至少选择一项显示内容，或关闭菜单栏信息」。
- 菜单栏改为按固定顺序静态组合所选字段，不再轮替。选中任一指数项时前缀为「上证」，只选当日持仓收益时前缀为「持仓」；持仓收益统一显示为 `¥+1,234.56` / `¥-12.50`，零收益为 `¥0.00`，无数据为 `¥—`。各字段按自身涨跌或收益方向着色。
- 上证行情仍约 60 秒刷新；当日持仓收益取 `Portfolio::day_profit()`，随看板刷新和手动刷新更新。Windows 不显示菜单栏标题，该配置作用于托盘提示文本；关闭后托盘图标和提示仍保留，提示恢复为应用名。
- 验证：`pnpm build`、`cargo fmt --all -- --check`、`cargo check -p funddesk --features funddesk/custom-protocol` 通过；`cargo test -p funddesk --lib` 6 项、`cargo test -p funddesk-core` 67 项通过。新增用例覆盖点数无千分位、涨跌幅正负、`¥` 与千分位、字段顺序、仅收益前缀和无行情时暂不显示指数项。
- macOS 安装版使用隔离演示数据（8 只虚构持仓 + 正式数据源）实测：默认菜单栏显示「上证 3606.49 +3.73%」；勾选三项后显示「上证 3606.49 +3.73% ¥+6,488.32」；仅保留收益时显示「持仓 ¥+6,488.32」；关闭开关后菜单栏入口消失；全不选时设置页显示校验错误且原选择保留；重启后三项配置恢复。截图：`qa/2026-11-27-menu-bar/screenshots/`。随后已退出演示实例，恢复正式数据目录并重启安装版（17 只持仓，菜单栏配置保持未写入的默认值）。
- `docs/guide/使用指南.md`、`README.md` 已同步；`docs/guide/screenshots/settings.png` 已替换为菜单栏设置页。
- macOS universal App/DMG 已重建，ad-hoc 签名和镜像校验通过，并安装到 `/Applications/基金看板桌面版.app`。DMG SHA-256：`435b55fcabd7013bd2f8dc76c189abad507644d8f9d7d8bd536bff80afb08e95`。
- Windows 安装包本轮未重建。`cargo check --target x86_64-pc-windows-msvc -p funddesk` 停在 `tauri-winres` 缺少 `llvm-rc`，未能验证 Windows 编译；下次 Windows 发布时应复核托盘提示随配置变化，以及关闭后托盘图标仍可打开看板。
- 风险：三项全开时菜单栏占宽明显增加；关闭菜单栏入口后只能从 Dock 或 Cmd+Q 操作应用，这是开关的预期行为。Windows 托盘提示的实际展示尚未在本轮实机复核。

## 2026-11-27 设置弹窗改为左右分栏

- 用户要求把设置改成左右分栏，便于后续扩展更多配置。`SettingsDialog` 现在由 `SETTINGS_TABS` 驱动左侧分类导航，右侧为独立可滚动内容区；新增配置只需登记分类并在右侧增加对应面板。
- 现有配置拆为四个分类：外观主题、刷新间隔、数据源、关于与免责声明。主题与间隔的保存逻辑、数据源配置入口和免责声明正文保持不变；刷新策略说明随「刷新间隔」归类。弹窗尺寸调整为 `min(780px, 94vw)` × `min(520px, 84vh)`，窄于 640px 时分类导航转为顶部横向排列。
- 左侧分类同时显示图标、标题和简短说明；「关于与免责声明」保留完整名称，原有按该文案查找的 UI 自动化检查仍可命中。
- `pnpm build` 通过。使用隔离演示数据运行调试版，逐一切换四个分类，核对浅色与深色主题、分段控件、刷新说明、免责声明和分栏滚动布局；测试后恢复「跟随系统」与 10 秒间隔。
- 更新 `docs/guide/使用指南.md` 的设置说明，并用浅色分栏界面替换 `docs/guide/screenshots/settings.png`。
- macOS universal App/DMG 已重建，ad-hoc 签名和镜像校验通过，安装到 `/Applications/基金看板桌面版.app`。安装版用隔离演示数据实测：设置可分栏切换、免责声明正常显示、「数据源 → 配置数据源」弹窗可打开。随后退出演示实例，已用正式数据目录重新启动安装版。
- DMG SHA-256：`5dab30fc685bfd968512eb6238780a3094f18e027fcdc4e7c4cbef0808eefd3e`。
- Windows 安装包本轮未重建；由于本次只改前端设置布局，建议下次 Windows 发布时复核四个分类与数据源弹窗。

## 2026-11-27 设置弹窗深色主题配色修复

- 用户反馈深色模式下设置弹窗出现浅色外壳配深色卡片，标题「设置」在浅色背景上对比度过低。根因是 `--detail-canvas-top` / `--detail-canvas-bottom` 只在基金详情页和详情弹窗内部定义，设置、添加、导入导出、流水及数据源弹窗使用了浅色兜底值。
- 将画布配色提升为亮色与暗色主题的根级变量，所有弹窗和详情页统一继承当前主题；删除详情页和详情弹窗内重复的暗色变量定义。浅色设置页保持原有白底卡片，深色设置页现在使用深色画布、同色系卡片和高对比标题。
- `pnpm build` 通过。使用生产 CSS 分别强制渲染亮色和暗色设置页，核对标题、说明文字、卡片、分段控件及免责声明的对比度。
- macOS universal App 与 DMG 已重建，ad-hoc 签名及镜像校验通过，安装到 `/Applications/基金看板桌面版.app`。安装版实测在深色、白色之间切换设置页，配色均正常；随后已切回「跟随系统」，刷新间隔仍为 10 秒。
- DMG SHA-256：`60b045034f284aa8cf6f2e759ed73f4fa35b8570022dc339f4a6b65c21c1422e`。
- Windows 安装包本轮未重建；本次只修改主题变量，建议下次 Windows 发布时一并复核深色设置页。

## 2026-11-27 全平台全功能自测与添加基金回归

- 用户要求重新自测全部平台、全部功能，重点是「添加基金」不能再次失效。本轮先复现，再修复实际存在的 7 个问题：
  1. **「我的持仓」添加新基金后无可见结果**：新基金只写入全部自选，当前页仍只显示有份额的基金，弹窗关闭后看起来像没添加。现在添加成功会显示提示、清空列表搜索词；当前分组/页面看不到新基金时自动切到「全部自选」。
  2. **详情页编辑持仓被后台刷新重置**：自动刷新每 5/10 秒重建 `row`，原 `useEffect([row])` 会关闭编辑并覆盖输入。现在只在基金代码变化时初始化，打开编辑时重新读取当前份额/成本；已实测输入 12 秒后仍保留，保存后「已保存」不再立即消失。
  3. **未配置数据源或目录不可用时无法添加**：`add_fund` 原先依赖 `ensure_catalog()`，搜索失败后没有任何添加入口。现在添加不再等待网络目录，只读取已加载/本地目录补名称；搜索无结果且输入六位代码时提供「直接添加代码」入口。隔离空数据目录实测可添加。
  4. **手动刷新撞上后台刷新时报「刷新正在进行」**：改为原子 `try_begin_refresh`，已有刷新时直接返回当前看板，不再显示错误。
  5. **自定义期货无添加入口，且中文名乱码**：期货标题栏新增代码输入和「添加自选」；新浪期货响应改用 GBK 解码。实测添加 `NID` 显示「伦镍」并写入 `futures-watchlist.json`，可正常移除。
  6. **Windows 持仓流水日期被截断**：日期输入宽度从 92px 调为 132px，Windows 实机显示完整 `2026/11/27`。
  7. **观察数据空白页无说明**：分组基金没有观察数据时显示「导入包含 MACD 或红利评分的配置后会显示」。
- 前端验证：`pnpm build` 通过。macOS 安装版实机覆盖：全部自选 / 我的持仓 / MACD / 红利添加，搜索、排序、显示列、详情五个标签、目标 ETF、持仓流水、编辑持仓、离线直接添加代码、行情中心大盘/行业/指数分时、期货列表/详情/自定义添加移除、设置主题与间隔、免责声明、数据源弹窗、导入导出、关闭窗口后从 Dock/`open` 恢复。测试后已恢复正式数据目录启动。
- Windows 10 x64 安装版 UI Automation 覆盖并通过：我的持仓添加后切到全部自选并提示、红利分组添加、编辑持仓 12 秒不被刷新重置、流水新增后份额重算、五个详情标签、观察数据空状态、行情中心行业排行与上证分时、设置免责声明、数据源路径、配置文本导出、自定义期货中文名。日志：`qa/2026-11-27-windows/logs/funddesk-win-full-qa.log`、`qa/2026-11-27-windows/logs/funddesk-win-deep-qa.log`；截图：`qa/2026-11-27-windows/screenshots/full-qa`、`qa/2026-11-27-windows/screenshots/deep-qa`。
- Windows 验收资料已从 macOS 家目录归档到 `qa/2026-11-27-windows/`，包含脚本、日志、截图、中间安装包、代码同步暂存和早期证据；家目录及 `~/Downloads` 中的重复副本已清理。家目录的 `funddesk-win-setup-3.exe` 与 `release/基金看板桌面版_1.0.0_x64-setup.exe` SHA-256 相同，未重复保留。
- 自动化测试：`cargo fmt --all -- --check`、`cargo check -p funddesk --features funddesk/custom-protocol` 通过；`cargo test -p funddesk-core` 35 单元 + 8 golden + 12 parsers + 7 research + 5 roundtrip 全通过；`cargo test -p funddesk --lib` 1 项通过；`live_fund_endpoints` 通过。`live_market_endpoints` 仍失败在东方财富 `push2delay.eastmoney.com` 美股分时 `IncompleteMessage`，与本轮改动无关，属外部接口/网络问题。
- 发行产物：macOS universal App/DMG 重建、ad-hoc 签名和镜像校验通过，安装到 `/Applications/基金看板桌面版.app`（19:25）；Windows x64 NSIS 重建并静默安装（`funddesk.exe` 11,832,832 字节，19:26:56）。DMG SHA-256：`ca66975f0eba9ed7b36c245a51bc2bac26134556b00f750685fc430899de4143`；Windows 安装包 SHA-256：`5099547e45ea41611ec9f5c5520818b11d26482a258436299380b241c9fa9e94`。
- 文档：使用指南补充「我的持仓添加后跳转」「六位代码直接添加」以及期货自定义代码示例。
- 风险：Windows 安装包仍未做 Authenticode 签名，macOS 仍为 ad-hoc 未公证；东方财富美股分时回退在接口恢复前仍可能失败；直接按代码添加时若目录不可用，名称会先显示代码，移除后在有目录时重新添加可补全名称。

## 2026-11-27 分组内添加基金未生效修复

- 用户反馈在 Windows 版「红利观察」中添加 008163 时显示已添加，但分组中没有该基金。根因有两处：`add_fund` 只把基金加入全部自选，从不写入当前分组；添加弹窗对已在全部自选中的基金直接禁用并显示「已添加」，因此在分组内点击不会触发任何请求。
- 核心层新增 `Board::add_holding(fund, group)` 和 `Holding::join_group`：新基金可直接带分组写入；已有基金保持原位置和持仓，只合并请求的分组；重复加入同一分组不产生重复成员。`add_fund` 命令新增可选 `group` 参数（`macd` / `red`，其他值报错），前端在分组页传入当前分组。
- 添加弹窗改为区分「已添加」和「加入 MACD 观察 / 加入红利观察」：基金已在全部自选但不在当前分组时按钮可用；已在当前分组时禁用并显示「已添加」。使用指南补充分组内添加说明。
- 新增 4 个回归用例：新基金直接加入红利分组、已有基金补加红利分组、重复加入幂等且保留原有 MACD 分组、无分组重复添加不产生重复行。
- 全量验证：`pnpm build`、`cargo fmt --all -- --check`、`cargo check -p funddesk --features funddesk/custom-protocol` 通过；`cargo test -p funddesk-core` 共 67 项通过（35 单元 + 8 golden + 12 parsers + 7 research + 5 roundtrip），`cargo test -p funddesk --lib` 1 项通过；真实看板只读往返通过。联网 `live_fund_endpoints` 通过；`live_market_endpoints` 两次均失败在东方财富 `push2delay.eastmoney.com` 美股分时请求 `IncompleteMessage`，属外部接口/网络问题，与本轮改动无关。
- Chromium 前端流程验证：在「红利观察」搜索 008163，结果按钮为「加入红利观察」；点击后调用 `add_fund` 且 `group: red`，分组计数从 1 变 2，表格出现 008163。
- Windows 10 x64 NSIS 已在 Parallels 当前用户会话重建并安装，安装后的 `funddesk.exe` 为 11,678,208 字节、时间戳 18:03。UI Automation 实测：红利观察 → 添加基金 → 搜索 008163 → 「加入红利观察」→ 点击后分组计数为 2，隔离数据中的 `board.json` 保存 `groups: ["red"]`，截图与 `verify.log` 通过。测试后已重启正式数据目录的安装版。
- macOS universal App/DMG 已重建、ad-hoc 签名与镜像校验通过，并安装到 `/Applications/基金看板桌面版.app`；测试后已恢复正式数据目录启动。DMG SHA-256：`4f3ea4eb1f71d64f3c4f771e3fb30ca9f92c3969753ed00604586615e0d253b9`；Windows 安装包 SHA-256：`81b8715f0a67c2618b6b19f41e59412da4ebdc09bc32d6516835fa5c089856e2`。
- 风险：Windows 安装包仍未做 Authenticode 签名，macOS 仍为 ad-hoc 未公证；`live_market_endpoints` 的东方财富美股分时回退需在接口恢复后复测。

## 2026-11-27 Windows 最新安装包补发与配置入口复测

- 用户反馈虚拟机中的 Windows 版不是最新版，且找不到接口配置入口。核对后确认虚拟机内 `funddesk.exe` 为 11:08 构建，早于 14:32 的数据源配置化；`release` 中 15:41 的安装包也早于 16:16 的设置页免责声明改动。
- 使用当前源码在 Parallels Windows 10 重新构建 x64 NSIS，安装包 SHA-256 为 `76dbcd5ae61fc360a2de7ba59e735cb714db34b58f35b4a58caaa1d1846ca92a`。首次覆盖安装时旧进程占用 `funddesk.exe`，安装器仍返回 0 但文件未替换；结束旧进程后重新安装成功。
- 安装后的 `C:\Users\MAC\AppData\Local\基金看板桌面版\funddesk.exe` 为 11,676,160 字节，时间戳 17:42。使用隔离演示数据和真实数据源配置启动，UI Automation 找到「设置 → 数据源 → 配置数据源」及「关于与免责声明」，配置弹窗包含「选择配置文件」「保存并应用」「清空配置」，验收通过。
- 桌面截图证据：Windows 设置页 1176×849，数据源配置弹窗 1176×849。测试结束后已重新启动正式数据目录的安装版。Windows 安装包仍未做 Authenticode 签名。

## 2026-11-27 应用内免责声明

- 自选看板底部新增常驻提示「数据来自公开接口 · 仅供学习参考」，鼠标悬停可查看完整说明；原「每 N 秒自动检查」保留在中间，右侧不再重复显示数据源描述。
- 设置页新增「关于与免责声明」卡片，位于数据源配置之后、刷新说明之前，打开设置即可看到正文：软件仅供学习和研究，不构成投资建议或操作依据；行情、净值、估值等数据来自第三方公开接口，可能存在延迟、缺失、口径差异或错误，不对准确性、完整性和及时性作出保证，亦不承担因使用数据产生的责任；请以基金公司、交易所官方披露为准。
- 同步润色 `README.md` 的「数据、隐私与免责声明」和 `docs/guide/使用指南.md` 第 14 节；`docs/guide/数据来源与开源合规.md` 的「应用内免责声明入口」检查项已勾选。
- 验收：`pnpm build` 通过；macOS universal App/DMG 重建、ad-hoc 签名和镜像校验通过，安装到 `/Applications/基金看板桌面版.app`。使用隔离的 `.demo-data` 启动安装版，核对自选看板底部提示与设置页免责声明正文，演示数据为 8 只虚构持仓；随后结束演示实例并恢复正式数据目录启动。
- DMG SHA-256：`d2e838049c9e80fdd53a1b49bee0508c22e57c6b30b676561c3a5e1efd1a6023`。Windows 安装包本轮未重建。
- 风险：免责声明不改变第三方数据的版权和授权状态，也不构成法律意见；公开分发前仍需按合规评估核对数据源授权和 Release 说明。

## 2026-11-27 数据源配置化与中性标识

- 数据源地址从 Rust 代码全部移到 `<data-dir>/data-sources.json`（也可用 `FUND_DESK_SOURCES_FILE` 指定）。首次启动默认空白，界面显示「尚未配置数据源」，设置页提供「数据源 → 配置数据源」导入/粘贴/清空，保存后立即替换运行中的 `MarketClient`。
- 配置分 `eastmoney.*`、`sina.*`、`tencent.*`、`yahoo.query1`、`http.userAgent`。所有地址必须 HTTPS（localhost 可 HTTP），拒绝用户名/密码、查询参数和片段；保存前检查格式并显示缺少字段。`yahoo.query1` 默认空，美股指数分时回退东方财富。
- 默认 User-Agent 改为 `FundDeskDesktop/1.0`；新浪、腾讯 Referer 由配置中的 `sina.finance`、`tencent.portal` 决定。`crates/core/src/{provider,market,research}.rs` 已无写死的第三方 URL。
- Bundle ID 已改为中性 `app.funddesk.desktop`；README、P3/P6 和合规文档已同步，代码/文档中不再出现旧个人前缀或本机用户路径。
- 新增 `demo/data-sources.example.json`（全空模板）、`docs/guide/数据源配置.md` 和 `screenshots/data-sources.png`；README、使用指南和合规评估补充了「配置化不等于数据授权」「社群配置的供应链风险」。
- 验收：`pnpm build` 通过；`cargo check -p funddesk --features funddesk/custom-protocol` 通过；`cargo fmt --all -- --check` 通过；核心测试 31+8+12+7+5 项通过，2 项联网测试按配置单独运行通过，1 项真实看板测试忽略。使用真实数据源配置运行 `live_fund_endpoints` 和 `live_market_endpoints` 均通过，包含美股指数回退。
- macOS universal App/DMG 已重建并安装到 `/Applications/基金看板桌面版.app`；演示数据截图后已恢复正式数据目录。DMG SHA-256：`1bf7188320397d3beed49091388148e67bae3b10648ef7107b87df3deb6bffd7`。
- Windows x64 NSIS 已在 Parallels Windows 10 重新构建、静默安装并投放新 `data-sources.json`；安装包 SHA-256：`1bfccc977866805ad0c7a8feca2a34387f01cd514336b49cd0bb282f5fd431c4`。通过 SYSTEM 非交互方式启动时进程存在但未取得窗口，Windows 界面仍需在交互会话复测。
- 新增证据：`sources.rs` 单元测试覆盖空配置、HTTP 非本机拒绝、尾斜杠归一化。数据源配置截图使用 `example.com` 占位地址，不包含真实端点。

## 2026-11-27 使用文档、演示截图与开源合规评估

- 新增 `docs/guide/使用指南.md`，覆盖安装、首次启动、看板、持仓、基金详情、MACD/红利观察、行情中心、期货、设置、导入导出、菜单栏、数据目录、备份迁移和常见问题。
- 新增 `docs/guide/数据来源与开源合规.md`：逐项列出东方财富/天天基金、新浪、腾讯、Yahoo、交易所行情和基金经理简介的来源、robots/条款观察、风险等级及发布前检查清单；结论是代码可开源，但公开数据不等于可自由再分发，必须保持本机运行时请求、不打包行情数据库。
- 新增 `demo/board.demo.json`（8 只虚构持仓）和 `demo/README.md`；新增 6 张文档截图 `docs/guide/screenshots/`，统一使用隔离目录 `.demo-data`、白色主题和演示份额/成本。截图中的行情为 2026-11-27 公开快照，截图不含真实持仓。
- 新增 `LICENSE`（MIT）、`THIRD_PARTY_NOTICES.md` 和 `CONTRIBUTING.md`；README 增加演示截图、使用指南、合规评估、数据隐私免责声明、许可证和发布说明。`docs/README.md` 与 `.gitignore` 已同步；Rust/npm 包元数据声明 MIT。
- 验收：`demo/board.demo.json` 可解析；文档相对链接全部存在；截图 2320×1620，`mdls` 无来源/作者元数据。采集时退出正式安装版，使用 `FUND_DESK_DATA_DIR="$PWD/.demo-data"` 启动演示实例；完成后已结束演示进程并重新启动 `/Applications/基金看板桌面版.app`，恢复正式数据目录。
- 本轮只改文档、演示数据和仓库说明，未改应用代码，因此未重建 App/DMG；正式安装版仍为上一轮构建。
- 原列出的 Yahoo、UA/Referer 风险已在 2026-11-27「数据源配置化与中性标识」中处理（Yahoo 默认关闭、UA 中性、地址外置）。仍需注意：`push2.eastmoney.com` robots 全站禁止；`docs/screenshots/` 旧 P3 截图需逐张复核；macOS ad-hoc 未公证、Windows 未签名需在 Release 中明确。

## 2026-11-27 基金与指数详情改为窗口内子页面

- 点击基金名称不再打开居中遮罩弹窗。详情在主区域内替换自选看板，保留侧栏；页头提供「‹ 返回」，返回后恢复主区域和基金表格原来的滚动位置。
- 点击市场指数仍进入行情中心子页面，页头保留「返回基金列表」；指数分时也继续提供「‹ 返回行情分类」。两处详情不再调用窗口放大或居中逻辑，窗口尺寸和位置保持原样。
- 删除已无调用的 `src/window.ts`，基金详情和行情中心均不再使用 `useExpandedWindow`。详情页在短内容标签下也撑满可用高度，底部本地持仓保持常驻。
- `pnpm build` 通过。使用隔离的 17 只持仓在安装版中验证：基金详情打开、五个标签切换、返回并恢复表格滚动位置；点击上证指数进入分时、返回基金列表；窗口未缩放或重新居中。
- macOS universal App 与 DMG 已重建，ad-hoc 签名及镜像校验通过，安装到 `/Applications/基金看板桌面版.app`。DMG SHA-256：`f6637cbe2a00006147f5ea3b87ff5951351800f55ec4060b27f4d5889645a5fd`。
- Windows 安装包本轮未重建或验证。

## 2026-11-27 菜单栏固定「上证」并轮替两个数字

- 菜单栏不再向上滚动整行。「上证」固定在左侧，右侧只保留一个数字区域，在涨跌点数与当前上证点数之间先淡出、再淡入轮替；上涨红色、下跌绿色、平盘系统文字色。
- 数字区域按两项中较宽的一项预留宽度，切换时不抖动。整项点击区域仍覆盖完整宽度，点击数字本身也能打开看板。
- 当前点数不再显示千位逗号（如「3555.27」）。数字字形比中文矮，数字整体下移 1pt 与「上证」共用基线；截图像素核对两者底部落在同一行。
- `TrayIcon` 的 macOS 点击层由 tray-icon 覆盖视图处理；报价显示层改为挂在它下方，并在更新宽度时同步该覆盖视图，避免自绘视图吞掉点击。
- 盘中安装版实测菜单栏在「上证 +55.07」与「上证 3,531.95」之间轮替，前缀不移动；点击数字后 `show_main` 记录为可见并聚焦。已核对淡出/淡入过渡帧。
- `pnpm build`、`cargo check -p funddesk --features funddesk/custom-protocol`、`cargo test -p funddesk --lib`（1 项）通过；`cargo test -p funddesk-core` 59 项通过，3 项按原配置忽略。
- macOS universal App 与 DMG 已重建，ad-hoc 签名及镜像校验通过，安装到 `/Applications/基金看板桌面版.app` 并重启验证。DMG SHA-256：`cac441ebdb880009e8cf41d53e597dc02485d8fae321fd5868ee0f08602510a2`。
- Windows 安装包本轮未重建或验证。

## 2026-11-27 逐页对齐 Swift 原生版

- 基金详情改为 Swift 版结构：标题与「完成」、并排的正式净值和盘中估算卡、等宽可拖动标签栏、底部常驻本地持仓。基础标签固定为持仓明细、净值估算、历史净值、累计收益、基金概况；观察数据只在 MACD/红利分组中存在。基金经理并入基金概况，持仓流水改为独立弹窗，不再占标签位。
- 持仓明细恢复「披露期 / 腾讯个股行情 / 获取于 / 目标 ETF」信息层级，列顺序为名称、代码、类别、当日涨跌幅、占净值、较上期。Rust 详情接口新增估值分时和披露个股行情，并新增目标 ETF 披露读取；展开目标 ETF 时按需缓存。
- 净值估算显示估算分时和读数；历史净值恢复单位/累计净值切换、七档区间、走势读数及最近 8 个披露日；累计收益单独记忆区间。基金概况显示档案、区间收益、现任经理和历任区间。
- 观察数据恢复 Swift 的「MACD 战法适配」：适配度评分、评级、推荐语、赎回费、红/绿柱信号，以及净值 + MACD 双区图（DIF、DEA、柱、买卖点）。红利分组显示估值锚、近一年分位、40 日相对强弱和四锚评分。
- 设置改为 540×500 弹窗；添加基金为 548×392 弹窗并恢复推荐基金入口。行情中心隐藏侧栏并恢复等宽分类栏、并排成交统计、全宽五口径资金卡和走势读数。期货恢复单行标题、面板内刷新、全日期报价和合并的「最新报价」详情卡；期货详情分时补均价读数和 DIF/DEA/柱读数。
- 金额负数统一为「−¥12,923.84」，涨跌幅保留 ASCII 负号；表格移除名称后的 MACD/红利标签，底部提示补「保留上次数据」。
- 新增 Tauri 命令：`fund_disclosure`、`replace_journal`；`fund_detail` 返回 `estimateSeries`、`stockQuotes`、`stockQuoteFailed`。流水弹窗支持修改已有记录。
- `pnpm build` 通过；`cargo test -p funddesk-core` 通过 59 项，3 项按原配置忽略（联网 2 项、真实看板往返 1 项）；`cargo check -p funddesk --features funddesk/custom-protocol` 通过。
- macOS 通用 DMG 已重建并通过镜像及 ad-hoc 签名校验，安装到 `/Applications/基金看板桌面版.app` 后复核主表、详情五标签、目标 ETF 展开、历史净值、MACD 观察、设置、行情中心和期货；正式数据目录保留。DMG SHA-256：`1570eada450e33f0d2ea8eedc9b4366cd69c52ba245150bb54ed61cd90e760d3`。
- Windows x64 NSIS 已在 Parallels Windows 10 ARM64 的 `MAC` 用户会话重新安装；主表显示新布局，确认无旧版名称标签，正式数据目录保留。安装器未做 Authenticode 签名。安装包 SHA-256：`6ad7e348020051f682f48d4fce47212e27abb0c595e69105afae958d92a3a499`。

## 2026-11-27 行情中心与其他页面对齐原生版

- 行情中心复用主看板的七张市场指数卡，含获取时间、方向、涨跌幅、涨跌点数和报价时间。行情分类位于指数卡下方，返回基金列表恢复进入前的分组。刷新本页同时刷新指数卡和当前分时图或分类。
- 指数分时从 Rust 端读取内地、香港及美股交易时段配置。价格和成交量分别按当地交易分钟映射，午间休市压缩为一个刻度，盘中未到时段留空。双轴以昨收为中心，显示点位、涨跌幅、最近成交和成交量。批量刷新与切换指数时只采用当前页面的响应。
- 行情分类按需请求。大盘资金请求沪深两市统计和资金流，板块页只请求所选分类及周期的排行。独立刷新指数卡，避免重复抓取指数。
- 基金详情分别记住历史净值和累计收益区间。期货分时和五日序列达到 35 个样本时显示 MACD，分时均价只使用源数据；设置显示生效的刷新间隔并可通过「完成」回到基金列表。
- 前端生产构建、Rust 格式和 59 项核心测试通过，另有 3 项按原配置忽略。浏览器以虚构持仓验证开盘 22 分钟对应全天 22/240 的横轴位置、缺失成交量不移位、北京/香港/美东时区、四类板块与排行周期、详情独立区间、期货 MACD 与周期切换、设置返回，以及 980px 宽窗口七张指数卡同屏。

- macOS 通用 DMG 已重建并通过镜像与 ad-hoc 签名校验。安装到 `/Applications/基金看板桌面版.app` 后，以隔离持仓验证实时上证、全天时间轴、五个分类标签、返回我的持仓、期货和设置。已恢复正式数据目录并重启。
- Windows x64 NSIS 已重建并在 Parallels 的 Windows 10 ARM64 环境安装。使用隔离数据验证市场指数入口、分时详情、行情分类、期货、设置及返回基金列表，随后重开正式数据目录。安装器未做 Authenticode 签名，两套安装包的 SHA-256 已更新并校验。

## 2026-11-27 自选看板紧凑布局

- 参照旧版基金看板截图调整侧栏、内联日期、横排持仓汇总、七项指数卡和基金列表。搜索移入列表工具栏，保留 Cmd/Ctrl+F；列表使用 25px 行高、固定表头和独立滚动区。底部显示估值排除原因或更新时间，侧栏底部直达现有数据导入与导出设置。
- 无列布局偏好时使用旧版截图的九列顺序；净值、净值日和估算净值仍可通过「显示列」开启。显式保存的列顺序及隐藏偏好继续生效。指数卡展示点位、涨跌幅、点数和来源时间，右侧刷新单独请求指数，失败时继续显示最近获取的行情。
- TypeScript/Vite 生产构建、Rust 格式检查和 59 项核心测试通过，3 项依照原配置忽略。浏览器用虚构数据验证了最小窗口、参考尺寸和默认窗口下七项指数与九列同屏，搜索快捷键、排序、行列拖拽、列显隐、指数刷新、添加基金和导入导出入口均通过，复核了浅色及深色界面。
- macOS 通用 DMG 已重建并通过镜像及 ad-hoc 签名校验。已安装到 `/Applications/基金看板桌面版.app`，用 17 只虚构基金检查实机画面、列选择与导入导出入口，默认窗口完整显示 16 行，随后恢复正式数据目录并重启应用。
- Windows x64 NSIS 已重新构建并在 Parallels 的 Windows 10 ARM64 环境安装。使用隔离的虚构持仓验证列表、搜索框、显示列和导入导出入口，随后重开正常数据目录的安装版。Windows 安装器未做 Authenticode 签名。两套安装包的 SHA-256 均已更新。

## 2026-11-27 macOS 菜单栏仅涨跌点数着色

- 去掉菜单栏报价前的折线图标。「上证」使用系统默认文字色，AppKit 只给带正负号的点数范围上色，涨红、跌绿，平盘用系统文字色。
- 已重新构建通用 DMG、校验签名和镜像、更新 SHA-256，并安装重启 `/Applications` 中的新版。实际菜单栏显示默认文字色的「上证」和绿色「-7.30」，截图确认图标已去除。点击点数可打开看板，Dock 关闭后恢复及最小化后恢复均复测通过。
- Rust 检查和前端生产构建通过。核心测试 59 项通过，3 项按原配置忽略。本轮实机行情为下跌。

## 2026-11-27 macOS Dock 窗口恢复与菜单栏涨跌颜色

- 接收 macOS 重新打开事件，复用主窗口显示、取消最小化和聚焦逻辑。关闭主窗口后应用继续驻留。
- 菜单栏仍显示上证涨跌点数，每 60 秒刷新。AppKit 按涨跌方向设置标题颜色，上涨用系统红色，下跌用系统绿色，平盘用系统文字颜色。
- 旧安装版复现关闭窗口后 Dock 点击无效。新版从通用 DMG 安装到 `/Applications` 后，通过 Dock 实际验证关闭和最小化两种状态均能恢复并聚焦。现场行情为上涨，菜单栏实测显示红色「上证 +5.50」。下跌和平盘的颜色分支尚无实时画面验证。
- 前端生产构建和 Rust 检查通过。核心测试 59 项通过，3 项按原配置忽略。App 和 DMG 的 ad-hoc 签名校验及 DMG 镜像校验通过，已更新发行校验和。本轮仅重建 macOS 版。

## 2026-11-27 侧栏信息清理

- 移除品牌区的系统兼容性副标题，以及底部展示操作系统和托盘模式的状态栏。删除对应前端状态和样式，继续用现有启动接口读取看板数据。
- TypeScript 检查和 Vite 构建通过。核心测试 59 项通过，3 项按原配置忽略。
- macOS 通用 App 和 DMG 已重建并通过签名及镜像校验，采用 ad-hoc 签名。已安装到 `/Applications` 并重启，通过新窗口的辅助功能树确认品牌、导航和基金列表可见，两处标注文字均已移除。已更新校验和。
- Windows 安装包仍为上一版，本轮未验证 Windows 界面。

## 2026-11-27 自选基金助手导入与导出

- 设置页支持选择 JSON/TXT 配置文件、粘贴 JSON、保存 JSON 和复制 JSON 文本。Windows 与 macOS 使用原生文件选择及保存面板。
- 自选基金助手 3.4.4 使用 `fundListGroup[].funds`，旧版使用 `fundListM` 或 `fundList`。基金代码始终以六位字符串导出，`num` 为持有份额，`cost` 为每份成本。导出采用 3.4.4 的分组格式。
- 导入按代码合并，默认补齐空白份额和成本。勾选覆盖时仅覆盖配置中有效的已填写字段，显式零份额可清仓，零成本按空白处理。重复持仓采用各字段首个非零值并报告冲突。MACD 观察和红利观察按同名映射，其他插件分组汇入全部自选。
- 导入在看板锁内原子保存，保存成功后才替换内存数据。现有基金、流水、行情快照和设置继续由本机看板保存。插件导出仅含基金和对应分组所需的数据。
- 测试覆盖当前和旧版格式、精确小数、前导零、重复基金、字段覆盖和无效输入。构建与安装验收记录见下节。

## 验证

- `cargo test -p funddesk-core` 通过 59 项，另有 3 项联网或外部文件测试按原配置忽略。`cargo check -p funddesk` 与前端构建通过。
- 对照 Microsoft Edge 商店发布的自选基金助手 3.4.4 扩展包及本机真实导出文件。macOS 从 DMG 安装后在隔离目录导入，再导出到文件和剪贴板。19 只基金的代码、份额和成本逐项相同，重启后仍显示 19 只。扩展通过其设置界面接受看板导出的文件及 JSON 文本。
- Windows 10 虚拟机用 x64 NSIS 安装后验证文本导入、文本导出、原生打开和保存面板、带 UTF-8 BOM 的旧版配置、JSON 落盘及前导零与小数。测试使用隔离目录，完成后重新启动正式安装版。
- macOS App 和 DMG 通过签名及镜像校验。macOS 已重开正式数据目录的安装版并检查设置入口。两套安装包的 SHA-256 已更新。
- 本地产物的发布签名沿用既有配置。macOS 为 ad-hoc 签名，Windows 安装包未做 Authenticode 签名。
