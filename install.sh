#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$DIR/install.ps1" "$@"
else
    echo "[x] 未找到 pwsh (PowerShell 7+)。请先安装："
    echo "    macOS:  brew install pwsh"
    echo "    Linux:  https://learn.microsoft.com/powershell/scripting/install/installing-powershell"
    exit 1
fi
