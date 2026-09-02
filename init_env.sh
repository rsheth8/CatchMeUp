#!/bin/bash
# Prefer: ./meet setup
# Kept as a tiny helper if you only need the venv.
set -euo pipefail
cd "$(dirname "$0")"
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
echo "venv ready. Next: ./meet setup   (installs ffmpeg + whisperkit-cli too)"
