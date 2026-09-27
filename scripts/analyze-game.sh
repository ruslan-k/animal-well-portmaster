#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <Animal Well.exe|switch-exefs-dir>" >&2
  exit 2
fi

TARGET="$1"
if [ -f "$TARGET" ]; then
  echo "== Windows executable =="
  file "$TARGET"
  sha256sum "$TARGET"
  echo
  echo "== imported DLLs =="
  objdump -p "$TARGET" | awk '/DLL Name:/ {print $3}' | sort -u
  echo
  echo "== D3D12/DXGI markers =="
  strings -a -n 5 "$TARGET" | grep -Ei 'D3D12|DXGI|CreateSwapChain|CreateCommittedResource|RootSignature' | head -200 || true
  exit 0
fi

if [ -d "$TARGET" ] && [ -f "$TARGET/main" ]; then
  echo "== Switch ExeFS =="
  for f in main rtld sdk; do
    [ -f "$TARGET/$f" ] || continue
    file "$TARGET/$f"
    sha256sum "$TARGET/$f"
  done
  echo
  echo "== SDK/NVN markers =="
  strings -a -n 5 "$TARGET/main" "$TARGET/sdk" \
    | grep -Ei 'SDK_gfx|nvn[A-Za-z]|nn::|hid|audio|account|nifm' \
    | head -400 || true
  exit 0
fi

echo "unsupported input: $TARGET" >&2
exit 2
