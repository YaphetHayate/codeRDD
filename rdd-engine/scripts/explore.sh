#!/usr/bin/env bash
# rdd-engine explore entry point for non-Windows platforms.
# Requires PowerShell 7+ (pwsh). Install via: brew install pwsh | apt install pwsh
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$script_dir/explore.ps1" "$@"
