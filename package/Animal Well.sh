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
T14="$RT/test14"
MALIDIR="/tmp/animalwell-mali-driver"
XORG_SOURCE=""
XORG_CONFIG=""
XORG_LD_PATH="${XORG_LD_PATH:-}"
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
    # PortMaster's control.txt/device_info helpers are not nounset-safe.
    # Temporarily disable `set -u` while sourcing the framework, then restore it.
    set +u
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
    set -u
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
    cpu_preset_restore
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
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        # The device has no timeout(1). Without a bound, a wedged Wine client
        # (known first-display-client behaviour) would hang the launcher forever.
        "$@" &
        _rtp=$!
        ( sleep "$seconds"; kill -TERM "$_rtp" 2>/dev/null; sleep 2; kill -KILL "$_rtp" 2>/dev/null ) &
        _rtw=$!
        wait "$_rtp" 2>/dev/null
        _rtrc=$?
        kill "$_rtw" 2>/dev/null
        return "$_rtrc"
    fi
}

discover_xorg_runtime_paths() {
    # Populate Xorg/Totono runtime library roots even when DISPLAY already exists.
    # Wine winex11.so needs these too.
    for d in \
        /mnt/UDISK/xorg-libs/lib/aarch64-linux-gnu \
        /mnt/UDISK/xorg-libs/usr/lib/aarch64-linux-gnu \
        /mnt/UDISK/xorg/usr/lib/aarch64-linux-gnu; do
        [ -d "$d" ] && case ":$XORG_LD_PATH:" in *":$d:"*) ;; *) XORG_LD_PATH="${XORG_LD_PATH:+$XORG_LD_PATH:}$d" ;; esac
    done
    for t in \
        /mnt/SDCARD/Roms/PORTS/you-and-me-and-her/totono-runtime \
        /mnt/SDCARD/Roms/ports/you-and-me-and-her/totono-runtime \
        /mnt/sdcard/mmcblk1p1/Roms/ports/you-and-me-and-her/totono-runtime; do
        for d in "$t/arm64-libs/gl" "$t/arm64-libs"; do
            [ -d "$d" ] && case ":$XORG_LD_PATH:" in *":$d:"*) ;; *) XORG_LD_PATH="${XORG_LD_PATH:+$XORG_LD_PATH:}$d" ;; esac
        done
        if [ -f "$t/totono-fb.conf" ] && [ -z "$XORG_CONFIG" ]; then XORG_CONFIG="$t/totono-fb.conf"; fi
    done
}

setup_vulkan_env() {
    # TSPS loader pick: prefer the port-bundled 1.2.131 loader (test14/deps),
    # which exposes the X11 WSI extensions (VK_KHR_xcb/xlib_surface) that
    # Wine's win32u needs to map win32_surface. The firmware loader (1.3.296)
    # was built without X11 WSI and filters them out, which broke vkd3d
    # instance creation. The wrapper exports vk_icdGetPhysicalDeviceProcAddr,
    # so the 1.2.x loaders no longer crash in
    # loader_check_icds_for_phys_dev_ext_address on unknown-name probes.
    rm -f /tmp/animalwell-loader/libvulkan.so.1 2>/dev/null || true
    mkdir -p /tmp/animalwell-loader
    LOADER_PICK=
    for cand in "$T14/deps/libvulkan.so.1" \
        /mnt/UDISK/xorg-libs/usr/lib/aarch64-linux-gnu/libvulkan.so.1 \
        /usr/lib/libvulkan.so.1; do
        if [ -e "$cand" ]; then
            ln -sf "$cand" /tmp/animalwell-loader/libvulkan.so.1
            LOADER_PICK=/tmp/animalwell-loader
            log "loader_source=$cand"
            break
        fi
    done

    mkdir -p "$MALIDIR"
    MALI_SO=$(ls -1 /usr/lib/libmali.so.0* 2>/dev/null | head -1 || true)
    if [ -n "$MALI_SO" ]; then
        ln -sf "$MALI_SO" "$MALIDIR/libmali.so.0"
        ln -sf "$MALI_SO" "$MALIDIR/libmali.so"
    fi

    ICDJSON="/tmp/animalwell-icd-$$.json"
    printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s/lib/libmali_wrapper.so","api_version":"1.3.276"}}\n' "$T14" >"$ICDJSON"
    export VK_ICD_FILENAMES="$ICDJSON"
    export WSI_X11_FORCE_SHM=1
    export MALI_WRAPPER_LOG_CATEGORY=wrapper
    export MALI_WRAPPER_LOG_LEVEL=0
    export MALI_WRAPPER_LOG_CONSOLE=0
    export MALI_WRAPPER_LOG_FILE="$LOGDIR/aw-wrapper.log"
    export WINE_D3D_CONFIG="renderer=no3d"
    # Belt: every Wine child must see :1 even if a stray unset happened.
    export DISPLAY="${DISPLAY:-:1}"
    export LD_LIBRARY_PATH="${LOADER_PICK:+$LOADER_PICK:}$T14/deps:$T14/lib:$MALIDIR${XORG_LD_PATH:+:$XORG_LD_PATH}:/mnt/SDCARD/Persistent/portmaster/lib:/mnt/SDCARD/spruce/flip/lib:/usr/trimui/lib:/usr/lib:/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    log "vulkan_env: loader_pick=${LOADER_PICK:-<bundled>} icd=$ICDJSON mali=${MALI_SO:-<none>} wsi_force_shm=1 renderer=no3d"
}

