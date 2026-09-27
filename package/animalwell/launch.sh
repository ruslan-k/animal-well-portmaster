#!/usr/bin/env bash
set -u
GAMEDIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$GAMEDIR/runtime"
GAME_DIR="${ANIMALWELL_GAME_DIR:-$GAMEDIR/game}"
GAME_EXE="${ANIMALWELL_EXE:-$GAME_DIR/Animal Well.exe}"
BACKEND="${ANIMALWELL_BACKEND:-proton214}"
LOGDIR="$GAMEDIR/logs/$BACKEND"
PREFIX="$GAMEDIR/prefix-$BACKEND"
mkdir -p "$LOGDIR" "$PREFIX"

BOX64="$RUNTIME/box64/bin/box64"
WINE="$RUNTIME/wine/bin/wine"
WINESERVER="$RUNTIME/wine/bin/wineserver"

if [ ! -x "$BOX64" ] || [ ! -x "$WINE" ]; then
  echo "Runtime is incomplete: missing Box64 or Wine" >&2; exit 2
fi
if [ ! -f "$GAME_EXE" ]; then
  echo "Missing game executable: $GAME_EXE" >&2
  echo "Copy the legally-owned Windows game files into $GAME_DIR" >&2
  exit 3
fi

export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all,+seh,+loaddll}"
export SteamAppId=813230 SteamGameId=813230
export BOX64_LOG="${BOX64_LOG:-1}"
export BOX64_DYNAREC="${BOX64_DYNAREC:-1}"
export BOX64_DYNAREC_BIGBLOCK="${BOX64_DYNAREC_BIGBLOCK:-2}"
export BOX64_DYNAREC_STRONGMEM="${BOX64_DYNAREC_STRONGMEM:-1}"
export BOX64_DYNAREC_SAFEFLAGS="${BOX64_DYNAREC_SAFEFLAGS:-1}"
export BOX64_LD_LIBRARY_PATH="$RUNTIME/wine/lib64:$RUNTIME/wine/lib64/wine:$RUNTIME/wine/lib:$RUNTIME/wine/lib/wine:${BOX64_LD_LIBRARY_PATH:-}"
export WINEDLLPATH="$RUNTIME/wine/lib64/wine:$RUNTIME/wine/lib/wine"
export WINELOADER="$WINE"
export WINESERVER="$WINESERVER"
export PATH="$RUNTIME/box64/bin:$RUNTIME/wine/bin:$PATH"
export LD_LIBRARY_PATH="$RUNTIME/native-libs:${LD_LIBRARY_PATH:-}"
export VKD3D_DEBUG="${VKD3D_DEBUG:-info}"
export VKD3D_SHADER_DEBUG="${VKD3D_SHADER_DEBUG:-info}"
export VKD3D_LOG_FILE="$LOGDIR/vkd3d.log"
export VKD3D_SHADER_CACHE_PATH="$GAMEDIR/cache/vkd3d-$BACKEND"
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-info}"
export DXVK_LOG_PATH="$LOGDIR"
export DISPLAY="${DISPLAY:-:0}"
mkdir -p "$VKD3D_SHADER_CACHE_PATH"

runwine() { "$BOX64" "$WINE" "$@"; }

install_backend() {
  local sys32="$PREFIX/drive_c/windows/system32"
  mkdir -p "$sys32"
  case "$BACKEND" in
    wine)
      rm -f "$sys32/d3d12.dll" "$sys32/d3d12core.dll" "$sys32/dxgi.dll"
      ;;
    proton214)
      cp -f "$RUNTIME/backends/vkd3d-proton-2.14.1/x64/d3d12.dll" "$sys32/"
      [ -f "$RUNTIME/backends/vkd3d-proton-2.14.1/x64/d3d12core.dll" ] && cp -f "$RUNTIME/backends/vkd3d-proton-2.14.1/x64/d3d12core.dll" "$sys32/"
      cp -f "$RUNTIME/backends/dxvk-2.3.1/x64/dxgi.dll" "$sys32/"
      runwine reg add 'HKCU\Software\Wine\DllOverrides' /v d3d12 /d native,builtin /f >/dev/null 2>&1 || true
      runwine reg add 'HKCU\Software\Wine\DllOverrides' /v d3d12core /d native,builtin /f >/dev/null 2>&1 || true
      runwine reg add 'HKCU\Software\Wine\DllOverrides' /v dxgi /d native,builtin /f >/dev/null 2>&1 || true
      ;;
    proton301)
      cp -f "$RUNTIME/backends/vkd3d-proton-3.0.1/x64/d3d12.dll" "$sys32/"
      [ -f "$RUNTIME/backends/vkd3d-proton-3.0.1/x64/d3d12core.dll" ] && cp -f "$RUNTIME/backends/vkd3d-proton-3.0.1/x64/d3d12core.dll" "$sys32/"
      cp -f "$RUNTIME/backends/dxvk-2.6.2/x64/dxgi.dll" "$sys32/"
      runwine reg add 'HKCU\Software\Wine\DllOverrides' /v d3d12 /d native,builtin /f >/dev/null 2>&1 || true
      runwine reg add 'HKCU\Software\Wine\DllOverrides' /v d3d12core /d native,builtin /f >/dev/null 2>&1 || true
      runwine reg add 'HKCU\Software\Wine\DllOverrides' /v dxgi /d native,builtin /f >/dev/null 2>&1 || true
      ;;
    *) echo "Unknown ANIMALWELL_BACKEND=$BACKEND (wine|proton214|proton301)" >&2; exit 4;;
  esac
}

if [ ! -f "$PREFIX/.initialized" ]; then
  runwine wineboot -u >"$LOGDIR/wineboot.log" 2>&1 || true
  touch "$PREFIX/.initialized"
fi
install_backend
cd "$GAME_DIR"
printf '%s backend=%s exe=%s\n' "$(date -Iseconds 2>/dev/null || date)" "$BACKEND" "$GAME_EXE" >> "$LOGDIR/launch.log"
exec "$BOX64" "$WINE" "$GAME_EXE" >>"$LOGDIR/wine.log" 2>&1
