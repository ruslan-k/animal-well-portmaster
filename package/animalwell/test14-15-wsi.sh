#!/bin/sh
# ANIMAL WELL TSPS test14/test15 field harness.
# test14: native ARM64 Vulkan Xlib/SHM swapchain through Mali WSI wrapper.
# test15: Wine DXGI/D3D12 smoke through the same wrapper. Never launches the game.
set -u

MODE=${1:-test14}
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT="$SELF"
RT="$ROOT/runtime"
T14="$RT/test14"
LOGDIR="$ROOT/logs"
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
LOG="$LOGDIR/${MODE}-$STAMP.log"
XCONF="/tmp/animalwell-test14-xorg.conf"
XORG_PID=""
XORG_STARTED=0
XORG_SOURCE=""
XORG_CONFIG=""
XORG_LD_PATH=""
MALIDIR="/tmp/animalwell-mali-driver"
ICD="/tmp/animalwell-mali-wrapper-$$.json"
PFX="/tmp/animalwell-test15-prefix"
BOX64="$RT/box64/box64"
BOX64_MAIN="$RT/box64/box64-test15-main"
WINE="$RT/wine/bin/wine"
WINESERVER="$RT/wine/bin/wineserver"

mkdir -p "$LOGDIR" "$MALIDIR"
exec >>"$LOG" 2>&1

stamp() { date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || date; }
log() { echo "[$(stamp)] $*"; }
mem() {
    echo "MemAvailable_kB=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo unknown)"
    echo "SwapFree_kB=$(awk '/SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo unknown)"
    echo "CmaFree_kB=$(awk '/CmaFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo unknown)"
}
cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM 2>/dev/null || true
    if [ -x "$BOX64" ] && [ -x "$WINESERVER" ]; then "$BOX64" "$WINESERVER" -k >/dev/null 2>&1 || true; fi
    rm -rf "$PFX" "$MALIDIR" 2>/dev/null || true
    rm -f "$ICD" "$XCONF" 2>/dev/null || true
    if [ "$XORG_STARTED" = 1 ] && [ -n "$XORG_PID" ]; then
        kill "$XORG_PID" >/dev/null 2>&1 || true
        wait "$XORG_PID" >/dev/null 2>&1 || true
    fi
    log "exit_code=$rc"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_timeout() {
    sec=$1; shift
    if command -v timeout >/dev/null 2>&1; then timeout -k 5 "$sec" "$@"; else "$@"; fi
}

