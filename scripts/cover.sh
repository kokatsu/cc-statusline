#!/usr/bin/env bash
# Generate test coverage using DWARF debug info + debugger breakpoints.
# Linux: readelf + GDB (with DWARF v5 patching)
# macOS: dwarfdump + LLDB (no patching needed)
#
# Usage: ./scripts/cover.sh
#   or:  zig build cover
set -euo pipefail

cd "$(dirname "$0")/.."

BIN=zig-out/test-bin

mkdir -p zig-out

echo "=== Step 1: Build test binary ==="
zig test --test-no-exec -femit-bin="$BIN" src/main.zig 2>&1

OS="$(uname -s)"

if [ "$OS" = "Linux" ]; then
  PATCHED=zig-out/test-bin-patched
  echo "=== Step 2: Patch DWARF (strip DW_LNCT_LLVM_source) ==="
  STRIP_DWARF=zig-out/bin/strip-dwarf
  if [ ! -x "$STRIP_DWARF" ]; then
    zig build -Doptimize=ReleaseFast 2>&1 | grep -v "^$"
  fi
  "$STRIP_DWARF" "$BIN" "$PATCHED"
  chmod +x "$PATCHED"
  TARGET="$PATCHED"
else
  echo "=== Step 2: Skip DWARF patch (not needed on $OS) ==="
  TARGET="$BIN"
fi

echo ""
echo "=== Step 3: Run coverage ==="
bash scripts/coverage.sh src "$TARGET"
