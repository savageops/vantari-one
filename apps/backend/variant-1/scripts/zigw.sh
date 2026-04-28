#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export ZIG_LOCAL_CACHE_DIR="/tmp/VANTARI-ONE-VAR1-local-cache"
export ZIG_GLOBAL_CACHE_DIR="/tmp/VANTARI-ONE-VAR1-global-cache"
mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || -n "${MSYSTEM:-}" ]]; then
  if command -v cygpath >/dev/null 2>&1; then
    WINDOWS_WRAPPER="$(cygpath -w "$SCRIPT_DIR/zigw.ps1")"
  else
    WINDOWS_WRAPPER="$SCRIPT_DIR/zigw.ps1"
  fi
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WINDOWS_WRAPPER" "$@"
fi

WRAPPER="$ROOT_DIR/.toolchain/zig/zig"
exec "$WRAPPER" "$@"
