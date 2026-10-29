#!/bin/bash
# Build, sign, install to ~/Applications and register as LaunchAgent (autostart).
set -euo pipefail
cd "$(dirname "$0")"

NAME=StandUpSitDown
LABEL=io.github.derveloper.standupsitdown
APP="build/$NAME.app"
DEST="$HOME/Applications/$NAME.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14" Sources/main.swift -o "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP" # ad-hoc unless SIGN_IDENTITY is set

[ "${1:-}" = "--build-only" ] && exit 0

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/$NAME</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $DEST, autostart: $PLIST"
