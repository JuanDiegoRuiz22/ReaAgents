#!/usr/bin/env bash
# Thin wrapper for Git Bash: on Windows there is no `ss`/`lsof`, so the
# monitoring lives in run-monitored.ps1 (Get-NetTCPConnection + DNS cache).
# Usage: ./run-monitored.sh [-Mode cli|mcp] [-Target targets\\app] [-IntervalMs 200]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -W 2>/dev/null || pwd)"
exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$here/run-monitored.ps1" "$@"