display_usable() {
    d=$1; n=${d#:}; n=${n%%.*}
    [ -S "/tmp/.X11-unix/X$n" ] || return 1
    if command -v xdpyinfo >/dev/null 2>&1; then DISPLAY="$d" xdpyinfo >/dev/null 2>&1 || return 1; fi
    return 0
}
write_xorg_config() {
cat >"$XCONF" <<'EOF'
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
EOF
}
discover_xorg_runtime_paths() {
    # Populate Xorg/Totono runtime library roots even when DISPLAY already exists.
    # Wine winex11.so needs these too; older harnesses only gave them to the Xorg process.
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

ensure_display() {
    discover_xorg_runtime_paths
    if [ -n "${DISPLAY:-}" ] && display_usable "$DISPLAY"; then
        log "using inherited DISPLAY=$DISPLAY"
        export SDL_VIDEODRIVER=x11
        return 0
    fi
    for d in :0 :1; do
        if display_usable "$d"; then
            DISPLAY="$d"; export DISPLAY
            export SDL_VIDEODRIVER=x11
            log "using existing DISPLAY=$DISPLAY"
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

    if [ -z "$XORG" ]; then
        log "ERROR no Xorg found"
        log "checked_private=$PRIVATE_XORG"
        log "checked_system=PATH,/usr/bin,/usr/trimui/bin,/mnt/SDCARD/spruce/bin64"
        ls -ld /mnt/UDISK/xorg /mnt/UDISK/xorg/usr/lib/xorg /mnt/UDISK/xorg-libs 2>/dev/null || true
        return 1
    fi

    if [ -f /tmp/.X1-lock ]; then
        xp=$(tr -dc '0-9' </tmp/.X1-lock 2>/dev/null || true)
        if [ -z "$xp" ] || ! kill -0 "$xp" 2>/dev/null; then rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true; fi
    fi

    if [ -z "$XORG_CONFIG" ]; then
        write_xorg_config
        XORG_CONFIG="$XCONF"
    fi

    log "xorg_source=$XORG_SOURCE"
    log "xorg_binary=$XORG"
    log "xorg_config=$XORG_CONFIG"
    log "xorg_ld_path=${XORG_LD_PATH:-<default>}"

    if [ -n "$XORG_LD_PATH" ]; then
        env LD_LIBRARY_PATH="$XORG_LD_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
            "$XORG" :1 -ac -nolisten tcp -noreset -config "$XORG_CONFIG" \
            -logfile "$LOGDIR/Xorg.test14.log" >"$LOGDIR/Xorg.test14.stdout.log" 2>&1 &
    else
        "$XORG" :1 -ac -nolisten tcp -noreset -config "$XORG_CONFIG" \
            -logfile "$LOGDIR/Xorg.test14.log" >"$LOGDIR/Xorg.test14.stdout.log" 2>&1 &
    fi
    XORG_PID=$!; XORG_STARTED=1

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
        i=$((i+1))
    done

    log "ERROR Xorg failed"
    tail -160 "$LOGDIR/Xorg.test14.log" 2>/dev/null || true
    tail -160 "$LOGDIR/Xorg.test14.stdout.log" 2>/dev/null || true
    return 1
}

find_mali() {
    for f in /usr/lib/libmali.so.0 /usr/lib/libmali.so /usr/trimui/lib/libmali.so.0 /usr/trimui/lib/libmali.so /lib/libmali.so.0 /lib/libmali.so; do
        [ -e "$f" ] && { readlink -f "$f" 2>/dev/null || echo "$f"; return 0; }
    done
    find /usr/lib /usr/trimui/lib /lib /mnt/SDCARD/spruce -maxdepth 4 -type f -name 'libmali.so*' 2>/dev/null | head -1
}
setup_wrapper() {
    [ -x "$T14/vk_wsi_xlib_probe" ] || { log "ERROR missing $T14/vk_wsi_xlib_probe"; return 1; }
    [ -f "$T14/lib/libmali_wrapper.so" ] || { log "ERROR missing wrapper"; return 1; }
    mali=$(find_mali)
    [ -n "$mali" ] && [ -e "$mali" ] || { log "ERROR real libmali not found"; return 1; }
    ln -sf "$mali" "$MALIDIR/libmali.so.0"
    ln -sf "$mali" "$MALIDIR/libmali.so"
    cat >"$ICD" <<EOF
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "$T14/lib/libmali_wrapper.so",
    "api_version": "1.3.276"
  }
}
EOF
    export VK_ICD_FILENAMES="$ICD"
    export WSI_X11_FORCE_SHM=1
    export MALI_WRAPPER_LOG_LEVEL=3
    export MALI_WRAPPER_LOG_CATEGORY=wrapper+wsi+low-address-map
    export MALI_WRAPPER_LOG_COLORS=0
    export LD_LIBRARY_PATH="$T14/deps:$T14/lib:$MALIDIR${XORG_LD_PATH:+:$XORG_LD_PATH}:/mnt/SDCARD/Persistent/portmaster/lib:/mnt/SDCARD/spruce/flip/lib:/usr/trimui/lib:/usr/lib:/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    log "real_mali=$mali"
    log "VK_ICD_FILENAMES=$VK_ICD_FILENAMES"
    log "WSI_X11_FORCE_SHM=$WSI_X11_FORCE_SHM"
    log "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
}

