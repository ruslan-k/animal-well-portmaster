#!/bin/sh
set -eu
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT="$SELF/animalwell"; RT="$ROOT/runtime"; GAME="$ROOT/game"; PREFIX="$ROOT/prefix"; LOG="$ROOT/logs"
mkdir -p "$PREFIX" "$LOG" "$ROOT/cache/vkd3d"
BOX64="$RT/box64/box64"; WINE="$RT/wine/bin/wine"; EXE="$GAME/Animal Well.exe"
[ -x "$BOX64" ] || { echo "missing $BOX64" >&2; exit 2; }
[ -x "$WINE" ] || { echo "missing $WINE" >&2; exit 2; }
[ -f "$EXE" ] || { echo "copy Animal Well.exe, steam_api64.dll and steam_appid.txt to $GAME" >&2; exit 2; }
BACKEND=wine; [ -f "$ROOT/backend" ] && BACKEND=$(tr -d '\r\n ' < "$ROOT/backend")
export WINEPREFIX="$PREFIX" WINEARCH=win64 BOX64_NOBANNER=1 BOX64_DYNAREC=1 BOX64_DYNACACHE=1
export BOX64_LD_LIBRARY_PATH="$RT/box64/x64lib:$RT/wine/lib:$RT/wine/lib64${BOX64_LD_LIBRARY_PATH:+:$BOX64_LD_LIBRARY_PATH}"
export XDG_CACHE_HOME="$ROOT/cache" VKD3D_SHADER_CACHE_PATH="$ROOT/cache/vkd3d" WINEDEBUG=-all
if [ ! -f "$PREFIX/.ready" ]; then "$BOX64" "$WINE" wineboot -u >"$LOG/wineboot.log" 2>&1 || true; touch "$PREFIX/.ready"; fi
SYS="$PREFIX/drive_c/windows/system32"; mkdir -p "$SYS"; rm -f "$SYS/d3d12.dll" "$SYS/d3d12core.dll"
export WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree=d;mshtml=d"
case "$BACKEND" in
 wine|'') ;;
 vkd3d-2.6|vkd3d-3.0.1) SRC="$RT/backends/$BACKEND/x64"; cp "$SRC/d3d12.dll" "$SYS/d3d12.dll"; [ ! -f "$SRC/d3d12core.dll" ] || cp "$SRC/d3d12core.dll" "$SYS/d3d12core.dll"; export WINEDLLOVERRIDES="d3d12=n,b;d3d12core=n,b;$WINEDLLOVERRIDES" ;;
 *) echo "unknown backend: $BACKEND" >&2; exit 3;;
esac
cd "$GAME"
exec "$BOX64" "$WINE" "$EXE"
