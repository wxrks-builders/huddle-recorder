#!/usr/bin/env bash
# Remove the Huddle Rec button and its login item.
#
#     ./uninstall.sh
#
# Keeps your recordings, transcripts and notes, your settings, OBS and its
# Huddle setup, and the speech model. The end of the output says how to remove
# those too.
set -euo pipefail

AGENT="$HOME/Library/LaunchAgents/com.wxrks.huddle-rec.plist"
APP="$HOME/Applications/Huddle Rec.app"

launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/huddle-rec" 2>/dev/null || true
rm -f "$AGENT"
rm -rf "$APP"
echo "Removed Huddle Rec and its login item."
cat <<EOF

Still on this Mac, remove by hand if you want:
  recordings, transcripts, notes   ~/Movies/huddles
  settings                         ~/.config/huddle-recorder
  speech model (1.6 GB)            ~/.cache/whisper-cpp
  OBS Huddle setup                 OBS > Scene Collection and Profile menus
  the tools                        brew uninstall whisper-cpp; brew uninstall --cask obs
EOF
