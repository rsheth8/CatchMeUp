#!/bin/bash
# Prefer: ./catchup setup
set -euo pipefail
cd "$(dirname "$0")"
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
echo "venv ready. Next: ./catchup setup   (installs ffmpeg + whisperkit-cli too)"
