#!/bin/bash
# Finds fully-written recordings and runs pipeline.py.
# Usage: watch_and_process.sh [meeting|lecture] [brain-slug]
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${CATCHMEUP_HOME:-$PROJECT_DIR}"
LOCK_DIR="$DATA_DIR/logs/watch.lock.d"
if [[ -x "$PROJECT_DIR/venv/bin/python3" ]]; then
    PYTHON="$PROJECT_DIR/venv/bin/python3"
else
    PYTHON="$(command -v python3 || true)"
fi
MODE=""
BRAIN=""

for arg in "$@"; do
    [ -z "$arg" ] && continue
    case "$arg" in
        meeting|lecture) MODE="$arg" ;;
        *) BRAIN="$arg" ;;
    esac
done

if [[ -n "$BRAIN" ]]; then
    RECORDINGS_DIR="$DATA_DIR/brains/$BRAIN/inbox"
else
    RECORDINGS_DIR="$DATA_DIR/recordings"
fi

mkdir -p "$DATA_DIR/logs" "$RECORDINGS_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

if [[ -z "$PYTHON" || ! -x "$PYTHON" ]]; then
    echo "python3 missing — run ./catchup setup" >> "$DATA_DIR/logs/pipeline.log"
    exit 1
fi

export CATCHMEUP_HOME="$DATA_DIR"

shopt -s nullglob
for f in "$RECORDINGS_DIR"/*.mov "$RECORDINGS_DIR"/*.mp4 "$RECORDINGS_DIR"/*.m4a \
         "$RECORDINGS_DIR"/*.mp3 "$RECORDINGS_DIR"/*.wav "$RECORDINGS_DIR"/*.aac \
         "$RECORDINGS_DIR"/*.mkv "$RECORDINGS_DIR"/*.webm; do
    [ -e "$f" ] || continue

    if stat -f%z "$f" >/dev/null 2>&1; then
        size1=$(stat -f%z "$f")
        sleep 5
        size2=$(stat -f%z "$f" 2>/dev/null || echo "")
    else
        size1=$(stat -c%s "$f")
        sleep 5
        size2=$(stat -c%s "$f" 2>/dev/null || echo "")
    fi
    [ "$size1" != "$size2" ] && continue
    [ -z "$size2" ] && continue

    args=()
    [[ -n "$MODE" ]] && args+=(--mode "$MODE")
    [[ -n "$BRAIN" ]] && args+=(--brain "$BRAIN")
    "$PYTHON" "$PROJECT_DIR/pipeline.py" "${args[@]}" "$f" >> "$DATA_DIR/logs/pipeline.log" 2>&1
done
