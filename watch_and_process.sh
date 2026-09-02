#!/bin/bash
# Finds fully-written recordings in recordings/ and runs them through pipeline.py.
# Used by `./catchup watch meeting|lecture` and the optional launchd watcher.
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDINGS_DIR="$PROJECT_DIR/recordings"
LOCK_DIR="$PROJECT_DIR/logs/watch.lock.d"
PYTHON="$PROJECT_DIR/venv/bin/python3"
MODE="${1:-}"

mkdir -p "$PROJECT_DIR/logs" "$RECORDINGS_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

if [[ ! -x "$PYTHON" ]]; then
    echo "venv missing — run ./catchup setup" >> "$PROJECT_DIR/logs/pipeline.log"
    exit 1
fi

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

    if [[ -n "$MODE" ]]; then
        "$PYTHON" "$PROJECT_DIR/pipeline.py" --mode "$MODE" "$f" >> "$PROJECT_DIR/logs/pipeline.log" 2>&1
    else
        "$PYTHON" "$PROJECT_DIR/pipeline.py" "$f" >> "$PROJECT_DIR/logs/pipeline.log" 2>&1
    fi
done