harden_prefix_for_wine() {
    # [v10 LATE] Window fix applied AFTER the clean staging/probe phase, so
    # the win32u/vkd3d session state forms without these PE copies, while the
    # game/explorer processes (spawned after wineboot) still find them in
    # C:\windows\system32. Without the copies: nodrv ("Application tried to
    # create a window, but no driver could be loaded") in the game process.
    # No registry writes, no wineserver restart here (must not disturb the
    # seeded session).
    SYS32="$PFX/drive_c/windows/system32"
    mkdir -p "$SYS32" 2>/dev/null || true
    for _d in winspool.drv winex11.drv; do
        if [ ! -f "$SYS32/$_d" ] && [ -f "$RT/wine/lib/wine/x86_64-windows/$_d" ]; then
            cp "$RT/wine/lib/wine/x86_64-windows/$_d" "$SYS32/$_d" 2>/dev/null || true
        fi
    done
    if [ ! -f "$SYS32/rpcss.exe" ] && [ -f "$RT/wine/lib/wine/x86_64-windows/rpcss.exe" ]; then
        cp "$RT/wine/lib/wine/x86_64-windows/rpcss.exe" "$SYS32/rpcss.exe" 2>/dev/null || true
    fi
    log "prefix_pe_fix(late): winex11.drv/winspool.drv/rpcss.exe ensured in system32"
}

run_watchdog() {
    # Bound any Wine client: no timeout(1) on the device, and the first
    # display client of a fresh session is known to wedge instead of exiting.
    _wlimit=$1
    shift
    "$@" &
    _wp=$!
    ( sleep "$_wlimit"; kill -TERM "$_wp" 2>/dev/null; sleep 2; kill -KILL "$_wp" 2>/dev/null ) &
    _ww=$!
    wait "$_wp" 2>/dev/null
    _wrc=$?
    kill "$_ww" 2>/dev/null
    return "$_wrc"
}

