#!/usr/bin/env bash
# Transcribe a recording (voice memo, call, conference talk) to text, locally.
#
# Runs whisper.cpp on-device. Nothing is uploaded, which matters because these
# recordings are internal strategy calls and client conversations.
#
#     bin/transcribe.sh ~/Downloads/some-call.m4a [outdir]
#
# Writes <outdir>/<name>.txt and <name>.vtt (timestamped). Defaults to a
# sibling of the input. Raw transcripts are unedited talk: keep them private.
#
# Setup, once:
#     brew install whisper-cpp
#     mkdir -p ~/.cache/whisper-cpp && curl -L -o ~/.cache/whisper-cpp/ggml-large-v3-turbo.bin \
#       https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
#
# large-v3-turbo, not base/small: our recordings are full of proper nouns the
# small models mangle (people's names, company and product names), and
# they are frequently Portuguese or code-switching. ~31 min transcribes in
# under two minutes on Apple Silicon.
set -euo pipefail

MODEL="${WHISPER_MODEL:-$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin}"
AUDIO="${1:?usage: bin/transcribe.sh <audio-file> [outdir]}"
OUTDIR="${2:-$(dirname "$AUDIO")}"
NAME="$(basename "${AUDIO%.*}")"

command -v whisper-cli >/dev/null || { echo "whisper-cli missing: brew install whisper-cpp" >&2; exit 1; }
command -v ffmpeg      >/dev/null || { echo "ffmpeg missing: brew install ffmpeg" >&2; exit 1; }
[ -f "$MODEL" ] || { echo "model missing: $MODEL (see setup in this file's header)" >&2; exit 1; }

WAV="$(mktemp -t transcribe).wav"
trap 'rm -f "$WAV"' EXIT

# whisper.cpp only accepts 16 kHz mono PCM.
ffmpeg -y -loglevel error -i "$AUDIO" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV"

# -l auto: we work in English and Portuguese and the file rarely says which.
# -pp prints progress; a 30-minute file is long enough that silence looks like a hang.
whisper-cli -m "$MODEL" -f "$WAV" -otxt -ovtt -of "$OUTDIR/$NAME" -l auto -pp

echo "wrote $OUTDIR/$NAME.txt and $OUTDIR/$NAME.vtt"
echo
echo "Note: whisper loops on long silences — you will see a line repeated dozens of"
echo "times where nobody was talking. That is an artifact, not content. Filter before reading."
