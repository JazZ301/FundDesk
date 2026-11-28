# 演示数据

`board.demo.json` 是虚构的自选与持仓，仅用于截图、文档和功能演示，不对应任何人的真实账户。

用法：

```sh
mkdir -p .demo-data
cp demo/board.demo.json .demo-data/board.json
cp src-tauri/resources/data-sources.json .demo-data/data-sources.json
FUND_DESK_DATA_DIR="$PWD/.demo-data" pnpm tauri dev
```

已安装应用可直接指定可执行文件：

```sh
mkdir -p .demo-data
cp demo/board.demo.json .demo-data/board.json
cp src-tauri/resources/data-sources.json .demo-data/data-sources.json
FUND_DESK_DATA_DIR="$PWD/.demo-data" \
  "/Applications/基金看板.app/Contents/MacOS/funddesk"
```

份额和成本均为整齐的演示数字。`src-tauri/resources/data-sources.json` 是安装包内置的默认接口配置，全新数据目录也会自动生成同样的文件。不要把带有登录凭据或未知代理的配置提交到仓库。