seed_display_session() {
    # Harness-shaped display warmup (test14-15-wsi.sh): a real-env baseline
    # client, a killed wineserver, then the display registry is seeded by a
    # display-kmt client with GPU discovery DISABLED (nonexistent ICD, empty
    # GL stubs, WINEDEBUG=-all). That wineserver is KEPT ALIVE and a fresh
    # client with the real GPU env re-uses it. Probes and the game then run in
    # the same seeded session.
    SSSMK="$PFX/drive_c/aw-smoke/d3d12_smoke.exe"
    mkdir -p "$PFX/drive_c/aw-smoke" 2>/dev/null || true
    [ -f "$SSSMK" ] || cp -f "$RT/tools/d3d12_smoke.exe" "$SSSMK" 2>/dev/null || true
    [ -x "$SSSMK" ] || { log "seed: no smoke binary in prefix, skip"; return 0; }

    log "--- display baseline (real env, keep going regardless) ---"
    run_watchdog 15 env WINE_D3D_CONFIG=renderer=no3d VKD3D_DEBUG=info VKD3D_LOG_FILE="$LOGDIR/vkd3d-seed0.log" "$BOX64" "$WINE" "$SSSMK" display-kmt >"$LOGDIR/seed-display0.log" 2>&1
    log "baseline rc=$? (expected to wedge/fail)"
    "$BOX64" "$WINESERVER" -k >/dev/null 2>&1 || true
    sleep 1

    NO_GL_DIR="/tmp/animalwell-no-opengl"
    rm -rf "$NO_GL_DIR"
    mkdir -p "$NO_GL_DIR"
    : >"$NO_GL_DIR/libEGL.so.1"
    : >"$NO_GL_DIR/libGL.so.1"

    log "--- display session seed (display-kmt, degraded GPU env, keep-server) ---"
    (
        export VK_ICD_FILENAMES=/tmp/animalwell-no-vulkan-icd-does-not-exist.json
        export LD_LIBRARY_PATH="$NO_GL_DIR:$LD_LIBRARY_PATH"
        export WINEDEBUG=-all
        export WINE_D3D_CONFIG=renderer=no3d
        export MALI_WRAPPER_LOG_CATEGORY=wrapper
        export MALI_WRAPPER_LOG_LEVEL=0
        export MALI_WRAPPER_LOG_CONSOLE=0
        export MALI_WRAPPER_LOG_FILE="$LOGDIR/aw-wrapper-seed.log"
        run_watchdog 130 "$BOX64" "$WINE" "$SSSMK" display-kmt >"$LOGDIR/seed-display.log" 2>&1
    )
    src=$?
    marker=$(grep -a "SMOKE_RESULT" "$LOGDIR/seed-display.log" 2>/dev/null | tail -n 1 || true)
    log "seed: rc=$src marker=${marker:-none} (rc=137 after the marker is the proven-good shape)"
    rm -rf "$NO_GL_DIR"

    log "--- display same-server (real GPU env) ---"
    env WINE_D3D_CONFIG=renderer=no3d VKD3D_DEBUG=info VKD3D_LOG_FILE="$LOGDIR/vkd3d-seed2.log" "$BOX64" "$WINE" "$SSSMK" display-kmt >"$LOGDIR/seed-display2.log" 2>&1 &
    sp2=$!
    ( sleep 40; kill -TERM "$sp2" 2>/dev/null; sleep 2; kill -KILL "$sp2" 2>/dev/null ) &
    wd2=$!
    wait "$sp2" 2>/dev/null
    src2=$?
    kill "$wd2" 2>/dev/null
    marker2=$(grep -a "SMOKE_RESULT" "$LOGDIR/seed-display2.log" 2>/dev/null | tail -n 1 || true)
    log "seed same-server: rc=$src2 marker=${marker2:-none} (PASS_DISPLAY_KMT expected)"
    return 0
}

