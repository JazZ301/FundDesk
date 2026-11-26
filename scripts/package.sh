#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration" --product FundDesk
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/funddesk-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/基金看板.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
cp "$bin_dir/FundDesk" "$app/Contents/MacOS/FundDesk"

swift scripts/make-icon.swift "$stage/icon.png"
mkdir "$stage/FundDesk.iconset"
for pixels in 16 32 128 256 512; do
    sips -z "$pixels" "$pixels" "$stage/icon.png" --out "$stage/FundDesk.iconset/icon_${pixels}x${pixels}.png" >/dev/null
    retina=$((pixels * 2))
    sips -z "$retina" "$retina" "$stage/icon.png" --out "$stage/FundDesk.iconset/icon_${pixels}x${pixels}@2x.png" >/dev/null
done
iconutil -c icns "$stage/FundDesk.iconset" -o "$app/Contents/Resources/FundDesk.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>基金看板</string>
    <key>CFBundleExecutable</key><string>FundDesk</string>
    <key>CFBundleIconFile</key><string>FundDesk</string>
    <key>CFBundleIdentifier</key><string>local.ju.funddesk</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>基金看板</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.29</string>
    <key>CFBundleVersion</key><string>42</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>local.ju.funddesk.holding-row</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeDescription</key><string>FundDesk Holding Row</string>
        </dict>
    </array>
</dict></plist>
PLIST

plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir "$stage/disk"
ditto "$app" "$stage/disk/基金看板.app"
ln -s /Applications "$stage/disk/Applications"
hdiutil create -volname '基金看板' -srcfolder "$stage/disk" -format UDZO -fs HFS+ "$stage/基金看板.dmg"
hdiutil verify "$stage/基金看板.dmg"

destination="$PWD/dist"
if [[ -d "$destination/基金看板.app" ]]; then
    mv "$destination/基金看板.app" "$stage/previous.app"
fi
if ! mv "$app" "$destination/基金看板.app"; then
    if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$destination/基金看板.app"; fi
    exit 1
fi
mv -f "$stage/基金看板.dmg" "$destination/基金看板.dmg"
