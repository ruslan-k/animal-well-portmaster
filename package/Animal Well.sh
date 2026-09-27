#!/bin/sh
# ANIMAL WELL / Windows x86-64 -> Box64 -> Wine -> D3D12/Vulkan
# Target: ARM64 PortMaster handhelds; first physical target is TSPS/SpruceOS.
set -u

# Spruce ships extra userland tools here. Keep the script usable without them.
if [ -d /mnt/SDCARD/spruce/bin64 ]; then
    PATH="/mnt/SDCARD/spruce/bin64:$PATH"
    export PATH
fi

# PortMaster's control.txt is a bash script. Re-enter under bash when available,
# but keep the launcher POSIX-compatible so stock TrimUI ash can still run it.
if [ -z "${BASH_VERSION:-}" ] && command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
fi

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT="$SELF/animalwell"
RT="$ROOT/runtime"
GAME="$ROOT/game"
CACHE="$ROOT/cache"
LOGDIR="$ROOT/logs"
LOG="$ROOT/log.txt"
PREV="$ROOT/log.prev.txt"
PFXIMG="$ROOT/prefix.ext2"
PFXMNT="/tmp/animalwell-wineprefix"
LOCKDIR="/tmp/animalwell-port.lock"
BOX64="$RT/box64/box64"
WINE="$RT/wine/bin/wine"
WINESERVER="$RT/wine/bin/wineserver"
EXE="$GAME/Animal Well.exe"
PREFIX_MOUNTED=0
LOCK_OWNED=0
PM_READY=0

mkdir -p "$CACHE/vkd3d" "$LOGDIR"
[ -f "$LOG" ] && mv -f "$LOG" "$PREV" 2>/dev/null || true
: > "$LOG"
exec >>"$LOG" 2>&1

stamp() { date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || date 2>/dev/null || echo unknown; }
log() { echo "[$(stamp)] $*"; }

root_run() {
    if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif [ -n "${ESUDO:-}" ]; then
        # PortMaster intentionally exposes ESUDO as a command plus arguments.
        # shellcheck disable=SC2086
        $ESUDO "$@"
    else
        "$@"
    fi
}

setup_portmaster() {
    [ -n "${BASH_VERSION:-}" ] || return 0
    controlfolder="${controlfolder:-}"
    if [ -z "$controlfolder" ]; then
        for c in \
            /mnt/SDCARD/Apps/PortMaster/PortMaster \
            /PortMaster \
            /opt/system/Tools/PortMaster \
            /opt/tools/PortMaster \
            "${XDG_DATA_HOME:-$HOME/.local/share}/PortMaster" \
            /roms/ports/PortMaster \
            /mnt/SDCARD/Roms/ports/PortMaster; do
            if [ -f "$c/control.txt" ]; then controlfolder="$c"; break; fi
        done
    fi
    if [ -n "$controlfolder" ] && [ -f "$controlfolder/control.txt" ]; then
        # shellcheck disable=SC1090
        . "$controlfolder/control.txt"
        if [ -n "${CFW_NAME:-}" ] && [ -f "$controlfolder/mod_${CFW_NAME}.txt" ]; then
            # shellcheck disable=SC1090
            . "$controlfolder/mod_${CFW_NAME}.txt"
        fi
        if command -v get_controls >/dev/null 2>&1; then get_controls || true; fi
        if [ -n "${sdl_controllerconfig:-}" ]; then
            SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
            export SDL_GAMECONTROLLERCONFIG
        fi
        PM_READY=1
        export controlfolder
        log "PortMaster integration: controlfolder=$controlfolder cfw=${CFW_NAME:-unknown} device=${DEVICE:-unknown} arch=${DEVICE_ARCH:-unknown}"
    else
        log "PortMaster control.txt not found; using standalone launcher path"
    fi
}

acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"
        LOCK_OWNED=1
        return 0
    fi
    oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        log "ERROR another ANIMAL WELL launcher is active: pid=$oldpid"
        return 1
    fi
    rm -rf "$LOCKDIR" 2>/dev/null || true
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"
        LOCK_OWNED=1
        return 0
    fi
    log "ERROR cannot acquire $LOCKDIR"
    return 1
}

mount_prefix() {
    [ -f "$PFXIMG" ] || { log "ERROR missing Wine prefix image: $PFXIMG"; return 1; }
    mkdir -p "$PFXMNT"
    if grep -qs " $PFXMNT " /proc/mounts 2>/dev/null; then
        log "stale prefix mount found; attempting clean unmount"
        root_run umount "$PFXMNT" >/dev/null 2>&1 || root_run umount -l "$PFXMNT" >/dev/null 2>&1 || return 1
    fi
    if root_run mount -t ext2 -o loop,rw,noatime "$PFXIMG" "$PFXMNT"; then
        PREFIX_MOUNTED=1
    elif root_run mount -t ext4 -o loop,rw,noatime "$PFXIMG" "$PFXMNT"; then
        PREFIX_MOUNTED=1
    elif root_run mount -o loop,rw,noatime "$PFXIMG" "$PFXMNT"; then
        PREFIX_MOUNTED=1
    else
        log "ERROR failed to loop-mount Wine prefix image"
        return 1
    fi
    [ -f "$PFXMNT/system.reg" ] || { log "ERROR mounted prefix has no system.reg"; return 1; }
    log "Wine prefix mounted: $PFXIMG -> $PFXMNT"
}

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM 2>/dev/null || true
    if [ "$PREFIX_MOUNTED" = 1 ]; then
        if [ -x "$BOX64" ] && [ -x "$WINESERVER" ]; then
            "$BOX64" "$WINESERVER" -k >/dev/null 2>&1 || true
            sleep 1
        fi
        sync 2>/dev/null || true
        root_run umount "$PFXMNT" >/dev/null 2>&1 || root_run umount -l "$PFXMNT" >/dev/null 2>&1 || true
        PREFIX_MOUNTED=0
    fi
    rmdir "$PFXMNT" 2>/dev/null || true
    if [ "$LOCK_OWNED" = 1 ]; then rm -rf "$LOCKDIR" 2>/dev/null || true; fi
    if [ "$PM_READY" = 1 ] && command -v pm_finish >/dev/null 2>&1; then pm_finish >/dev/null 2>&1 || true; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log "=== ANIMAL WELL PortMaster Windows runtime ==="
