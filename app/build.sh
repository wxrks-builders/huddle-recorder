#!/usr/bin/env bash
# Build the recording button into ~/Applications/Huddle Rec.app.
#
#     app/build.sh [path/to/Huddle Rec.app]
#
# The .app is not in git: this script, huddle-rec.swift and record-icon.py are
# the source. It bakes in where this checkout lives and where recordings go
# (HR_DIR in ~/.config/huddle-recorder/config), so re-run it after moving either.
# Needs the Xcode command line tools (xcode-select --install) for swiftc.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/../bin" && pwd)"
CONFIG="$HOME/.config/huddle-recorder/config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
RECORDINGS="${HR_DIR:-$HOME/Movies/huddles}"
APP="${1:-$HOME/Applications/Huddle Rec.app}"

command -v swiftc >/dev/null || { echo "swiftc missing: run xcode-select --install, then this again" >&2; exit 1; }

RUNNING=$(pgrep -f "$APP/Contents/MacOS/huddle-rec" >/dev/null && echo yes || echo no)
[ "$RUNNING" = yes ] && pkill -f "$APP/Contents/MacOS/huddle-rec" || true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Paths.swift" <<SWIFT
// Written by app/build.sh for this Mac.
let BIN = "$BIN"
let RECORDINGS = "$RECORDINGS"
SWIFT

# With two source files, Swift allows top-level code only in one named main.swift.
cp "$HERE/huddle-rec.swift" "$WORK/main.swift"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$RECORDINGS"
swiftc -O -framework Cocoa -o "$APP/Contents/MacOS/huddle-rec" "$WORK/Paths.swift" "$WORK/main.swift"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Huddle Rec</string>
  <key>CFBundleDisplayName</key><string>Huddle Rec</string>
  <key>CFBundleIdentifier</key><string>com.wxrks.huddle-rec</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>huddle-rec</string>
  <key>CFBundleIconFile</key><string>RecordRing</string>
  <key>LSUIElement</key><false/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

python3 "$HERE/record-icon.py" "$APP/Contents/Resources/RecordRing.icns" >/dev/null
touch "$APP"
echo "built $APP"

if [ "$RUNNING" = yes ]; then
  open "$APP"
  echo "restarted it"
fi
