#!/usr/bin/env bash
# One button for recording a call (a Slack huddle, a Meet, anything with sound):
# click to start, click again to stop. Stopping transcribes the call on this Mac
# in the background, then writes notes if Claude Code is installed.
#
#     bin/record-huddle.sh          # toggle
#     bin/record-huddle.sh status
#
# OBS records two tracks: the call audio (everyone else, through ScreenCaptureKit)
# and your microphone (you). "Huddle Rec.app" is the button; it runs this script.
#
# Settings live in ~/.config/huddle-recorder/config (install.sh writes it).
# Tell the others you are recording.
set -euo pipefail

# A .app launched from the Dock gets a bare PATH — node and ffmpeg live here.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HOME/.config/huddle-recorder/config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

OBS="node $HERE/obs-huddle.mjs"
OUTDIR="${HR_DIR:-$HOME/Movies/huddles}"
TRANSCRIPTS="$OUTDIR/transcripts"
NOTES="$OUTDIR/notes"
LOG="$OUTDIR/.record-huddle.log"

mkdir -p "$TRANSCRIPTS"

say () { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }

# OBS only reads --collection/--profile at launch; obs-huddle.mjs switches a
# session that is already open on something else.
ensure_obs () {
  pgrep -xq OBS && return 0
  open -a OBS --args --collection Huddle --profile Huddle --minimize-to-tray --disable-shutdown-check
  for _ in $(seq 1 40); do
    if $OBS status >/dev/null 2>&1; then
      # Remember that this was ours, so the stop can close it again. While OBS
      # runs it holds the mic and the screen tap open, and macOS shows its own
      # recording indicators — which read as "still recording" when nothing is.
      touch "$OUTDIR/.obs-launched"
      return 0
    fi
    perl -e 'select(undef,undef,undef,0.5)'
  done
  say "Recording failed" "OBS did not start. Open it once by hand."
  exit 1
}

# OBS returns the path the moment you stop, but the muxer is still finishing the
# file — hand it to ffmpeg too early and you get "EBML header parsing failed".
wait_until_finalized () {
  local file="$1" last=0 size stable=0
  for _ in $(seq 1 60); do
    size=$(stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -gt 0 ] && [ "$size" -eq "$last" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 2 ] && ffprobe -v error "$file" >/dev/null 2>&1 && return 0
    else
      stable=0
    fi
    last="$size"
    perl -e 'select(undef,undef,undef,0.5)'
  done
  return 1
}

# Optional: copy the result into a team folder (a Google Drive folder synced on
# this Mac, say). Notes by default; the full transcript only when asked for.
share () {
  local name="$1"
  [ -n "${HR_SHARE_DIR:-}" ] || return 0
  mkdir -p "$HR_SHARE_DIR"
  if [ -f "$NOTES/$name.md" ]; then cp "$NOTES/$name.md" "$HR_SHARE_DIR/"; fi
  if [ "${HR_SHARE_TRANSCRIPTS:-0}" = 1 ] && [ -f "$TRANSCRIPTS/$name.txt" ]; then
    cp "$TRANSCRIPTS/$name.txt" "$HR_SHARE_DIR/"
  fi
  return 0
}

transcribe () {
  local file="$1" name
  name="$(basename "${file%.*}")"
  if ! wait_until_finalized "$file"; then
    say "Transcription skipped" "$name never finished writing. The recording is in $OUTDIR."
    return 1
  fi
  # The file is safe on disk now, so close OBS if we were the ones who opened it.
  # Nothing recording, nothing running, no indicators left glowing.
  if [ -f "$OUTDIR/.obs-launched" ]; then
    rm -f "$OUTDIR/.obs-launched"
    osascript -e 'tell application "OBS" to quit' >/dev/null 2>&1 || true
    perl -e 'select(undef,undef,undef,4)'
    pgrep -xq OBS && pkill -x OBS || true
  fi
  say "Transcribing $name" "Running on this Mac. A one-hour call takes a few minutes."
  if ! "$HERE/transcribe-tracks.sh" "$file" "$TRANSCRIPTS" >>"$LOG" 2>&1; then
    say "Transcription failed" "See $LOG — the recording itself is safe."
    return 1
  fi
  say "Transcript ready" "$name.txt in $(basename "$OUTDIR")/transcripts"
  # Notes need Claude Code on this Mac (`claude`). Without it the transcript is
  # the result. The notes script sends its own notification.
  if [ "${HR_NOTES:-auto}" != off ] && command -v claude >/dev/null; then
    node "$HERE/huddle-notes.mjs" "$TRANSCRIPTS/$name.txt" >>"$LOG" 2>&1 || true
  fi
  share "$name"
}

case "${1:-toggle}" in
  status)
    ensure_obs
    $OBS status
    ;;
  toggle|start|stop)
    ensure_obs
    result="$($OBS "${1:-toggle}")"
    case "$result" in
      *'"started"'*)
        say "Recording — tell the others" "Click Huddle Rec again to stop."
        ;;
      *'"stopped"'*)
        file="$(printf '%s' "$result" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')"
        say "Recording saved" "$(basename "$file")"
        # Fully detached, in its own process with its own file descriptors. A
        # backgrounded subshell still holds the caller's stdout pipe open, which
        # froze the button for the length of the transcription.
        nohup "${BASH_SOURCE[0]}" transcribe-file "$file" >/dev/null 2>&1 </dev/null &
        disown 2>/dev/null || true
        ;;
      *)
        say "Nothing to do" "OBS reported: $result"
        ;;
    esac
    printf '%s\n' "$result"
    ;;
  transcribe-file)
    # Internal: run detached by the stop branch above.
    transcribe "${2:?usage: record-huddle.sh transcribe-file <recording>}"
    ;;
  *)
    echo "usage: $(basename "$0") [toggle|start|stop|status]" >&2
    exit 64
    ;;
esac
