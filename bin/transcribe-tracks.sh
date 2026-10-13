#!/usr/bin/env bash
# Transcribe a huddle recording that has one audio track per side, and merge the
# two into a single conversation you can read.
#
#     bin/transcribe-tracks.sh ~/Movies/huddles/huddle-....mkv [outdir]
#
# OBS writes track 1 = "Everyone else" (system audio) and track 2 = "You" (mic),
# so the two sides never bleed into each other and whisper transcribes each on
# its own. The merged file interleaves them by timestamp:
#
#     0:04  Them: so the handoff happens on Thursday
#     0:11  You:  that works, I will send the brief
#
# A file with a single audio track falls through to bin/transcribe.sh.
# Per-person names inside "Them" need diarization — see the note at the bottom.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${WHISPER_MODEL:-$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin}"
AUDIO="${1:?usage: transcribe-tracks.sh <recording> [outdir]}"
OUTDIR="${2:-$(dirname "$AUDIO")}"
NAME="$(basename "${AUDIO%.*}")"

command -v whisper-cli >/dev/null || { echo "whisper-cli missing: brew install whisper-cpp" >&2; exit 1; }
[ -f "$MODEL" ] || { echo "model missing: $MODEL" >&2; exit 1; }

TRACKS=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$AUDIO" | wc -l | tr -d ' ')
if [ "$TRACKS" -lt 2 ]; then
  echo "single audio track — using transcribe.sh"
  exec "$HERE/transcribe.sh" "$AUDIO" "$OUTDIR"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUTDIR"

# whisper.cpp only accepts 16 kHz mono PCM. One pass per side.
for i in 0 1; do
  label=$([ "$i" = 0 ] && echo them || echo you)
  ffmpeg -y -loglevel error -i "$AUDIO" -map "0:a:$i" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/$label.wav"
  whisper-cli -m "$MODEL" -f "$WORK/$label.wav" -ovtt -of "$WORK/$label" -l auto -pp
done

python3 - "$WORK/them.vtt" "$WORK/you.vtt" "$OUTDIR/$NAME.txt" <<'PY'
import re, sys

# whisper repeats one line over and over across silence; the same cue text
# arriving back to back is an artifact, not somebody saying it twice.
CUE = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d{3}) --> ")

def read(path, speaker):
    out, last = [], None
    for block in open(path, encoding="utf-8").read().split("\n\n"):
        lines = [l for l in block.strip().splitlines() if l and not l.startswith("WEBVTT")]
        if len(lines) < 2:
            continue
        m = CUE.match(lines[0])
        if not m:
            continue
        h, mi, s, _ = m.groups()
        text = " ".join(lines[1:]).strip()
        if not text or text == last:
            continue
        last = text
        out.append((int(h) * 3600 + int(mi) * 60 + int(s), speaker, text))
    return out

them, you, dest = sys.argv[1], sys.argv[2], sys.argv[3]
cues = sorted(read(them, "Them"), key=lambda c: c[0]) + sorted(read(you, "You"), key=lambda c: c[0])
cues.sort(key=lambda c: c[0])

with open(dest, "w", encoding="utf-8") as f:
    for seconds, speaker, text in cues:
        f.write(f"{seconds // 60}:{seconds % 60:02d}  {speaker + ':':5} {text}\n")
print(f"wrote {dest} ({len(cues)} lines)")
PY

# Keep the per-side transcripts too: useful when one track is clean and the
# other is a noisy room.
cp "$WORK/them.vtt" "$OUTDIR/$NAME.them.vtt"
cp "$WORK/you.vtt" "$OUTDIR/$NAME.you.vtt"
echo "wrote $OUTDIR/$NAME.txt plus per-side .vtt files"
