#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); RT="$ROOT/runtime"; GAME="$ROOT/game"; PREFIX="$ROOT/prefix"; LOG="$ROOT/logs"
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown); OUT="$LOG/diag-$STAMP"; mkdir -p "$OUT" "$PREFIX"
run(){ n=$1; shift; { echo "# $*"; "$@"; r=$?; echo "exit_code=$r"; return $r; } >"$OUT/$n.log" 2>&1; }
{ uname -a; echo DISPLAY=${DISPLAY:-}; echo WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}; cat /proc/meminfo 2>/dev/null; ulimit -a 2>/dev/null; ls -la /dev/dri 2>/dev/null; find /etc /usr /lib -maxdepth 5 -type f \( -name '*icd*.json' -o -name 'libvulkan.so*' -o -name 'libmali.so*' \) 2>/dev/null | head -200; } >"$OUT/system.log" 2>&1
command -v ldd >/dev/null && run glibc ldd --version || true
command -v vulkaninfo >/dev/null && run vulkaninfo vulkaninfo --summary || true
[ -x "$RT/tools/vkprobe" ] && run vkprobe "$RT/tools/vkprobe" || true
BOX64="$RT/box64/box64"; WINE="$RT/wine/bin/wine"
if [ -x "$BOX64" ] && [ -x "$WINE" ]; then
 export WINEPREFIX="$PREFIX" WINEARCH=win64 BOX64_NOBANNER=1 BOX64_LOG=1
 export BOX64_LD_LIBRARY_PATH="$RT/box64/x64lib:$RT/wine/lib:$RT/wine/lib64${BOX64_LD_LIBRARY_PATH:+:$BOX64_LD_LIBRARY_PATH}"
 run box64 "$BOX64" -v || true; run wine-version "$BOX64" "$WINE" --version || true; run wineboot "$BOX64" "$WINE" wineboot -u || true
 for b in wine vkd3d-2.6 vkd3d-3.0.1; do
  SYS="$PREFIX/drive_c/windows/system32"; mkdir -p "$SYS"; rm -f "$SYS/d3d12.dll" "$SYS/d3d12core.dll"; O="winemenubuilder.exe=d;mscoree=d;mshtml=d"
  if [ "$b" != wine ]; then SRC="$RT/backends/$b/x64"; [ -f "$SRC/d3d12.dll" ] || continue; cp "$SRC/d3d12.dll" "$SYS/"; [ ! -f "$SRC/d3d12core.dll" ] || cp "$SRC/d3d12core.dll" "$SYS/"; O="d3d12=n,b;d3d12core=n,b;$O"; fi
  export WINEDLLOVERRIDES="$O" VKD3D_DEBUG=info VKD3D_SHADER_DEBUG=info VKD3D_LOG_FILE="$OUT/vkd3d-$b.log"
  run "d3d12-$b" "$BOX64" "$WINE" "$RT/tools/d3d12_smoke.exe" || true
 done
 if [ -f "$GAME/Animal Well.exe" ] && command -v timeout >/dev/null; then export WINEDEBUG=+loaddll,+seh,+timestamp VKD3D_DEBUG=info; run game-loader timeout 20 "$BOX64" "$WINE" "$GAME/Animal Well.exe" || true; fi
fi
sha256sum "$GAME/Animal Well.exe" "$GAME/steam_api64.dll" >"$OUT/game-sha256.txt" 2>/dev/null || true
T="$LOG/diagnostics-$STAMP.tar.gz"; tar -czf "$T" -C "$LOG" "diag-$STAMP" 2>/dev/null || true; echo "$T"
