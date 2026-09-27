#!/bin/sh
# ANIMAL WELL / Windows x86-64 -> Box64 -> Wine -> D3D12/Vulkan
# Physical target: TrimUI Smart Pro S / SpruceOS.
set -u

if [ -d /mnt/SDCARD/spruce/bin64 ]; then
    PATH="/mnt/SDCARD/spruce/bin64:$PATH"
    export PATH
fi
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
PFXTPL="$ROOT/prefix-template"
PFX="/tmp/animalwell-wineprefix"
PERSIST_USER="$ROOT/wine-user/root"
LOCKDIR="/tmp/animalwell-port.lock"
XCONF="/tmp/animalwell-xorg.conf"
BOX64="$RT/box64/box64"
WINE="$RT/wine/bin/wine"
WINESERVER="$RT/wine/bin/wineserver"
SMOKE="$RT/tools/d3d12_smoke.exe"
EXE="$GAME/Animal Well.exe"
PM_READY=0
LOCK_OWNED=0
XORG_PID=""
XORG_STARTED=0

mkdir -p "$CACHE/vkd3d" "$LOGDIR" "$PERSIST_USER"
[ -f "$LOG" ] && mv -f "$LOG" "$PREV" 2>/dev/null || true
: >"$LOG"
exec >>"$LOG" 2>&1

stamp() { date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || date 2>/dev/null || echo unknown; }
log() { echo "[$(stamp)] $*"; }

setup_portmaster() {
    [ -n "${BASH_VERSION:-}" ] || return 0
    controlfolder="${controlfolder:-}"
    if [ -z "$controlfolder" ]; then
        for c in             /mnt/SDCARD/Apps/PortMaster/PortMaster             /PortMaster             /opt/system/Tools/PortMaster             /opt/tools/PortMaster             "${XDG_DATA_HOME:-$HOME/.local/share}/PortMaster"             /roms/ports/PortMaster             /mnt/SDCARD/Roms/ports/PortMaster; do
            if [ -f "$c/control.txt" ]; then controlfolder="$c"; break; fi
        done
    fi
    if [ -n "$controlfolder" ] && [ -f "$controlfolder/control.txt" ]; then
        . "$controlfolder/control.txt"
        if [ -n "${CFW_NAME:-}" ] && [ -f "$controlfolder/mod_${CFW_NAME}.txt" ]; then
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
        echo $$ >"$LOCKDIR/pid"
        LOCK_OWNED=1
        return 0
    fi
    oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        log "ERROR another ANIMAL WELL launcher is active: pid=$oldpid"
        return 1
    fi
    rm -rf "$LOCKDIR" 2>/dev/null || true
    mkdir "$LOCKDIR" 2>/dev/null || return 1
    echo $$ >"$LOCKDIR/pid"
    LOCK_OWNED=1
}

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM 2>/dev/null || true
    if [ -x "$BOX64" ] && [ -x "$WINESERVER" ]; then
        "$BOX64" "$WINESERVER" -k >/dev/null 2>&1 || true
        sleep 1
    fi
    rm -rf "$PFX" 2>/dev/null || true
    if [ "$XORG_STARTED" = 1 ] && [ -n "$XORG_PID" ]; then
        kill "$XORG_PID" >/dev/null 2>&1 || true
        wait "$XORG_PID" >/dev/null 2>&1 || true
    fi
    rm -f "$XCONF" 2>/dev/null || true
    if [ "$LOCK_OWNED" = 1 ]; then rm -rf "$LOCKDIR" 2>/dev/null || true; fi
    if [ "$PM_READY" = 1 ] && command -v pm_finish >/dev/null 2>&1; then
        pm_finish >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run_timeout() {
    seconds=$1
    shift
    if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"; else "$@"; fi
}

