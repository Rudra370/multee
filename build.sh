#!/bin/bash
# Build the Multee app via SwiftPM and bundle it. debug → "Multee Dev.app" (separate bundle id +
# amber icon); release → "Multee.app". Pass the config as $1 (default debug).
set -e
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
VER="${MULTEE_VERSION:-0.1.0}"   # release CI passes the tag version (e.g. 0.1.0)

# Debug builds are a SEPARATE app ("Multee Dev", distinct bundle id + icon) so local builds never
# clash with a real/brew-installed Multee you use day-to-day (separate path, settings, sessions).
if [ "$CONFIG" = "debug" ]; then
  APP="Multee Dev.app"; NAME="Multee Dev"; BID="com.multee.native.dev"; ICNS="AppIconDev.icns"
else
  APP="Multee.app";     NAME="Multee";     BID="com.multee.native";     ICNS="AppIcon.icns"
fi
[ -f "$ICNS" ] || ICNS="AppIcon.icns"   # fall back to the prod icon if the dev one is missing

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Multee"
echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Multee"

# Copy SwiftPM resource bundles (e.g. Highlightr's highlight.js) so they're found at runtime. The
# vendored Highlightr's resource lookup checks Contents/Resources first, so this stays sealed/valid.
for b in ".build/$CONFIG"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# Icon (» chevrons; teal for prod, amber for the dev variant).
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/icon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${NAME}</string>
  <key>CFBundleDisplayName</key><string>${NAME}</string>
  <key>CFBundleIdentifier</key><string>${BID}</string>
  <key>CFBundleExecutable</key><string>Multee</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${VER}</string>
  <key>CFBundleShortVersionString</key><string>${VER}</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign the bundle so Gatekeeper shows the milder "unidentified developer" prompt (clearable
# with right-click → Open) instead of "is damaged" on Apple Silicon. The real fix is Developer ID
# signing + notarization (needs an Apple Developer account).
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign unavailable; skipping ad-hoc sign)"

echo "==> done: $(pwd)/$APP"