setup_prefix() {
    T="$ROOT/prefix-template"
    [ -f "$T/system.reg" ] || { log "ERROR missing prefix template"; return 1; }
    rm -rf "$PFX"
    mkdir -p "$PFX/dosdevices" "$PFX/drive_c/windows" "$PFX/drive_c/users" "$PFX/drive_c/Program Files" "$PFX/drive_c/Program Files (x86)" "$PFX/drive_c/ProgramData" "$PFX/drive_c/windows/temp" "$PFX/drive_c/aw-smoke" "$ROOT/wine-user/root"
    cp "$T/system.reg" "$PFX/system.reg"; cp "$T/user.reg" "$PFX/user.reg"; cp "$T/userdef.reg" "$PFX/userdef.reg"
    [ ! -f "$T/.update-timestamp" ] || cp "$T/.update-timestamp" "$PFX/.update-timestamp"
    ln -s ../drive_c "$PFX/dosdevices/c:"; ln -s / "$PFX/dosdevices/z:"
    ln -s "$RT/wine/lib/wine/x86_64-windows" "$PFX/drive_c/windows/system32"
    ln -s "$RT/wine/lib/wine/i386-windows" "$PFX/drive_c/windows/syswow64"
    ln -s "$ROOT/wine-user/root" "$PFX/drive_c/users/root"
    cp "$RT/tools/d3d12_smoke.exe" "$PFX/drive_c/aw-smoke/d3d12_smoke.exe"
}

log "=== ANIMAL WELL ${MODE} ==="
log "harness_version=2026-09-28.18"
log "uname=$(uname -a 2>/dev/null || true)"
mem
ensure_display || exit 20
setup_wrapper || exit 21

log "--- wrapper identity/path check ---"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$T14/lib/libmali_wrapper.so" 2>/dev/null || true
fi
if strings "$T14/lib/libmali_wrapper.so" 2>/dev/null | grep -Fq 'WSI_X11_FORCE_SHM: skipping unused wsialloc/DMA-BUF allocator initialization.'; then
    log "wrapper_shm_bypass_marker=present"
else
    log "ERROR wrapper_shm_bypass_marker=missing (stale wrapper binary)"
    exit 22
fi
strings "$T14/lib/libmali_wrapper.so" 2>/dev/null | grep -E 'libmali\.so|Mali Wrapper|WSI_X11_FORCE_SHM' | head -40 || true

if [ "$MODE" = test14 ]; then
    log "--- native Xlib WSI/swapchain probe ---"
    set +e
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5 30 env \
            WSI_X11_FORCE_SHM=1 \
            VK_ICD_FILENAMES="$VK_ICD_FILENAMES" \
            LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
            "$T14/vk_wsi_xlib_probe"
    else
        env \
            WSI_X11_FORCE_SHM=1 \
            VK_ICD_FILENAMES="$VK_ICD_FILENAMES" \
            LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
            "$T14/vk_wsi_xlib_probe"
    fi
    rc=$?
    set -e 2>/dev/null || true
    mem
    if [ "$rc" -eq 0 ]; then log "TEST14_RESULT=PASS_XLIB_SWAPCHAIN"; else log "TEST14_RESULT=FAIL rc=$rc"; fi
    exit "$rc"
fi

[ "$MODE" = test15 ] || { log "usage: $0 [test14|test15]"; exit 2; }
[ -x "$BOX64" ] && [ -x "$WINE" ] || { log "ERROR full Box64/Wine runtime missing"; exit 30; }
[ -f "$RT/tools/d3d12_smoke.exe" ] || { log "ERROR d3d12 smoke missing"; exit 31; }
setup_prefix || exit 32

export WINEPREFIX="$PFX" WINEARCH=win64 WINEESYNC=0 WINEFSYNC=0
export BOX64_NOBANNER=1 BOX64_DYNAREC=1 BOX64_DYNACACHE=1 BOX64_LOG=1
export BOX64_LD_LIBRARY_PATH="$RT/box64/x64lib:$RT/wine/lib:$RT/wine/lib64${BOX64_LD_LIBRARY_PATH:+:$BOX64_LD_LIBRARY_PATH}"
export XDG_CACHE_HOME="$ROOT/cache" VKD3D_SHADER_CACHE_PATH="$ROOT/cache/vkd3d"
export WINEDLLOVERRIDES='d3d12=b;d3d12core=b;winemenubuilder.exe=d;mscoree=d;mshtml=d'
export WINE_D3D_CONFIG=renderer=no3d
export VKD3D_CONFIG=virtual_heaps
export VKD3D_DEBUG=info
export VKD3D_LOG_FILE="$LOGDIR/test15-vkd3d-$STAMP.log"
export WINEDEBUG=+timestamp,+dxgi,+d3d,+wined3d,+vulkan,+x11drv,+xrandr,+system,+d3dkmt,+wgl