setup_prefix() {
    [ -f "$PFXTPL/system.reg" ] || { log "ERROR missing $PFXTPL/system.reg"; return 1; }
    [ -d "$RT/wine/lib/wine/x86_64-windows" ] || { log "ERROR missing Wine x86_64-windows tree"; return 1; }
    [ -d "$RT/wine/lib/wine/i386-windows" ] || { log "ERROR missing Wine i386-windows tree"; return 1; }

    rm -rf "$PFX"
    mkdir -p "$PFX/dosdevices" "$PFX/drive_c/windows" "$PFX/drive_c/users"         "$PFX/drive_c/Program Files" "$PFX/drive_c/Program Files (x86)"         "$PFX/drive_c/ProgramData" "$PFX/drive_c/windows/temp" "$PFX/drive_c/aw-smoke"
    cp "$PFXTPL/system.reg" "$PFX/system.reg"
    cp "$PFXTPL/user.reg" "$PFX/user.reg"
    cp "$PFXTPL/userdef.reg" "$PFX/userdef.reg"
    [ ! -f "$PFXTPL/.update-timestamp" ] || cp "$PFXTPL/.update-timestamp" "$PFX/.update-timestamp"

    ln -s ../drive_c "$PFX/dosdevices/c:" || return 1
    ln -s / "$PFX/dosdevices/z:" || return 1
    ln -s "$RT/wine/lib/wine/x86_64-windows" "$PFX/drive_c/windows/system32" || return 1
    ln -s "$RT/wine/lib/wine/i386-windows" "$PFX/drive_c/windows/syswow64" || return 1
    ln -s "$PERSIST_USER" "$PFX/drive_c/users/root" || return 1

    [ -f "$PFX/drive_c/windows/system32/kernel32.dll" ] || {
        log "ERROR lightweight prefix cannot see kernel32.dll"
        return 1
    }
    log "Wine prefix ready in $PFX (registry in tmpfs, PE DLLs symlinked from SD)"
}

write_xorg_config() {
    cat >"$XCONF" <<'EOF_XORG'
Section "ServerFlags"
    Option "AutoAddDevices" "true"
    Option "DontVTSwitch" "true"
EndSection

Section "Device"
    Identifier "Framebuffer"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
    Option "ShadowFB" "true"
EndSection

Section "Monitor"
    Identifier "Monitor0"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Framebuffer"
    Monitor "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
    EndSubSection
EndSection

Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0"
EndSection
EOF_XORG
}

display_usable() {
    d=$1
    n=${d#:}
    n=${n%%.*}
    [ -S "/tmp/.X11-unix/X$n" ] || return 1
    if command -v xdpyinfo >/dev/null 2>&1; then
        DISPLAY="$d" xdpyinfo >/dev/null 2>&1 || return 1
    fi
    return 0
}

ensure_display() {
    if [ -n "${DISPLAY:-}" ] && display_usable "$DISPLAY"; then
        log "using inherited X display $DISPLAY"
        return 0
    fi
    for d in :0 :1; do
        if display_usable "$d"; then
            DISPLAY="$d"; export DISPLAY
            log "using existing X display $DISPLAY"
            return 0
        fi
    done

    XORG=""
    for x in "$(command -v Xorg 2>/dev/null || true)" /usr/bin/Xorg /usr/bin/X /usr/trimui/bin/Xorg /mnt/SDCARD/spruce/bin64/Xorg; do
        [ -n "$x" ] && [ -x "$x" ] && { XORG="$x"; break; }
    done
    [ -n "$XORG" ] || { log "ERROR no Xorg/X server found and DISPLAY is unset"; return 1; }

    # Clear only a proven stale :1 lock. Never kill an existing X server.
    if [ -f /tmp/.X1-lock ]; then
        xp=$(tr -dc '0-9' </tmp/.X1-lock 2>/dev/null || true)
        if [ -z "$xp" ] || ! kill -0 "$xp" 2>/dev/null; then
            rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
        fi
    fi

    write_xorg_config
    log "starting Xorg fbdev on :1 with $XORG"
    "$XORG" :1 -ac -nolisten tcp -noreset -config "$XCONF" -logfile "$LOGDIR/Xorg.1.log"         >"$LOGDIR/Xorg-stdout.log" 2>&1 &
    XORG_PID=$!
    XORG_STARTED=1

    i=0
    while [ "$i" -lt 8 ]; do
        sleep 1
        if display_usable :1; then
            DISPLAY=:1; export DISPLAY
            log "Xorg ready: DISPLAY=$DISPLAY pid=$XORG_PID"
            return 0
        fi
        kill -0 "$XORG_PID" 2>/dev/null || break
        i=$((i + 1))
    done

    log "ERROR Xorg did not become usable"
    tail -120 "$LOGDIR/Xorg.1.log" 2>/dev/null || true
    tail -120 "$LOGDIR/Xorg-stdout.log" 2>/dev/null || true
    return 1
}

base_overrides='winemenubuilder.exe=d;mscoree=d;mshtml=d'

prepare_smoke_backend() {
    backend=$1
    SDIR="$PFX/drive_c/aw-smoke"
    rm -f "$SDIR/d3d12_smoke.exe" "$SDIR/d3d12.dll" "$SDIR/d3d12core.dll"
    cp "$SMOKE" "$SDIR/d3d12_smoke.exe" || return 1
    case "$backend" in
        wine)
            WINEDLLOVERRIDES="d3d12=b;d3d12core=b;$base_overrides"
            ;;
        vkd3d-2.6|vkd3d-3.0.1)
            SRC="$RT/backends/$backend/x64"
            [ -f "$SRC/d3d12.dll" ] || return 1
            cp "$SRC/d3d12.dll" "$SDIR/d3d12.dll"
            [ ! -f "$SRC/d3d12core.dll" ] || cp "$SRC/d3d12core.dll" "$SDIR/d3d12core.dll"
            WINEDLLOVERRIDES="d3d12=n,b;d3d12core=n,b;$base_overrides"
            ;;
        *) return 1 ;;
    esac
    export WINEDLLOVERRIDES
}

