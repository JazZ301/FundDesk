#!/bin/sh
# Regenerates cross-language fixtures from the frozen Swift implementation.
# The Swift package is expected at ../fund, next to this repository.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SWIFT_CORE="$ROOT/../fund/Sources/FundCore"
BIN="${TMPDIR:-/tmp}/funddesk-golden"

swiftc -O -module-name FundCore "$SWIFT_CORE"/*.swift "$ROOT/tools/golden/main.swift" -o "$BIN"
"$BIN" "$ROOT/crates/core/tests/fixtures/scenario-metrics.json" \
  > "$ROOT/crates/core/tests/fixtures/golden.json"

echo "已更新 crates/core/tests/fixtures/golden.json"
