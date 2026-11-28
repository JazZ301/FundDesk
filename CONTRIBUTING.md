# 参与开发

感谢你愿意改进 FundDesk（基金看板）。提交代码前请遵守以下约定。

## 开发

```sh
pnpm install
pnpm tauri dev
```

核心测试：

```sh
cargo test -p funddesk-core
```

## 不要提交真实数据

- 不要提交本机数据目录中的 `board.json`、`board.backup.json`、`data-sources.json`、`research-v1/`、`catalog.json`、`futures-watchlist.json`、日志或浏览器登录态。安装包默认配置 `src-tauri/resources/data-sources.json` 除外。
- 不要提交真实持仓截图、带个人路径的截图或带账号信息的导出文件。
- 截图和功能演示请使用 `demo/board.demo.json`；需要新数据时请明确标注为虚构数据。
- 测试真实看板请使用 `FUND_DESK_DATA_DIR` 指向隔离目录。

## 不要引入数据再分发

- 不要在仓库、测试夹具或 Release 中打包历史净值库、全量基金库、板块资金流库或期货数据库。
- 不要增加公共代理、镜像、批量下载或绕过登录/付费墙的功能。
- 新增数据源时，请说明来源、访问条款和缓存策略，并优先使用有正式授权的 API。

## 许可证

除非另有说明，提交的代码按仓库根目录的 MIT License 授权。
