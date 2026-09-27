#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RT="$ROOT/runtime"
GAME="$ROOT/game"
LOGDIR="$ROOT/logs"
PFXTPL="$ROOT/prefix-template"
PFX="/tmp/animalwell-wineprefix"
PERSIST_USER="$ROOT/wine-user/root"
BOX64="$RT/box64/box64"
WINE="$RT/wine/bin/wine"
MODE=${1:---collect-only}
FAIL_RC=${2:-unknown}
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
OUT="$LOGDIR/diag-$STAMP"
mkdir -p "$OUT" "$LOGDIR" "$PERSIST_USER"

run() {
    name=$1; shift
    { echo "# $*"; "$@"; rc=$?; echo "exit_code=$rc"; return "$rc"; } >"$OUT/$name.log" 2>&1
}
run_timeout() {
    name=$1; seconds=$2; shift 2
    if command -v timeout >/dev/null 2>&1; then run "$name" timeout "$seconds" "$@"; else run "$name" "$@"; fi
}
setup_prefix() {
    [ -f "$PFXTPL/system.reg" ] || return 1
    if [ -f "$PFX/system.reg" ] && [ -f "$PFX/drive_c/windows/system32/kernel32.dll" ]; then return 0; fi
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
}
base_overrides='winemenubuilder.exe=d;mscoree=d;mshtml=d'
prepare_smoke() {
    b=$1
    SDIR="$PFX/drive_c/aw-smoke"
    rm -f "$SDIR/d3d12_smoke.exe" "$SDIR/d3d12.dll" "$SDIR/d3d12core.dll"
    cp "$RT/tools/d3d12_smoke.exe" "$SDIR/d3d12_smoke.exe" || return 1
    case "$b" in
        wine) O="d3d12=b;d3d12core=b;$base_overrides" ;;
        vkd3d-2.6|vkd3d-3.0.1)
            SRC="$RT/backends/$b/x64"; [ -f "$SRC/d3d12.dll" ] || return 1
            cp "$SRC/d3d12.dll" "$SDIR/"
            [ ! -f "$SRC/d3d12core.dll" ] || cp "$SRC/d3d12core.dll" "$SDIR/"
            O="d3d12=n,b;d3d12core=n,b;$base_overrides"
            ;;
        *) return 1 ;;
    esac
    WINEDLLOVERRIDES="$O"; export WINEDLLOVERRIDES
}

{
    echo "diagnostic_schema=animalwell-tsps-v3"
    echo "timestamp=$STAMP"
    echo "mode=$MODE"
    echo "launcher_failure_rc=$FAIL_RC"
    echo "backend=$(tr -d '\r\n ' <"$ROOT/backend" 2>/dev/null || echo auto)"
    echo "backend_selected=$(tr -d '\r\n ' <"$ROOT/backend.selected-v2" 2>/dev/null || echo none)"
    echo "DISPLAY=${DISPLAY:-}"
    echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
    uname -a 2>/dev/null || true
    echo "--- mounts ---"; cat /proc/mounts 2>/dev/null || true
    echo "--- filesystems ---"; cat /proc/filesystems 2>/dev/null || true
    echo "--- memory ---"; cat /proc/meminfo 2>/dev/null || true
    echo "--- limits ---"; ulimit -a 2>/dev/null || true
    echo "--- dri ---"; ls -la /dev/dri 2>/dev/null || true
    echo "--- framebuffer ---"; ls -la /dev/fb* 2>/dev/null || true
    echo "--- X sockets ---"; ls -la /tmp/.X11-unix /tmp/.X*-lock 2>/dev/null || true
    echo "--- X binaries ---"; command -v Xorg 2>/dev/null || true; command -v X 2>/dev/null || true; command -v xdpyinfo 2>/dev/null || true
    echo "--- disk ---"; df -h "$ROOT" /tmp 2>/dev/null || true
} >"$OUT/system.log" 2>&1

[ -f "$ROOT/log.txt" ] && cp "$ROOT/log.txt" "$OUT/launcher-log.txt" 2>/dev/null || true
[ -f "$ROOT/log.prev.txt" ] && cp "$ROOT/log.prev.txt" "$OUT/launcher-log-prev.txt" 2>/dev/null || true
[ -f "$LOGDIR/Xorg.1.log" ] && cp "$LOGDIR/Xorg.1.log" "$OUT/Xorg.1.log" 2>/dev/null || true
[ -f "$LOGDIR/Xorg-stdout.log" ] && cp "$LOGDIR/Xorg-stdout.log" "$OUT/Xorg-stdout.log" 2>/dev/null || true

command -v ldd >/dev/null 2>&1 && run glibc ldd --version || true
command -v vulkaninfo >/dev/null 2>&1 && run_timeout vulkaninfo 20 vulkaninfo --summary || true
[ -x "$RT/tools/vkprobe" ] && run vkprobe "$RT/tools/vkprobe" || true
[ -x "$BOX64" ] && run box64 "$BOX64" -v || true

if setup_prefix && [ -x "$BOX64" ] && [ -x "$WINE" ]; then
    export WINEPREFIX="$PFX" WINEARCH=win64 WINEESYNC=0 WINEFSYNC=0
    export BOX64_NOBANNER=1 BOX64_DYNAREC=1 BOX64_DYNACACHE=1 BOX64_LOG=1
    export BOX64_LD_LIBRARY_PATH="$RT/box64/x64lib:$RT/wine/lib:$RT/wine/lib64${BOX64_LD_LIBRARY_PATH:+:$BOX64_LD_LIBRARY_PATH}"
    export XDG_CACHE_HOME="$ROOT/cache" VKD3D_SHADER_CACHE_PATH="$ROOT/cache/vkd3d"
    run_timeout wine-version 15 "$BOX64" "$WINE" --version || true
    run_timeout prefix-sanity 20 "$BOX64" "$WINE" cmd /c ver || true
    for b in wine vkd3d-2.6 vkd3d-3.0.1; do
        prepare_smoke "$b" || continue
        export WINEDEBUG=-all VKD3D_DEBUG=info VKD3D_LOG_FILE="$OUT/vkd3d-$b.log"
        run_timeout "d3d12-$b" 30 "$BOX64" "$WINE" "$PFX/drive_c/aw-smoke/d3d12_smoke.exe" || true
    done
    if [ "$MODE" = "--full" ] && [ -f "$GAME/Animal Well.exe" ]; then
        export WINEDEBUG=+timestamp,+seh,+loaddll VKD3D_DEBUG=info
        run_timeout game-loader 25 "$BOX64" "$WINE" "$GAME/Animal Well.exe" || true
    fi
else
    echo "lightweight prefix setup failed" >"$OUT/prefix-setup-failed.log"
fi

command -v sha256sum >/dev/null 2>&1 && sha256sum "$GAME/Animal Well.exe" "$GAME/steam_api64.dll" >"$OUT/game-sha256.txt" 2>/dev/null || true
command -v dmesg >/dev/null 2>&1 && dmesg 2>/dev/null | tail -300 >"$OUT/dmesg-tail.log" || true

BUNDLE="$LOGDIR/diagnostics-$STAMP.tar.gz"
if command -v tar >/dev/null 2>&1 && tar -czf "$BUNDLE" -C "$LOGDIR" "diag-$STAMP" 2>/dev/null; then
    echo "$BUNDLE"
else
    echo "$OUT"
fi
exit 0