prepare_game_backend() {
    backend=$1
    rm -f "$GAME/d3d12.dll" "$GAME/d3d12core.dll"
    case "$backend" in
        wine)
            WINEDLLOVERRIDES="d3d12=b;d3d12core=b;$base_overrides"
            ;;
        vkd3d-2.6|vkd3d-3.0.1)
            SRC="$RT/backends/$backend/x64"
            [ -f "$SRC/d3d12.dll" ] || return 1
            cp "$SRC/d3d12.dll" "$GAME/d3d12.dll"
            [ ! -f "$SRC/d3d12core.dll" ] || cp "$SRC/d3d12core.dll" "$GAME/d3d12core.dll"
            WINEDLLOVERRIDES="d3d12=n,b;d3d12core=n,b;$base_overrides"
            ;;
        *) return 1 ;;
    esac
    export WINEDLLOVERRIDES
}

probe_backend() {
    backend=$1
    prepare_smoke_backend "$backend" || return 1
    logfile="$LOGDIR/backend-$backend.log"
    log "D3D12 smoke backend=$backend"
    VKD3D_DEBUG=info VKD3D_LOG_FILE="$LOGDIR/vkd3d-$backend.log"         run_timeout 30 "$BOX64" "$WINE" "$PFX/drive_c/aw-smoke/d3d12_smoke.exe" >"$logfile" 2>&1
    rc=$?
    tail -80 "$logfile" 2>/dev/null || true
    return "$rc"
}

select_backend() {
    requested=auto
    [ ! -f "$ROOT/backend" ] || requested=$(tr -d '\r\n ' <"$ROOT/backend")
    [ -n "$requested" ] || requested=auto

    if [ "$requested" != auto ]; then
        prepare_game_backend "$requested" || return 1
        printf '%s\n' "$requested" >"$ROOT/backend.selected-v2"
        echo "$requested"
        return 0
    fi

    if [ -f "$ROOT/backend.selected-v2" ]; then
        cached=$(tr -d '\r\n ' <"$ROOT/backend.selected-v2")
        if prepare_game_backend "$cached"; then
            echo "$cached"
            return 0
        fi
        rm -f "$ROOT/backend.selected-v2"
    fi

    for candidate in wine vkd3d-2.6 vkd3d-3.0.1; do
        if probe_backend "$candidate"; then
            printf '%s\n' "$candidate" >"$ROOT/backend.selected-v2"
            prepare_game_backend "$candidate" || return 1
            echo "$candidate"
            return 0
        fi
    done

    # Keep Wine VKD3D as the least demanding real-game attempt even if the
    # standalone smoke probe cannot create a device/swapchain.
    prepare_game_backend wine || return 1
    printf '%s\n' wine >"$ROOT/backend.selected-v2"
    echo wine
}

