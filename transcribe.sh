#!/bin/bash
# Legacy one-file helper. Prefer: ./meet transcribe <file>
exec "$(cd "$(dirname "$0")" && pwd)/meet" transcribe "$@"