WIN32U="$RT/wine/lib/wine/x86_64-unix/win32u.so"
WIN32U_D3DKMT_PATCH_SHA=ae33290fb4eec697dc93ea0302b2a878eab30db10e4642313e65723f270c2c2b
if [ -f "$WIN32U" ]; then
    win32u_sha=$(sha256sum "$WIN32U" | awk '{print $1}')
    log "win32u_sha256=$win32u_sha"
    if [ "$win32u_sha" = "$WIN32U_D3DKMT_PATCH_SHA" ]; then
        log "win32u_d3dkmt_novulkan_patch=present"
    else
        log "ERROR win32u_d3dkmt_novulkan_patch=missing expected=$WIN32U_D3DKMT_PATCH_SHA"
        exit 34
    fi
else
    log "ERROR win32u missing: $WIN32U"
    exit 34
fi

# Isolate the x86-64 -> Box64 -> native Vulkan bridge before spending time
# on Wine display seeding. The .16 field run proved that the wrapper crashes
# inside libstdc++ std::ostream::sentry while its C++ logger is active.
# Disable wrapper logging before entering the host Vulkan path so Logger::Log()
# returns before any stringstream/std::cout operation.
VKEXT="$RT/tools/vulkan_ext_probe_x64"
LAST_VKEXT_PASS=0
run_vkext_stage() {
    label=$1
    mode=$2
    limit=$3
    no_overlay=${4:-0}
    log_category=${5:-off}
    stage_log="$LOGDIR/test15-vkext-$label-$STAMP.stage.log"
    LAST_VKEXT_PASS=0
    log "--- vkext_label=$label mode=$mode no_overlay=$no_overlay wrapper_log_category=$log_category watchdog=${limit}s ---"
    rm -f "$stage_log" 2>/dev/null || true
    set +e
    run_timeout "$limit" env \
        BOX64_LOG=1 \
        BOX64_NOVULKANOVERLAY="$no_overlay" \
        MALI_WRAPPER_LOG_CATEGORY="$log_category" \
        "$BOX64" "$VKEXT" "$mode" >"$stage_log" 2>&1
    rc=$?
    set -e 2>/dev/null || true
    cat "$stage_log" 2>/dev/null || true
    if grep -Fq 'VKEXT_RESULT=PASS' "$stage_log" 2>/dev/null; then
        LAST_VKEXT_PASS=1
        semantic=PASS
    else
        semantic=FAIL
    fi
    log "VKEXT_STAGE_RESULT label=$label mode=$mode no_overlay=$no_overlay wrapper_log_category=$log_category rc=$rc semantic=$semantic"
    return 0
}

run_vkext_matrix() {
    matrix_name=$1
    no_overlay=$2
    log_category=$3
    vkext_direct_count_pass=0
    vkext_direct_fill_pass=0
    vkext_gipa_count_pass=0
    vkext_gipa_fill_pass=0

    run_vkext_stage "$matrix_name-direct-count" direct-count 10 "$no_overlay" "$log_category"
    vkext_direct_count_pass=$LAST_VKEXT_PASS
    run_vkext_stage "$matrix_name-direct-fill" direct-fill 10 "$no_overlay" "$log_category"
    vkext_direct_fill_pass=$LAST_VKEXT_PASS
    run_vkext_stage "$matrix_name-gipa-count" gipa-count 10 "$no_overlay" "$log_category"
    vkext_gipa_count_pass=$LAST_VKEXT_PASS
    run_vkext_stage "$matrix_name-gipa-fill" gipa-fill 10 "$no_overlay" "$log_category"
    vkext_gipa_fill_pass=$LAST_VKEXT_PASS
    log "VKEXT_MATRIX name=$matrix_name no_overlay=$no_overlay wrapper_log_category=$log_category direct_count=$vkext_direct_count_pass direct_fill=$vkext_direct_fill_pass gipa_count=$vkext_gipa_count_pass gipa_fill=$vkext_gipa_fill_pass"

    [ "$vkext_direct_count_pass" -eq 1 ] && [ "$vkext_direct_fill_pass" -eq 1 ] && \
    [ "$vkext_gipa_count_pass" -eq 1 ] && [ "$vkext_gipa_fill_pass" -eq 1 ]
}

