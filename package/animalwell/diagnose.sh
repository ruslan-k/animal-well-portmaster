#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RT="$ROOT/runtime"
GAME="$ROOT/game"
LOGDIR="$ROOT/logs"
PFXIMG="$ROOT/prefix.ext2"
PFXMNT="/tmp/animalwell-diagnostic-prefix"
BOX64="$RT/box64/box64"
WINE="$RT/wine/bin/wine"
WINESERVER="$RT/wine/bin/wineserver"
MODE=${1:---collect-only}
FAIL_RC=${2:-unknown}
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
OUT="$LOGDIR/diag-$STAMP"
mkdir -p "$OUT" "$LOGDIR"
PREFIX_MOUNTED=0

root_run() {
    if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && command -v sudo >/dev/null 2>&1; then sudo "$@"; else "$@"; fi
}
run() {
    name=$1; shift
    { echo "# $*"; "$@"; rc=$?; echo "exit_code=$rc"; return "$rc"; } >"$OUT/$name.log" 2>&1
}
run_timeout() {
    name=$1; seconds=$2; shift 2
    if command -v timeout >/dev/null 2>&1; then run "$name" timeout "$seconds" "$@"; else echo "timeout command unavailable; skipped: $*" >"$OUT/$name.log"; return 125; fi
}
mount_prefix() {
    [ -f "$PFXIMG" ] || return 1
    mkdir -p "$PFXMNT"
    if grep -qs " $PFXMNT " /proc/mounts 2>/dev/null; then root_run umount "$PFXMNT" >/dev/null 2>&1 || true; fi
    root_run mount -t ext2 -o loop,rw,noatime "$PFXIMG" "$PFXMNT" >/dev/null 2>&1 || \
    root_run mount -t ext4 -o loop,rw,noatime "$PFXIMG" "$PFXMNT" >/dev/null 2>&1 || \
    root_run mount -o loop,rw,noatime "$PFXIMG" "$PFXMNT" >/dev/null 2>&1 || return 1
    PREFIX_MOUNTED=1
    [ -f "$PFXMNT/system.reg" ]
}
cleanup() {
    if [ "$PREFIX_MOUNTED" = 1 ]; then
        if [ -x "$BOX64" ] && [ -x "$WINESERVER" ]; then "$BOX64" "$WINESERVER" -k >/dev/null 2>&1 || true; sleep 1; fi
        sync 2>/dev/null || true
        root_run umount "$PFXMNT" >/dev/null 2>&1 || root_run umount -l "$PFXMNT" >/dev/null 2>&1 || true
    fi
    rmdir "$PFXMNT" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

{
    echo "diagnostic_schema=animalwell-tsps-v2"
    echo "timestamp=$STAMP"
    echo "mode=$MODE"
    echo "launcher_failure_rc=$FAIL_RC"
    echo "backend=$(tr -d '\r\n ' < "$ROOT/backend" 2>/dev/null || echo wine)"
    echo "DISPLAY=${DISPLAY:-}"
    echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
    echo "HOME=${HOME:-}"
    echo "PATH=$PATH"
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
    uname -a 2>/dev/null || true
    echo "--- /etc/os-release ---"; cat /etc/os-release 2>/dev/null || true
    echo "--- mounts ---"; cat /proc/mounts 2>/dev/null || true
    echo "--- filesystems ---"; cat /proc/filesystems 2>/dev/null || true
    echo "--- memory ---"; cat /proc/meminfo 2>/dev/null || true
    echo "--- cpu ---"; cat /proc/cpuinfo 2>/dev/null || true
    echo "--- limits ---"; ulimit -a 2>/dev/null || true
    echo "--- dri ---"; ls -la /dev/dri 2>/dev/null || true
    echo "--- loop ---"; ls -la /dev/loop* /dev/loop-control 2>/dev/null || true
    echo "--- prefix image ---"; ls -lh "$PFXIMG" 2>/dev/null || true
    echo "--- disk ---"; df -h "$ROOT" /tmp 2>/dev/null || true
} >"$OUT/system.log" 2>&1

[ -f "$ROOT/log.txt" ] && cp "$ROOT/log.txt" "$OUT/launcher-log.txt" 2>/dev/null || true
[ -f "$ROOT/log.prev.txt" ] && cp "$ROOT/log.prev.txt" "$OUT/launcher-log-prev.txt" 2>/dev/null || true

if command -v ldd >/dev/null 2>&1; then run glibc ldd --version || true; fi
if command -v file >/dev/null 2>&1; then run binaries file "$BOX64" "$WINE" "$RT/tools/vkprobe" "$RT/tools/d3d12_smoke.exe" || true; fi
if command -v vulkaninfo >/dev/null 2>&1; then run_timeout vulkaninfo 20 vulkaninfo --summary || true; fi
[ -x "$RT/tools/vkprobe" ] && run vkprobe "$RT/tools/vkprobe" || true
[ -x "$BOX64" ] && run box64 "$BOX64" -v || true

{
    find /etc /usr /lib /mnt/SDCARD -maxdepth 6 -type f \( -name '*icd*.json' -o -name 'libvulkan.so*' -o -name 'libmali.so*' \) 2>/dev/null | head -300
} >"$OUT/vulkan-files.log" 2>&1

if command -v dmesg >/dev/null 2>&1; then dmesg 2>/dev/null | tail -300 >"$OUT/dmesg-tail.log" || true; fi
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$GAME/Animal Well.exe" "$GAME/steam_api64.dll" >"$OUT/game-sha256.txt" 2>/dev/null || true; fi

if mount_prefix; then
    export WINEPREFIX="$PFXMNT" WINEARCH=win64 WINEESYNC=0 WINEFSYNC=0
    export BOX64_NOBANNER=1 BOX64_DYNAREC=1 BOX64_DYNACACHE=1 BOX64_LOG=1
    export BOX64_LD_LIBRARY_PATH="$RT/box64/x64lib:$RT/wine/lib:$RT/wine/lib64${BOX64_LD_LIBRARY_PATH:+:$BOX64_LD_LIBRARY_PATH}"
    export XDG_CACHE_HOME="$ROOT/cache" VKD3D_SHADER_CACHE_PATH="$ROOT/cache/vkd3d"
    if [ -x "$BOX64" ] && [ -x "$WINE" ]; then
        run_timeout wine-version 15 "$BOX64" "$WINE" --version || true
        for b in wine vkd3d-2.6 vkd3d-3.0.1; do
            SYS="$WINEPREFIX/drive_c/windows/system32"; mkdir -p "$SYS"
            SRC="$RT/backends/$b/x64"; [ -f "$SRC/d3d12.dll" ] || continue
            rm -f "$SYS/d3d12.dll" "$SYS/d3d12core.dll"
            cp "$SRC/d3d12.dll" "$SYS/d3d12.dll"
            [ ! -f "$SRC/d3d12core.dll" ] || cp "$SRC/d3d12core.dll" "$SYS/d3d12core.dll"
            O="winemenubuilder.exe=d;mscoree=d;mshtml=d"
            if [ "$b" != wine ]; then O="d3d12=n,b;d3d12core=n,b;$O"; fi
            export WINEDLLOVERRIDES="$O" WINEDEBUG=-all VKD3D_DEBUG=info
            run_timeout "d3d12-$b" 20 "$BOX64" "$WINE" "$RT/tools/d3d12_smoke.exe" || true
        done
        if [ "$MODE" = "--full" ] && [ -f "$GAME/Animal Well.exe" ]; then
            export WINEDEBUG=+timestamp,+seh,+loaddll VKD3D_DEBUG=info
            run_timeout game-loader 20 "$BOX64" "$WINE" "$GAME/Animal Well.exe" || true
        fi
    fi
else
    echo "prefix image could not be mounted" >"$OUT/prefix-mount-failed.log"
fi

cleanup
PREFIX_MOUNTED=0
trap - EXIT HUP INT TERM 2>/dev/null || true

BUNDLE="$LOGDIR/diagnostics-$STAMP.tar.gz"
if command -v tar >/dev/null 2>&1; then
    if tar -czf "$BUNDLE" -C "$LOGDIR" "diag-$STAMP" 2>/dev/null; then
        echo "$BUNDLE"
        exit 0
    fi
fi
echo "$OUT"
exit 0