# CPU performance preset with save/restore (PortMaster-style). The handheld
# must not stay pinned at max clock after the game exits.
CPU_SAVE=/tmp/aw-cpu-save.$$
cpu_preset_apply() {
    : > "$CPU_SAVE" 2>/dev/null || true
    for d in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -d "$d" ] || continue
        echo "$d $(cat "$d/scaling_governor" 2>/dev/null) $(cat "$d/scaling_max_freq" 2>/dev/null)" >> "$CPU_SAVE"
        chmod a+w "$d/scaling_governor" "$d/scaling_max_freq" 2>/dev/null || true
        echo 1992000 > "$d/scaling_max_freq" 2>/dev/null || true
        echo performance > "$d/scaling_governor" 2>/dev/null || true
    done
}
cpu_preset_restore() {
    [ -f "$CPU_SAVE" ] || return 0
    while read -r d gov mx; do
        [ -d "$d" ] || continue
        chmod a+w "$d/scaling_governor" "$d/scaling_max_freq" 2>/dev/null || true
        [ -n "$mx" ] && echo "$mx" > "$d/scaling_max_freq" 2>/dev/null || true
        [ -n "$gov" ] && echo "$gov" > "$d/scaling_governor" 2>/dev/null || true
    done < "$CPU_SAVE"
    rm -f "$CPU_SAVE" 2>/dev/null || true
}
# Keep the fast swap first: zram (compressed RAM) > internal flash > SD card.
# Only re-prioritize a device that holds little data (avoid faulting pages back).
swap_priorities() {
    for spec in "/dev/zram0 200" "/mnt/UDISK/swapfile 100" "/mnt/sdcard/mmcblk1p1/cachefile 10"; do
        set -- $spec
        dev=$1; prio=$2
        [ -e "$dev" ] || continue
        line=$(awk -v d="$dev" '$1==d {print; exit}' /proc/swaps 2>/dev/null)
        [ -n "$line" ] || continue
        cur=$(echo "$line" | awk '{print $5}')
        used=$(echo "$line" | awk '{print $4}')
        [ "$cur" = "$prio" ] && continue
        [ -n "$used" ] && [ "$used" -gt 65536 ] 2>/dev/null && continue
        swapoff "$dev" 2>/dev/null || continue
        swapon -p "$prio" "$dev" 2>/dev/null || true
    done
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
    discover_xorg_runtime_paths
    if [ -n "${DISPLAY:-}" ] && display_usable "$DISPLAY"; then
        log "using inherited X display $DISPLAY"
        export SDL_VIDEODRIVER=x11
        return 0
    fi
    for d in :0 :1; do
        if display_usable "$d"; then
            DISPLAY="$d"; export DISPLAY
            export SDL_VIDEODRIVER=x11
            log "using existing X display $DISPLAY"
            return 0
        fi
    done

    XORG=""
    PRIVATE_XORG=/mnt/UDISK/xorg/usr/lib/xorg/Xorg
    if [ -x "$PRIVATE_XORG" ]; then
        XORG="$PRIVATE_XORG"
        XORG_SOURCE=totono-private
    fi
    if [ -z "$XORG" ]; then
        for x in "$(command -v Xorg 2>/dev/null || true)" /usr/bin/Xorg /usr/bin/X /usr/trimui/bin/Xorg /mnt/SDCARD/spruce/bin64/Xorg; do
            [ -n "$x" ] && [ -x "$x" ] && { XORG="$x"; XORG_SOURCE=system; break; }
        done
    fi
    [ -n "$XORG" ] || { log "ERROR no Xorg/X server found and DISPLAY is unset"; return 1; }

    # Clear only a proven stale :1 lock. Never kill an existing X server.
    if [ -f /tmp/.X1-lock ]; then
        xp=$(tr -dc '0-9' </tmp/.X1-lock 2>/dev/null || true)
        if [ -z "$xp" ] || ! kill -0 "$xp" 2>/dev/null; then
            rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
        fi
    fi

    if [ -z "$XORG_CONFIG" ]; then
        write_xorg_config
        XORG_CONFIG="$XCONF"
    fi

    log "xorg_source=$XORG_SOURCE xorg_binary=$XORG xorg_config=$XORG_CONFIG"
    log "xorg_ld_path=${XORG_LD_PATH:-<default>}"
    if [ -n "$XORG_LD_PATH" ]; then
        # Xorg must NOT inherit the port's full LD_LIBRARY_PATH: it would pick
        # spruce/flip libs built for a newer glibc (liblzma.so.5 wants
        # GLIBC_2.34, the device ships 2.31) and the server would not start.
        env LD_LIBRARY_PATH="$XORG_LD_PATH" \
            "$XORG" :1 -ac -nolisten tcp -noreset -config "$XORG_CONFIG" \
            -logfile "$LOGDIR/Xorg.1.log" >"$LOGDIR/Xorg-stdout.log" 2>&1 &
    else
        "$XORG" :1 -ac -nolisten tcp -noreset -config "$XORG_CONFIG" \
            -logfile "$LOGDIR/Xorg.1.log" >"$LOGDIR/Xorg-stdout.log" 2>&1 &
    fi
    XORG_PID=$!
    XORG_STARTED=1

    i=0
    while [ "$i" -lt 10 ]; do
        sleep 1
        if display_usable :1; then
            DISPLAY=:1; export DISPLAY
            export SDL_VIDEODRIVER=x11
            log "Xorg ready: DISPLAY=$DISPLAY pid=$XORG_PID"
            return 0
        fi
        kill -0 "$XORG_PID" 2>/dev/null || break
        i=$((i + 1))
    done

    log "ERROR Xorg did not become usable"
    tail -160 "$LOGDIR/Xorg.1.log" 2>/dev/null || true
    tail -160 "$LOGDIR/Xorg-stdout.log" 2>/dev/null || true
    return 1
}

