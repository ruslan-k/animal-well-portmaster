#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?usage: test-runtime.sh <runtime-dir>}"

must_exist() {
  [ -e "$1" ] || { echo "missing: $1" >&2; exit 1; }
}

must_exist "$ROOT/bin/box64"
must_exist "$ROOT/wine/bin/wine64"
must_exist "$ROOT/VERSIONS"

file "$ROOT/bin/box64"
file "$ROOT/wine/bin/wine64"

# The aarch64 binary cannot execute natively on the amd64 Actions runner.
# qemu smoke catches malformed dynamic loader / immediate startup failures.
QEMU_SYSROOT=/usr/aarch64-linux-gnu
qemu-aarch64-static -L "$QEMU_SYSROOT" "$ROOT/bin/box64" -v

echo "checking PE payloads"
find "$ROOT/vkd3d" "$ROOT/dxvk" -type f \( -iname '*.dll' -o -iname '*.exe' \) -print -exec file {} \;

echo "runtime static smoke: PASS"
