#!/usr/bin/env bash
# Set up Huddle Rec on this Mac: one button that records a call (the call audio
# and your mic), transcribes it on this Mac, and writes notes.
#
#     ./install.sh                 # asks your name and, optionally, a team folder
#     ./install.sh --name "Ana Silva" --share-dir "$HOME/Library/CloudStorage/GoogleDrive-ana@example.com/Shared drives/Calls"
#
# Safe to run again: it keeps your settings and an OBS setup that already exists.
# --force rewrites the OBS setup. --test skips installs, downloads and launching
# (for checking the script itself).
#
# What it does:
#   1. installs OBS, ffmpeg, whisper.cpp and node with Homebrew
#   2. downloads the speech model (~1.6 GB) to ~/.cache/whisper-cpp
#   3. writes your settings to ~/.config/huddle-recorder/config
#   4. adds a "Huddle" scene collection and profile to OBS and turns on its
#      local remote control (obs-websocket), which is how the button drives it
#   5. builds "Huddle Rec.app" into ~/Applications and starts it at login
#   6. opens OBS once so macOS asks for the microphone and screen/audio permission
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/huddle-recorder"
CONFIG="$CONFIG_DIR/config"
OBSDIR="$HOME/Library/Application Support/obs-studio"
MODEL="$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
AGENT="$HOME/Library/LaunchAgents/com.wxrks.huddle-rec.plist"
APP="$HOME/Applications/Huddle Rec.app"

NAME="" SHARE_DIR="" FORCE=0 TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --share-dir) SHARE_DIR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --test) TEST=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

step () { printf '\n\033[1m%s\033[0m\n' "$*"; }
ask () { local answer; read -r -p "$1" answer </dev/tty || true; printf '%s' "$answer"; }

[ "$(uname)" = Darwin ] || { echo "Huddle Rec is Mac-only for now." >&2; exit 1; }
if [ "$(uname -m)" != arm64 ]; then
  echo "Note: this is an Intel Mac. Recording works; transcription will be slow (roughly the length of the call)."
fi
if pgrep -xq OBS; then
  echo "OBS is open. Quit it first: OBS saves its own settings on quit and would undo this setup." >&2
  exit 1
fi

# ------------------------------------------------------------------ 1. tools
step "1/6  Tools"
if [ "$TEST" = 1 ]; then
  echo "test: skipping Homebrew"
else
  command -v brew >/dev/null || {
    echo "Homebrew is missing. Install it from https://brew.sh, then run this again." >&2
    exit 1
  }
  for f in ffmpeg whisper-cpp node; do
    brew list --formula "$f" >/dev/null 2>&1 && echo "ok   $f" || brew install "$f"
  done
  if [ -d /Applications/OBS.app ]; then echo "ok   OBS"; else brew install --cask obs; fi
  xcode-select -p >/dev/null 2>&1 || {
    echo "The Xcode command line tools are needed to build the button. A window opens now:"
    echo "click Install, wait for it to finish, then run ./install.sh again."
    xcode-select --install || true
    exit 1
  }
  echo "ok   Xcode command line tools"
fi

# ------------------------------------------------------------------ 2. model
step "2/6  Speech model"
if [ -f "$MODEL" ]; then
  echo "ok   $(basename "$MODEL") already downloaded"
elif [ "$TEST" = 1 ]; then
  echo "test: skipping the 1.6 GB download"
else
  mkdir -p "$(dirname "$MODEL")"
  curl -L --fail --progress-bar -o "$MODEL.part" "$MODEL_URL"
  mv "$MODEL.part" "$MODEL"
fi

# ------------------------------------------------------------------ 3. settings
step "3/6  Your settings"
if [ -f "$CONFIG" ] && [ "$FORCE" = 0 ]; then
  echo "ok   keeping $CONFIG"
else
  [ -n "$NAME" ] || NAME="$(ask "Your name, as people say it in calls (e.g. Ana Silva): ")"
  [ -n "$NAME" ] || NAME="$(id -F 2>/dev/null || whoami)"
  if [ -z "$SHARE_DIR" ] && [ "$TEST" = 0 ]; then
    echo "Optional: a team folder that gets a copy of each call's notes (a Google Drive"
    echo "folder synced on this Mac, say). Press Enter to keep everything on this Mac."
    SHARE_DIR="$(ask "Team folder: ")"
  fi
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG" <<EOF
# Huddle Rec settings. Edit freely; the scripts read this on every run.

# Your name. Notes call your next steps "your next steps".
HR_NAME="$NAME"

# Where recordings, transcripts and notes go.
HR_DIR="$HOME/Movies/huddles"

# Notes language: English or Portuguese.
HR_NOTES_LANGUAGE="English"

# Notes need Claude Code on this Mac. "off" keeps transcripts only.
HR_NOTES="auto"