base_overrides='winemenubuilder.exe=d;mscoree=d;mshtml=d'
# Audio-off A/B: AW_NO_AUDIO=1 disables the bundled XAudio2 (FAudio) so the
# game's audio init fails cleanly - used to isolate the FAudio mix crash
# (wild buffer pointers) from the graphics path.
if [ -n "${AW_NO_AUDIO:-}" ]; then base_overrides="$base_overrides;xaudio2_9=d;xaudio2_8=d"; fi
# Native-XAudio2 A/B: AW_XA2_NATIVE=1 prefers a user-supplied xaudio2_9.dll in
# the game directory (e.g. the other port's build) over the bundled FAudio.
if [ -n "${AW_XA2_NATIVE:-}" ]; then base_overrides="xaudio2_9=n,b;$base_overrides"; fi

prepare_smoke_backend() {
    backend=$1
    SDIR="$PFX/drive_c/aw-smoke"
    rm -f "$SDIR/d3d12_smoke.exe" "$SDIR/d3d12.dll" "$SDIR/d3d12core.dll"
    cp "$SMOKE" "$SDIR/d3d12_smoke.exe" || return 1
    case "$backend" in
        wine)
            WINEDLLOVERRIDES="d3d12=b;d3d12core=b;$base_overrides"
            VKD3D_CONFIG=virtual_heaps
            export VKD3D_CONFIG
            ;;
        vkd3d-2.6|vkd3d-3.0.1)
            unset VKD3D_CONFIG 2>/dev/null || true
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
            VKD3D_CONFIG=virtual_heaps
            export VKD3D_CONFIG
            ;;
        vkd3d-2.6|vkd3d-3.0.1)
            unset VKD3D_CONFIG 2>/dev/null || true
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
    : >"$logfile"
    rc=1
    # Harness-shaped: separate stage processes in the same (seeded) session;
    # pass/fail by the SMOKE_RESULT marker, exactly like test14-15-wsi.sh.
    for stage in factory device; do
        case "$stage" in
            factory) want=PASS_DXGI_FACTORY ;;
            device)  want=PASS_D3D12_DEVICE ;;
        esac
        (
            export VKD3D_DEBUG=info
            export VKD3D_LOG_FILE="$LOGDIR/vkd3d-$backend-$stage.log"
            run_timeout 45 "$BOX64" "$WINE" "$PFX/drive_c/aw-smoke/d3d12_smoke.exe" "$stage" >>"$logfile" 2>&1
        )
        if grep -aq "$want" "$logfile"; then rc=0; else rc=1; break; fi
    done
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
log "launcher_version=2026-09-29.15"
log "changes: box64 STRONGMEM=1+ALIGNED_ATOMICS+SAFEFLAGS+BLEEDING_EDGE=0 (bisected-safe set) + SHOWSEGV; BOX64_WINEDBG=1 (real crash handling); SCM bootstrap (services.exe, final session) for COM/RPC; bundled 1.2.131 loader pick (xlib WSI); wrapper ICD + phys-dev export; WSI_X11_FORCE_SHM; totono Xorg; display-first order; no3d renderer; harness-shaped display seed; stage-wise probes; watchdog run_timeout"
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
# box64 refuses to launch winedbg by default ("winedbg detected, not launching
# it!"), so wine's unhandled-exception handler waits forever for a debugger that
# never attaches and the process deadlocks (a crashed thread keeps holding the
# heap lock). BOX64_WINEDBG=1 lets box64 launch winedbg; the crash then produces
# a real backtrace and the process exits cleanly instead of hanging.
export BOX64_WINEDBG=1
# Memory-model hardening: OFF by default for speed. The wild-pointer crashes
# that motivated it were traced to the FAudio 26.09 out-of-bounds mix (fixed by
# the xaudio2_9 swap); with that root gone the extra atomics only cost frames.
# AW_HARDEN=1 re-enables the safe set (STRONGMEM=2/BIGBLOCK=1/CALLRET=0 were
# bisected out: each made even `wine cmd /c ver` die with SIGKILL at exit).
if [ -n "${AW_HARDEN:-}" ]; then
    export BOX64_DYNAREC_STRONGMEM=${BOX64_DYNAREC_STRONGMEM:-1}
    export BOX64_DYNAREC_ALIGNED_ATOMICS=${BOX64_DYNAREC_ALIGNED_ATOMICS:-1}
    export BOX64_DYNAREC_SAFEFLAGS=${BOX64_DYNAREC_SAFEFLAGS:-1}
    export BOX64_DYNAREC_BLEEDING_EDGE=${BOX64_DYNAREC_BLEEDING_EDGE:-0}