if [ -x "$VKEXT" ]; then
    log "--- Box64/native Vulkan extension bridge matrix (wrapper logging disabled) ---"
    if run_vkext_matrix logoff 0 off; then
        export MALI_WRAPPER_LOG_CATEGORY=off
        log "BOX64_VULKAN_BRIDGE_RESULT=PASS_WRAPPER_LOGOFF"
        log "MALI_WRAPPER_WORKAROUND=MALI_WRAPPER_LOG_CATEGORY=off"
    else
        log "BOX64_VULKAN_BRIDGE_LOGOFF=FAIL; retrying with BOX64_NOVULKANOVERLAY=1"
        if run_vkext_matrix logoff-no-overlay 1 off; then
            export MALI_WRAPPER_LOG_CATEGORY=off
            export BOX64_NOVULKANOVERLAY=1
            log "BOX64_VULKAN_BRIDGE_RESULT=PASS_WRAPPER_LOGOFF_NOVULKANOVERLAY"
            log "MALI_WRAPPER_WORKAROUND=MALI_WRAPPER_LOG_CATEGORY=off"
            log "BOX64_VULKAN_WORKAROUND=BOX64_NOVULKANOVERLAY=1"
        else
            log "BOX64_VULKAN_BRIDGE_RESULT=FAIL_WITH_WRAPPER_LOGOFF"
            log "TEST15_RESULT=BOX64_VULKAN_BRIDGE_BLOCKER"
            exit 0
        fi
    fi
else
    log "ERROR missing x64 Vulkan bridge probe: $VKEXT"
    exit 35
fi

# The .17 field run proved extension enumeration is healthy with wrapper logging off,
# but Wine now faults at the host vkCreateInstance Unix call. Reproduce that boundary
# directly through Box64, outside Wine, using both a minimal create-info and the same
# five host extensions selected by WineVulkan.
LAST_VKCREATE_PASS=0
run_vkcreate_stage() {
    label=$1
    mode=$2
    stage_log="$LOGDIR/test15-vkcreate-$label-$STAMP.stage.log"
    LAST_VKCREATE_PASS=0
    log "--- vkcreate_label=$label mode=$mode wrapper_log_category=off watchdog=12s ---"
    rm -f "$stage_log" 2>/dev/null || true
    set +e
    run_timeout 12 env \
        BOX64_LOG=2 \
        MALI_WRAPPER_LOG_CATEGORY=off \
        "$BOX64" "$VKEXT" "$mode" >"$stage_log" 2>&1
    rc=$?
    set -e 2>/dev/null || true
    cat "$stage_log" 2>/dev/null || true
    if grep -Fq 'VKCREATE_RESULT=PASS' "$stage_log" 2>/dev/null; then
        LAST_VKCREATE_PASS=1
        semantic=PASS
    else
        semantic=FAIL
    fi
    log "VKCREATE_STAGE_RESULT label=$label mode=$mode rc=$rc semantic=$semantic"
    return 0
}

vkcreate_min_direct=0
vkcreate_min_gipa=0
vkcreate_wine5_direct=0
vkcreate_wine5_gipa=0
run_vkcreate_stage min-direct create-min-direct
vkcreate_min_direct=$LAST_VKCREATE_PASS
run_vkcreate_stage min-gipa create-min-gipa
vkcreate_min_gipa=$LAST_VKCREATE_PASS
run_vkcreate_stage wine5-direct create-wine5-direct
vkcreate_wine5_direct=$LAST_VKCREATE_PASS
run_vkcreate_stage wine5-gipa create-wine5-gipa
vkcreate_wine5_gipa=$LAST_VKCREATE_PASS
log "VKCREATE_MATRIX min_direct=$vkcreate_min_direct min_gipa=$vkcreate_min_gipa wine5_direct=$vkcreate_wine5_direct wine5_gipa=$vkcreate_wine5_gipa"

if [ "$vkcreate_wine5_direct" -eq 1 ] || [ "$vkcreate_wine5_gipa" -eq 1 ]; then
    log "BOX64_VULKAN_CREATE_RESULT=PASS_WINE5"
    log "NOTE direct Box64 host vkCreateInstance works; any later Wine fault is above the raw Box64/Mali create boundary"