# Optional team folder: each call's notes are copied here. Empty = only this Mac.
HR_SHARE_DIR="$SHARE_DIR"
# 1 also copies the full transcript there. It is everyone on the call talking.
HR_SHARE_TRANSCRIPTS=0

# Optional: also file notes in a Notion database (see README).
# NOTION_API_KEY=
# HR_NOTION_DB=
EOF
  echo "ok   wrote $CONFIG"
fi
# shellcheck disable=SC1090
. "$CONFIG"
RECORDINGS="${HR_DIR:-$HOME/Movies/huddles}"
mkdir -p "$RECORDINGS/transcripts" "$RECORDINGS/notes"

# ------------------------------------------------------------------ 4. OBS
step "4/6  OBS setup"
mkdir -p "$OBSDIR/basic/scenes" "$OBSDIR/basic/profiles/Huddle" "$OBSDIR/plugin_config/obs-websocket"

if [ -f "$OBSDIR/basic/scenes/Huddle.json" ] && [ "$FORCE" = 0 ]; then
  echo "ok   keeping the Huddle scene collection"
else
  cp "$HERE/obs/Huddle.json" "$OBSDIR/basic/scenes/Huddle.json"
  echo "ok   Huddle scene collection: call audio on track 1, your mic on track 2"
fi

if [ -f "$OBSDIR/basic/profiles/Huddle/basic.ini" ] && [ "$FORCE" = 0 ]; then
  echo "ok   keeping the Huddle profile"
else
  sed "s#__RECORDINGS__#$RECORDINGS#" "$HERE/obs/basic.ini" > "$OBSDIR/basic/profiles/Huddle/basic.ini"
  cp "$HERE/obs/recordEncoder.json" "$OBSDIR/basic/profiles/Huddle/recordEncoder.json"
  echo "ok   Huddle profile: recordings go to $RECORDINGS"
fi

# The button talks to OBS over its local websocket (127.0.0.1 only). Keep an
# existing password; make one when there is none.
python3 - "$OBSDIR/plugin_config/obs-websocket/config.json" <<'PY'
import json, os, secrets, sys
path = sys.argv[1]
cfg = json.load(open(path)) if os.path.exists(path) else {}
before = dict(cfg)
cfg.setdefault("server_port", 4455)
cfg.setdefault("alerts_enabled", False)
cfg["first_load"] = False
cfg["server_enabled"] = True
cfg["auth_required"] = True
if not cfg.get("server_password"):
    cfg["server_password"] = secrets.token_urlsafe(16)
json.dump(cfg, open(path, "w"), indent=4)
print("ok   OBS remote control on (port %s)%s" % (cfg["server_port"], "" if before == cfg else ", updated"))
PY

# A brand-new OBS opens a setup wizard first; skip it and start on Huddle.
if [ ! -f "$OBSDIR/user.ini" ]; then
  cat > "$OBSDIR/user.ini" <<'EOF'
[General]
Pre19Defaults=false
Pre21Defaults=false
Pre23Defaults=false
Pre24.1Defaults=false
FirstRun=true

[Basic]
Profile=Huddle
ProfileDir=Huddle
SceneCollection=Huddle
SceneCollectionFile=Huddle.json
EOF
  echo "ok   OBS first-run wizard skipped"
fi

# ------------------------------------------------------------------ 5. button
step "5/6  The Huddle Rec button"
"$HERE/app/build.sh" "$APP"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.wxrks.huddle-rec</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/huddle-rec</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
echo "ok   starts at login"
if [ "$TEST" = 0 ]; then
  launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || open "$APP"
fi

# ------------------------------------------------------------------ 6. permissions
step "6/6  Permissions"
if [ "$TEST" = 1 ]; then
  echo "test: not opening OBS"
else
  echo "OBS opens now. When macOS asks, allow:"
  echo "  - Microphone"
  echo "  - Screen & System Audio Recording (this is how it hears the call)"
  echo "If OBS asks for permissions in its own window, grant both there, then quit OBS."
  open -a OBS --args --collection Huddle --profile Huddle --disable-shutdown-check
  ask "Press Enter once you have granted both and quit OBS... " >/dev/null
fi

cat <<EOF

Done. Huddle Rec is the black square with a white ring in your Dock.

  Click it to start recording, click again to stop. A red REC badge shows while
  it records. Say at the start of the call that you are recording.

  Recordings:  $RECORDINGS
  Transcripts: $RECORDINGS/transcripts   (a few minutes after you stop)
  Notes:       $RECORDINGS/notes$(command -v claude >/dev/null || printf '   (needs Claude Code: https://claude.com/claude-code)')
  Settings:    $CONFIG

Test it: play a YouTube video, click record, talk for ten seconds, click stop.
EOF