fi
export BOX64_SHOWSEGV=1
export BOX64_LD_LIBRARY_PATH="$RT/box64/x64lib:$RT/wine/lib:$RT/wine/lib64${BOX64_LD_LIBRARY_PATH:+:$BOX64_LD_LIBRARY_PATH}"
export XDG_CACHE_HOME="$CACHE"
export VKD3D_SHADER_CACHE_PATH="$CACHE/vkd3d"
export WINEDEBUG=${WINEDEBUG:--all}

log "--- cpu preset + swap priorities ---"
cpu_preset_apply
swap_priorities
# The display must be up BEFORE the first wine/box64 process starts: the
# win32u Vulkan driver caches its capability set (including
# VK_KHR_win32_surface) for the whole wineserver session, and without a live
# X display it initializes without it. The game then fails with
# "Failed to create vkd3d instance" (E_FAIL).
ensure_display || {
    "$ROOT/diagnose.sh" --collect-only >/dev/null 2>&1 || true
    exit 19
}
setup_vulkan_env

log "--- resetting stale wineserver (fresh session with display) ---"
"$BOX64" "$WINESERVER" -k >/dev/null 2>&1 || true
sleep 1

log "--- prefix sanity ---"
run_timeout 20 "$BOX64" "$WINE" cmd /c ver >"$LOGDIR/prefix-sanity.log" 2>&1
SANITY_RC=$?
# A non-zero rc with the version banner present means the command itself ran and
# only the exit path died (a known wine/box64 teardown crash: SIGKILL/137). Treat
# that as a pass; only a missing banner is a real failure.
if [ "$SANITY_RC" -ne 0 ] && ! grep -q "Microsoft Windows" "$LOGDIR/prefix-sanity.log" 2>/dev/null; then
    log "ERROR Wine lightweight prefix sanity failed (rc=$SANITY_RC)"
    cat "$LOGDIR/prefix-sanity.log" 2>/dev/null || true
    "$ROOT/diagnose.sh" --collect-only >/dev/null 2>&1 || true
    exit 18
fi
log "prefix sanity rc=$SANITY_RC (banner present)"
cat "$LOGDIR/prefix-sanity.log" 2>/dev/null || true

seed_display_session

if [ -x "$RT/tools/vkprobe" ]; then
    log "--- native Vulkan probe ---"
    "$RT/tools/vkprobe" >"$LOGDIR/vkprobe.log" 2>&1 || true
    cat "$LOGDIR/vkprobe.log" 2>/dev/null || true
fi

BACKEND=$(select_backend | tee "$LOGDIR/backend-selection.log" | tail -n 1)
prepare_game_backend "$BACKEND" || { log "ERROR failed to configure backend=$BACKEND"; exit 22; }

log "--- Box64 version ---"
"$BOX64" -v 2>&1 || true
log "--- Wine version ---"
"$BOX64" "$WINE" --version 2>&1 || true
# SCM bootstrap: the bundled ntdll.so runs wineboot with --help instead of
# --init (patched to dodge the wineboot wait-for-services.exe hang), so
# services.exe never starts by itself and the game's COM/RPC init fails
# ("Failed to open service manager", RPC_S_SERVER_UNAVAILABLE). Start the
# service control manager in the FINAL session - the seed stage resets the
# wineserver, so this must run after it; the template's RpcSs entry then lets
# rpcss start on demand. wineserver -k cleans it up with the session.
log "--- service control manager (COM/RPC bootstrap) ---"
"$BOX64" "$WINE" 'C:\windows\system32\services.exe' >>"$LOGDIR/services.log" 2>&1 &
SCM_OK=0
_i=0
while [ "$_i" -lt 20 ]; do
    sleep 1
    if ps | grep -q "services.exe" || ps | grep -q "svchost"; then SCM_OK=1; break; fi
    _i=$((_i + 1))
done
if [ "$SCM_OK" = 1 ]; then
    log "scm_up after ${_i}s"
else
    log "WARNING SCM not visible after 20s"
    tail -10 "$LOGDIR/services.log" 2>/dev/null || true
fi

harden_prefix_for_wine
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