elif [ "$vkcreate_min_direct" -eq 1 ] || [ "$vkcreate_min_gipa" -eq 1 ]; then
    log "BOX64_VULKAN_CREATE_RESULT=PASS_MINIMAL_FAIL_WINE5"
    log "TEST15_RESULT=VKCREATE_WINE5_EXTENSION_BLOCKER"
    exit 0
else
    log "BOX64_VULKAN_CREATE_RESULT=FAIL_MINIMAL"
    log "TEST15_RESULT=BOX64_VULKAN_CREATE_BLOCKER"
    exit 0
fi
log "--- prefix sanity ---"
prefix_ok=0
attempt=1
while [ "$attempt" -le 2 ]; do
    log "prefix_sanity_attempt=$attempt"
    set +e
    run_timeout 20 "$BOX64" "$WINE" cmd /c ver
    prefix_rc=$?
    set -e 2>/dev/null || true
    log "prefix_sanity_rc=$prefix_rc"
    if [ "$prefix_rc" -eq 0 ]; then
        prefix_ok=1
        break
    fi
    attempt=$((attempt+1))
    sleep 1
done
if [ "$prefix_ok" -ne 1 ]; then
    log "WARN prefix sanity did not exit cleanly; continuing diagnostics because template prefix is present"
fi
"$BOX64" "$WINESERVER" -k >/dev/null 2>&1 || true
sleep 1
mem

log "--- Wine display/KMT + virtual-desktop diagnostics ---"
log "MALI_WRAPPER_LOG_LEVEL=$MALI_WRAPPER_LOG_LEVEL"
log "MALI_WRAPPER_LOG_CATEGORY=$MALI_WRAPPER_LOG_CATEGORY"
log "xorg_runtime_ld_path=${XORG_LD_PATH:-<none>}"
log "NOTE native EnumDisplayDevicesW previously returned zero sources"
log "NOTE vdesktop-* modes create a 1280x720 Wine virtual desktop inside the probe"
log "NOTE Wine source forces update_display_cache(TRUE) for DF_WINE_VIRTUAL_DESKTOP"

LAST_STAGE_PASS=0
run_smoke_stage() {
    label=$1
    stage=$2
    limit=$3
    renderer=$4
    expected=$5
    keep_server=${6:-0}
    stage_log="$LOGDIR/test15-${label}-$STAMP.stage.log"
    LAST_STAGE_PASS=0

    log "--- smoke_label=$label stage=$stage renderer=$renderer watchdog=${limit}s ---"
    rm -f "$stage_log" 2>/dev/null || true

    set +e
    env WINE_D3D_CONFIG="renderer=$renderer" \
        "$BOX64" "$WINE" "$PFX/drive_c/aw-smoke/d3d12_smoke.exe" "$stage" >"$stage_log" 2>&1 &
    smoke_pid=$!
    (
        sleep "$limit"
        if kill -0 "$smoke_pid" 2>/dev/null; then
            log "SMOKE_WATCHDOG_FIRED label=$label stage=$stage renderer=$renderer pid=$smoke_pid"
            kill -TERM "$smoke_pid" >/dev/null 2>&1 || true
            sleep 1
            kill -KILL "$smoke_pid" >/dev/null 2>&1 || true
        fi
    ) &
    watchdog_pid=$!

    wait "$smoke_pid"
    rc=$?
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
    set -e 2>/dev/null || true

    cat "$stage_log" 2>/dev/null || true
    if grep -Fq "$expected" "$stage_log" 2>/dev/null; then
        LAST_STAGE_PASS=1
        semantic=PASS
    else
        semantic=FAIL
    fi
    log "SMOKE_STAGE_RESULT label=$label stage=$stage renderer=$renderer rc=$rc semantic=$semantic expected=$expected"

    if [ "$keep_server" -eq 1 ]; then
        log "WINESESSION_KEEP_SERVER label=$label"
    else
        "$BOX64" "$WINESERVER" -k >/dev/null 2>&1 || true
        sleep 1
    fi
    mem
    return 0
}

# Baseline with the real Mali wrapper.
run_smoke_stage display-real-before display-kmt 12 no3d STAGE_ENUM_DISPLAY_PASS
display_real_before_pass=$LAST_STAGE_PASS

