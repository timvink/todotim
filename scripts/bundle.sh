#!/usr/bin/env bash
# Builds build/TodoTim.app from the SwiftPM executable (release), with icon and ad-hoc signature.
# Usage: scripts/bundle.sh
# Env: SCRATCH_PATH=.build-foo  private build dir
#      VERSION=1.2.3            CFBundleShortVersionString (default 0.0.0-dev)
#      UNIVERSAL=1              build for arm64 and x86_64
set -euo pipefail

cd "$(dirname "$0")/.."
SCRATCH_PATH="${SCRATCH_PATH:-.build}"
APP="build/TodoTim.app"

VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release --scratch-path "$SCRATCH_PATH" "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release --scratch-path "$SCRATCH_PATH" "${ARCH_FLAGS[@]}" --show-bin-path)/TodoTim"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TodoTim"

# App icon, regenerated only when the script changes.
ICNS="build/AppIcon.icns"
if [[ ! -f "$ICNS" || scripts/make_icon.swift -nt "$ICNS" ]]; then
    TMP="$(mktemp -d)"
    swift scripts/make_icon.swift "$TMP/icon_1024.png"
    ICONSET="$TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
    rm -rf "$TMP"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TodoTim</string>
    <key>CFBundleDisplayName</key><string>TodoTim</string>
    <key>CFBundleIdentifier</key><string>nl.timvink.todotim</string>
    <key>CFBundleExecutable</key><string>TodoTim</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $APP"