log "launcher_version=2026-09-27.2"
log "self=$SELF"
log "root=$ROOT"
log "uname=$(uname -a 2>/dev/null || echo unavailable)"
log "display=${DISPLAY:-unset} wayland=${WAYLAND_DISPLAY:-unset}"
log "uid=$(id -u 2>/dev/null || echo unknown) gid=$(id -g 2>/dev/null || echo unknown)"

setup_portmaster
acquire_lock || exit 10

[ -x "$BOX64" ] || { log "ERROR missing/executable Box64: $BOX64"; exit 11; }
[ -x "$WINE" ] || { log "ERROR missing/executable Wine: $WINE"; exit 12; }
[ -f "$EXE" ] || { log "ERROR missing game executable: $EXE"; exit 13; }
[ -f "$GAME/steam_api64.dll" ] || { log "ERROR missing steam_api64.dll"; exit 14; }
[ -f "$GAME/steam_appid.txt" ] || { log "ERROR missing steam_appid.txt"; exit 15; }

BACKEND=${AW_BACKEND:-wine}
if [ -z "${AW_BACKEND:-}" ] && [ -f "$ROOT/backend" ]; then BACKEND=$(tr -d '\r\n ' < "$ROOT/backend"); fi
case "$BACKEND" in
    wine|'') BACKEND=wine ;;
    vkd3d-2.6|vkd3d-3.0.1) ;;
    *) log "ERROR unknown backend '$BACKEND'"; exit 16 ;;
esac
log "backend=$BACKEND"

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$EXE" "$GAME/steam_api64.dll" 2>/dev/null || true
fi

# Let PortMaster perform its platform/display handoff when available.
if [ "$PM_READY" = 1 ] && command -v pm_platform_helper >/dev/null 2>&1; then
    log "calling pm_platform_helper for Box64"
    pm_platform_helper "$BOX64" || log "WARNING pm_platform_helper returned non-zero"
fi
log "display_after_pm=${DISPLAY:-unset} wayland_after_pm=${WAYLAND_DISPLAY:-unset}"

# Native Vulkan must exist before a D3D12-over-Vulkan path can work.
if [ -x "$RT/tools/vkprobe" ]; then
    log "--- native Vulkan probe ---"
    if ! "$RT/tools/vkprobe"; then
        log "ERROR native Vulkan probe failed; not starting Wine"
        "$ROOT/diagnose.sh" --collect-only >/dev/null 2>&1 || true
        exit 20
    fi
else
    log "WARNING vkprobe missing; continuing"
fi

mount_prefix || { "$ROOT/diagnose.sh" --collect-only >/dev/null 2>&1 || true; exit 21; }

export WINEPREFIX="$PFXMNT"
export WINEARCH=win64
export WINEESYNC=0
export WINEFSYNC=0
export BOX64_NOBANNER=1
export BOX64_DYNAREC=1
export BOX64_DYNACACHE=1
export BOX64_LOG=${BOX64_LOG:-1}
export BOX64_LD_LIBRARY_PATH="$RT/box64/x64lib:$RT/wine/lib:$RT/wine/lib64${BOX64_LD_LIBRARY_PATH:+:$BOX64_LD_LIBRARY_PATH}"
export XDG_CACHE_HOME="$CACHE"
export VKD3D_SHADER_CACHE_PATH="$CACHE/vkd3d"
export VKD3D_DEBUG=${VKD3D_DEBUG:-warn}
export WINEDEBUG=${WINEDEBUG:--all}

SYS="$WINEPREFIX/drive_c/windows/system32"
mkdir -p "$SYS"
SRC="$RT/backends/$BACKEND/x64"
[ -f "$SRC/d3d12.dll" ] || { log "ERROR missing $SRC/d3d12.dll"; exit 22; }
rm -f "$SYS/d3d12.dll" "$SYS/d3d12core.dll"
cp "$SRC/d3d12.dll" "$SYS/d3d12.dll"
[ ! -f "$SRC/d3d12core.dll" ] || cp "$SRC/d3d12core.dll" "$SYS/d3d12core.dll"
OVERRIDES="winemenubuilder.exe=d;mscoree=d;mshtml=d"
case "$BACKEND" in
    wine) ;;
    vkd3d-2.6|vkd3d-3.0.1) OVERRIDES="d3d12=n,b;d3d12core=n,b;$OVERRIDES" ;;
esac
export WINEDLLOVERRIDES="$OVERRIDES"

log "--- Box64 version ---"
"$BOX64" -v 2>&1 || true
log "--- Wine version ---"
"$BOX64" "$WINE" --version 2>&1 || true
log "--- starting game ---"
cd "$GAME"
"$BOX64" "$WINE" "$EXE"
RC=$?
log "game_exit_code=$RC"

if [ "$RC" -ne 0 ]; then
    log "game failed; collecting diagnostics"
    "$ROOT/diagnose.sh" --collect-only "$RC" || true
fi
exit "$RC"
