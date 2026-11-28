#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

TARGET="universal-apple-darwin"
APP="$ROOT/target/$TARGET/release/bundle/macos/基金看板.app"
VERSION=$(node -p "require('$ROOT/src-tauri/tauri.conf.json').version")
DMG="$ROOT/release/FundDesk-${VERSION}-macOS-universal.dmg"
STAGING="$ROOT/target/dmg-staging"
IDENTITY=${APPLE_SIGNING_IDENTITY:--}

if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
  TAURI_SIGNING_PRIVATE_KEY="$HOME/.tauri/funddesk.key"
  export TAURI_SIGNING_PRIVATE_KEY
fi
if [ -z "${TAURI_SIGNING_PRIVATE_KEY_PASSWORD+x}" ]; then
  TAURI_SIGNING_PRIVATE_KEY_PASSWORD=""
  export TAURI_SIGNING_PRIVATE_KEY_PASSWORD
fi
if [ ! -f "$TAURI_SIGNING_PRIVATE_KEY" ] && ! printf '%s' "$TAURI_SIGNING_PRIVATE_KEY" | grep -q "untrusted comment"; then
  echo "缺少 updater 签名私钥：$TAURI_SIGNING_PRIVATE_KEY" >&2
  echo "请先运行 pnpm tauri signer generate -w ~/.tauri/funddesk.key" >&2
  exit 1
fi

pnpm tauri build --target "$TARGET" --bundles app

if [ "$IDENTITY" = "-" ]; then
  echo "未配置 APPLE_SIGNING_IDENTITY，使用 ad-hoc 签名。"
  codesign --force --deep --sign - --options runtime "$APP"
else
  codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$IDENTITY" != "-" ] && [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  ZIP="$ROOT/release/FundDeskDesktop.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
elif [ "$IDENTITY" != "-" ] && [ -n "${APPLE_NOTARY_PROFILE:-}" ]; then
  ZIP="$ROOT/release/FundDeskDesktop.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
else
  echo "未配置 Apple ID / Team ID 或公证钥匙串配置，跳过公证。"
fi

rm -rf "$STAGING"
mkdir -p "$STAGING" "$ROOT/release"
ditto "$APP" "$STAGING/基金看板.app"
ln -sfn /Applications "$STAGING/Applications"
cp "$ROOT/src-tauri/icons/icon.icns" "$STAGING/.VolumeIcon.icns"
SetFile -a C "$STAGING" 2>/dev/null || true

rm -f "$DMG"
hdiutil create -volname "基金看板" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$DMG"
codesign --force --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"
hdiutil verify "$DMG"

UPDATER="$ROOT/target/$TARGET/release/bundle/macos/基金看板.app.tar.gz"
if [ -f "$UPDATER" ] && [ -f "$UPDATER.sig" ]; then
  cp "$UPDATER" "$ROOT/release/FundDesk-${VERSION}-macOS-universal.app.tar.gz"
  cp "$UPDATER.sig" "$ROOT/release/FundDesk-${VERSION}-macOS-universal.app.tar.gz.sig"
else
  echo "未找到 updater 归档或签名，请确认 createUpdaterArtifacts 与签名密钥已配置。" >&2
  exit 1
fi

if [ "$IDENTITY" != "-" ] && { { [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; } || [ -n "${APPLE_NOTARY_PROFILE:-}" ]; }; then
  if [ -n "${APPLE_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$DMG" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
  fi
  xcrun stapler staple "$DMG"
fi

echo "DMG: $DMG"
