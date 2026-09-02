#!/bin/bash
# Legacy helper. Prefer: ./skip recap <file>
exec "$(cd "$(dirname "$0")" && pwd)/skip" recap "$@"
