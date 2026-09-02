#!/bin/bash
# Prefer: ./catchup meeting FILE   or   ./catchup lecture FILE
exec "$(cd "$(dirname "$0")" && pwd)/catchup" recap "$@"