# Seed the display registry with GPU discovery disabled. The previous physical
# run proved this path reaches \\.\DISPLAY1 + both D3DKMT opens in ~79s.
REAL_VK_ICD_FILENAMES="$VK_ICD_FILENAMES"
REAL_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
REAL_WINEDEBUG="$WINEDEBUG"
NO_VULKAN_ICD="/tmp/animalwell-no-vulkan-icd-does-not-exist.json"
NO_GL_DIR="/tmp/animalwell-no-opengl"
rm -rf "$NO_GL_DIR"
mkdir -p "$NO_GL_DIR"
: >"$NO_GL_DIR/libEGL.so.1"
: >"$NO_GL_DIR/libGL.so.1"

export VK_ICD_FILENAMES="$NO_VULKAN_ICD"
export LD_LIBRARY_PATH="$NO_GL_DIR:$REAL_LD_LIBRARY_PATH"
export WINEDEBUG=-all
log "--- DISPLAY_SEED_KEEP_WINESERVER begin ---"
log "NOTE successful seed will intentionally keep the same wineserver alive"

seed_start=$(date +%s 2>/dev/null || echo 0)
run_smoke_stage display-seed-keep-server display-kmt 120 no3d SMOKE_RESULT=PASS_DISPLAY_KMT 1
display_seed_pass=$LAST_STAGE_PASS
seed_end=$(date +%s 2>/dev/null || echo 0)
log "DISPLAY_SEED_NATIVE elapsed_s=$((seed_end-seed_start)) pass=$display_seed_pass"

# Restore the real GPU environment but DO NOT restart wineserver. A fresh Wine
# client should first consume the display registry/monitor serial from the live
# server; if that succeeds it should not need another GPU-discovery refresh.
export WINEDEBUG="$REAL_WINEDEBUG"
export VK_ICD_FILENAMES="$REAL_VK_ICD_FILENAMES"
export LD_LIBRARY_PATH="$REAL_LD_LIBRARY_PATH"
rm -rf "$NO_GL_DIR"

display_same_server_pass=0
if [ "$display_seed_pass" -eq 1 ]; then
    log "--- DISPLAY_REAL_SAME_WINESERVER begin ---"
    run_smoke_stage display-real-same-server display-kmt 20 no3d SMOKE_RESULT=PASS_DISPLAY_KMT 1
    display_same_server_pass=$LAST_STAGE_PASS
else
    log "SKIP same-server real-GPU test because seed did not pass"
fi
log "DISPLAY_SEED_RESULT before=$display_real_before_pass seed=$display_seed_pass same_server=$display_same_server_pass"

if [ "$display_same_server_pass" -eq 1 ]; then
    # Keep the seeded wineserver alive across the DXGI/D3D12 matrix as well.
    run_smoke_stage factory-same-server-no3d factory 30 no3d SMOKE_RESULT=PASS_DXGI_FACTORY 1
    factory_no3d_pass=$LAST_STAGE_PASS

    if [ "$factory_no3d_pass" -eq 1 ]; then
        run_smoke_stage device-same-server-no3d device 45 no3d SMOKE_RESULT=PASS_D3D12_DEVICE 1
        device_no3d_pass=$LAST_STAGE_PASS
    else
        device_no3d_pass=0
    fi

    if [ "$factory_no3d_pass" -ne 1 ]; then
        run_smoke_stage factory-same-server-gl factory 35 gl SMOKE_RESULT=PASS_DXGI_FACTORY 1
        factory_gl_pass=$LAST_STAGE_PASS
        if [ "$factory_gl_pass" -eq 1 ]; then
            run_smoke_stage device-same-server-gl device 45 gl SMOKE_RESULT=PASS_D3D12_DEVICE 1
        fi
    fi

    log "SAME_SERVER_DXGI_RESULT factory_no3d=$factory_no3d_pass device_no3d=$device_no3d_pass"
else
    log "SKIP same-server DXGI/D3D12 because display topology was not reusable"
fi

# Final cleanup only after all same-session probes are complete.
"$BOX64" "$WINESERVER" -k >/dev/null 2>&1 || true
sleep 1
mem

log "TEST15_RESULT=DIAGNOSTIC_COMPLETE"
exit 0
