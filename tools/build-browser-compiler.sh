#!/usr/bin/env bash
#
# Build the Zig compiler itself for wasm32-wasi so the site can recompile
# edited snippets client-side, plus a tarball of the standard library it needs
# at runtime.
#
# This is OPTIONAL. Without these artifacts the site still works: every snippet
# runs from its prebuilt, CI-verified wasm. Only the "Edit" button needs them.
#
# Outputs (git-ignored, several MB):
#   web/public/compiler/zig.wasm
#   web/public/compiler/lib.tar
#
# Usage:
#   ZIG_SRC=/path/to/ziglang/zig tools/build-browser-compiler.sh
#
# NOTE: This is a long, memory-hungry build (expect tens of minutes and >8 GB
# RAM). It must use Zig's self-hosted wasm backend, since LLVM cannot be part
# of a wasm32-wasi compiler binary.
set -euo pipefail

ZIG_SRC="${ZIG_SRC:-$HOME/opensource/ziglang/zig}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/web/public/compiler"

if [[ ! -d "$ZIG_SRC/lib/std" ]]; then
  echo "error: ZIG_SRC does not look like a Zig checkout: $ZIG_SRC" >&2
  echo "       set ZIG_SRC to your ziglang/zig clone" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "==> Building Zig compiler for wasm32-wasi (this takes a while)"
zig build \
  --build-file "$ZIG_SRC/build.zig" \
  -Dtarget=wasm32-wasi \
  -Doptimize=ReleaseSmall \
  -Dno-lib \
  -Dstrip

# The build lands in the Zig checkout's zig-out; locate the emitted module.
COMPILER_WASM="$(find "$ZIG_SRC/zig-out" -name '*.wasm' -type f | head -n1)"
if [[ -z "$COMPILER_WASM" ]]; then
  echo "error: no .wasm produced under $ZIG_SRC/zig-out" >&2
  exit 1
fi
cp "$COMPILER_WASM" "$OUT_DIR/zig.wasm"

echo "==> Packing standard library"
# Uncompressed tar; the browser-side untar in zig-compiler.ts expects no
# compression layer, and HTTP gzip handles transfer size.
tar --format=ustar -cf "$OUT_DIR/lib.tar" -C "$ZIG_SRC" lib

echo "==> Done"
du -h "$OUT_DIR"/zig.wasm "$OUT_DIR"/lib.tar
