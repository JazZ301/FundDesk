# Third-Party Notices

This project uses third-party software. This file is a summary, not a replacement for the full license texts.

## Application dependencies

| Component | License | Project |
| --- | --- | --- |
| Tauri | MIT OR Apache-2.0 | https://github.com/tauri-apps/tauri |
| React, React DOM | MIT | https://github.com/facebook/react |
| ECharts | Apache-2.0 | https://github.com/apache/echarts |
| zrender | BSD-3-Clause | https://github.com/ecomfe/zrender |
| TypeScript | Apache-2.0 | https://github.com/microsoft/TypeScript |
| Vite | MIT | https://github.com/vitejs/vite |

## Rust dependencies

The Rust dependency graph is predominantly MIT, Apache-2.0, BSD, ISC, Zlib, Unicode-3.0 and MPL-2.0. MPL-2.0 components identified in `Cargo.lock` include `cssparser`, `cssparser-macros`, `dtoa-short`, `option-ext`, `selectors`; their source is available from crates.io and the corresponding upstream repositories.

No GPL-only dependency was identified in the locked dependency graph on 2026-11-27. `r-efi` is offered under MIT OR Apache-2.0 OR LGPL-2.1-or-later; this project relies on the permissive options.

## Market data

No market data, fund database, NAV history, disclosure database or futures database is licensed under this repository's MIT license. Data is requested at runtime by each user's own machine from third-party sources and remains subject to those sources' terms. See `docs/guide/数据来源与开源合规.md`.

## Binary distribution

When distributing a built application, include this notice and the full license texts of the dependencies shipped in that binary. The exact dependency set can be regenerated from `Cargo.lock` and `pnpm-lock.yaml`.
