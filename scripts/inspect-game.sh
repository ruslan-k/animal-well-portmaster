#!/usr/bin/env bash
set -euo pipefail
EXE="${1:-Animal Well.exe}"
[ -f "$EXE" ] || { echo "usage: $0 /path/to/Animal\\ Well.exe" >&2; exit 2; }
command -v objdump >/dev/null || { echo "objdump is required" >&2; exit 2; }

printf 'path=%s\n' "$EXE"
printf 'size=%s\n' "$(stat -c %s "$EXE" 2>/dev/null || stat -f %z "$EXE")"
printf 'sha256=%s\n' "$(sha256sum "$EXE" | awk '{print $1}')"
file "$EXE"
printf '\n[imports]\n'
objdump -p "$EXE" | awk '/DLL Name:/{print $3}' | sort -fu
printf '\n[d3d12/dxgi symbols and diagnostic strings]\n'
strings -a "$EXE" | grep -Ei 'D3D12|DXGI|CreateSwapChain|CreateCommittedResource|CreateRootSignature|CreateGraphicsPipelineState|CreateComputePipelineState' | sort -u || true
printf '\n[version strings]\n'
strings -el "$EXE" | grep -E '^(1\.[0-9]+\.[0-9]+\.[0-9]+|Animal Well)$' | sort -u || true