log "=== ANIMAL WELL PortMaster Windows runtime ==="
log "launcher_version=2026-09-27.3"
log "self=$SELF"
log "root=$ROOT"
log "uname=$(uname -a 2>/dev/null || echo unavailable)"
log "uid=$(id -u 2>/dev/null || echo unknown) gid=$(id -g 2>/dev/null || echo unknown)"
log "sd_mount=$(grep ' /mnt/SDCARD ' /proc/mounts 2>/dev/null | head -1 || true)"

setup_portmaster
acquire_lock || exit 10

[ -x "$BOX64" ] || { log "ERROR missing/executable Box64: $BOX64"; exit 11; }
[ -x "$WINE" ] || { log "ERROR missing/executable Wine: $WINE"; exit 12; }
[ -f "$EXE" ] || { log "ERROR missing game executable: $EXE"; exit 13; }
[ -f "$GAME/steam_api64.dll" ] || { log "ERROR missing steam_api64.dll"; exit 14; }
[ -f "$GAME/steam_appid.txt" ] || { log "ERROR missing steam_appid.txt"; exit 15; }

if [ "$PM_READY" = 1 ] && command -v pm_platform_helper >/dev/null 2>&1; then
    log "calling pm_platform_helper for Box64"
    pm_platform_helper "$BOX64" || log "WARNING pm_platform_helper returned non-zero"
fi

setup_prefix || exit 18

export WINEPREFIX="$PFX"
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
export WINEDEBUG=${WINEDEBUG:--all}

log "--- prefix sanity ---"
if ! run_timeout 20 "$BOX64" "$WINE" cmd /c ver >"$LOGDIR/prefix-sanity.log" 2>&1; then
    log "ERROR Wine lightweight prefix sanity failed"
    cat "$LOGDIR/prefix-sanity.log" 2>/dev/null || true
    "$ROOT/diagnose.sh" --collect-only >/dev/null 2>&1 || true
    exit 18
fi
cat "$LOGDIR/prefix-sanity.log" 2>/dev/null || true

if [ -x "$RT/tools/vkprobe" ]; then
    log "--- native Vulkan probe ---"
    "$RT/tools/vkprobe" >"$LOGDIR/vkprobe.log" 2>&1 || true
    cat "$LOGDIR/vkprobe.log" 2>/dev/null || true
fi

ensure_display || {
    "$ROOT/diagnose.sh" --collect-only >/dev/null 2>&1 || true
    exit 19
}

BACKEND=$(select_backend | tee "$LOGDIR/backend-selection.log" | tail -n 1)
prepare_game_backend "$BACKEND" || { log "ERROR failed to configure backend=$BACKEND"; exit 22; }

log "--- Box64 version ---"
"$BOX64" -v 2>&1 || true
log "--- Wine version ---"
"$BOX64" "$WINE" --version 2>&1 || true
log "--- starting game ---"
log "backend=$BACKEND display=${DISPLAY:-unset} wayland=${WAYLAND_DISPLAY:-unset}"
log "mem_available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$EXE" "$GAME/steam_api64.dll" 2>/dev/null || true
fi

export VKD3D_DEBUG=${VKD3D_DEBUG:-warn}
export VKD3D_LOG_FILE="$LOGDIR/vkd3d-game.log"

cd "$GAME"
set +e
"$BOX64" "$WINE" "$EXE"
RC=$?
set -e 2>/dev/null || true
log "game_exit_code=$RC"

if [ "$RC" -ne 0 ]; then
    log "game failed; collecting diagnostics"
    "$ROOT/diagnose.sh" --collect-only "$RC" || true
fi
exit "$RC"
