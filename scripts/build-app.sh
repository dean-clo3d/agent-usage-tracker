#!/usr/bin/env bash
# Builds "Claude Usage.app" into ./dist. Works with Command Line Tools only (no Xcode).
#
#   scripts/build-app.sh            # build dist/Claude Usage.app
#   scripts/build-app.sh --install  # also copy to ~/Applications and launch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Claude Usage"
BUNDLE_ID="com.agentusage.ClaudeUsage"
VERSION="1.0.0"
APP="dist/$APP_NAME.app"

# The macOS 27 beta SDK expects a SwiftUI macro plugin that Command Line Tools doesn't
# ship, so prefer the newest non-beta SDK that's installed. Override with SDKROOT=...
if [[ -z "${SDKROOT:-}" ]]; then
  SDKS=/Library/Developer/CommandLineTools/SDKs
  for candidate in MacOSX26.5.sdk MacOSX26.sdk MacOSX15.sdk; do
    if [[ -d "$SDKS/$candidate" ]]; then export SDKROOT="$SDKS/$candidate"; break; fi
  done
fi
echo "▸ SDK: ${SDKROOT:-default}"

# Build outside the project folder: SwiftPM's build database hits I/O errors inside
# cloud-synced folders such as ~/Documents.
SCRATCH="${SCRATCH_PATH:-$HOME/Library/Caches/agent-usage-build}"
BUILD_FLAGS=(-c release --product AgentUsage --scratch-path "$SCRATCH")

echo "▸ Building (release)…"
swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/AgentUsage"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentUsage"
strip -x "$APP/Contents/MacOS/AgentUsage"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>AgentUsage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)"
codesign --force --sign - --options runtime "$APP"

echo "✓ Built $ROOT/$APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  # Only stop the copy we're replacing, not any process that happens to share the name.
  pkill -f "^$DEST/$APP_NAME.app/Contents/MacOS/AgentUsage" 2>/dev/null || true
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/$APP_NAME.app"
  echo "✓ Installed to $DEST/$APP_NAME.app and launched"
fi
