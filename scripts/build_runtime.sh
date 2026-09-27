#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); WORK=${WORK:-"$ROOT/.work"}; OUT=${OUT:-"$ROOT/dist"}
BOX64_REF=${BOX64_REF:-v0.4.4}; WINE_VER=${WINE_VER:-11.18}; WINE_SHA=${WINE_SHA:-f899879b8c37e0b20adca19d147cf77436f3f1a37bf16d08d27fa7137a52b9ba}; JOBS=${JOBS:-2}; PREFIX_IMAGE_MB=${PREFIX_IMAGE_MB:-640}
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"; cp -a "$ROOT/package" "$WORK/package"; RT="$WORK/package/animalwell/runtime"; mkdir -p "$RT/box64" "$RT/wine" "$RT/backends" "$RT/tools"
for x in git cmake curl tar xz python3 aarch64-linux-gnu-gcc x86_64-w64-mingw32-gcc readelf file mke2fs e2fsck debugfs truncate; do command -v "$x" >/dev/null || { echo "missing $x" >&2; exit 2; }; done

# Box64 ARM64 is built against the CI's Ubuntu Focal cross sysroot.
# Focal/glibc 2.31 is intentionally below the TSPS/SpruceOS glibc 2.33 target.
git clone -q --depth 1 --branch "$BOX64_REF" https://github.com/ptitSeb/box64.git "$WORK/box64"
cat >"$WORK/toolchain.cmake" <<'TC'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
TC
cmake -S "$WORK/box64" -B "$WORK/box64-build" -DCMAKE_TOOLCHAIN_FILE="$WORK/toolchain.cmake" -DARM64=1 -DBOX32=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build "$WORK/box64-build" -j"$JOBS"
cp "$WORK/box64-build/box64" "$RT/box64/box64"

# Do NOT copy Box64's repository x64lib directory wholesale. Those are convenience
# binaries from mixed/newer distributions and can require GLIBC/GLIBCXX newer
# than SpruceOS. Ship only the x86-64 guest helpers needed by this Wine path,
# copied from the same Ubuntu 20.04 build root as CI.
mkdir -p "$RT/box64/x64lib"
copy_focal_x64_lib() {
  name=$1
  src=
  for base in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu; do
    if [ -e "$base/$name" ]; then src="$base/$name"; break; fi
  done
  [ -n "$src" ] || { echo "missing Ubuntu Focal x86-64 helper: $name" >&2; exit 2; }
  cp -L "$src" "$RT/box64/x64lib/$name"
}
copy_focal_x64_lib libgcc_s.so.1
copy_focal_x64_lib libstdc++.so.6
copy_focal_x64_lib libunwind.so.8

# Native Vulkan probe and x64 Windows D3D12 smoke test.
aarch64-linux-gnu-gcc -O2 -Wall -Wextra -o "$RT/tools/vkprobe" "$ROOT/scripts/vkprobe.c" -ldl
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o "$RT/tools/d3d12_smoke.exe" "$ROOT/scripts/d3d12_smoke.c"

# Portable x86-64 WOW64 Wine; run through Box64, no armhf host required.
WF="wine-${WINE_VER}-amd64-wow64.tar.xz"; curl -fL --retry 5 -o "$WORK/$WF" "https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VER}/${WF}"; echo "$WINE_SHA  $WORK/$WF"|sha256sum -c -; tar -xJf "$WORK/$WF" -C "$WORK"
WD=$(find "$WORK" -maxdepth 1 -type d -name "wine-${WINE_VER}*wow64*"|head -1); [ -n "$WD" ] || { echo 'Wine extract dir missing' >&2; exit 3; }; cp -a "$WD"/. "$RT/wine/"

# SpruceOS lives on a FAT32 SD card, but Wine prefixes require symlinks in
# dosdevices/. Build the exact Wine 11.18 prefix on Linux and package it in an
# ext2 filesystem image. The launcher loop-mounts this image while the game runs.
PFXSRC="$WORK/prefix-root"
PFXIMG="$WORK/package/animalwell/prefix.ext2"
rm -rf "$PFXSRC"; mkdir -p "$PFXSRC"
export WINEPREFIX="$PFXSRC" WINEARCH=win64 WINEDEBUG=-all
export WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree=d;mshtml=d'
"$WD/bin/wine" wineboot -u >"$OUT/prefix-wineboot.log" 2>&1 || { cat "$OUT/prefix-wineboot.log" >&2; exit 5; }
"$WD/bin/wineserver" -w >>"$OUT/prefix-wineboot.log" 2>&1 || true
[ -f "$PFXSRC/system.reg" ] || { echo 'Wine prefix system.reg missing' >&2; exit 5; }
# Keep pristine copies of Wine's own D3D12 PE DLLs so changing experimental
# backends never destroys the built-in Wine fallback inside the persistent prefix.
mkdir -p "$RT/backends/wine/x64"
for dll in d3d12.dll d3d12core.dll; do
  [ -f "$PFXSRC/drive_c/windows/system32/$dll" ] || { echo "Wine prefix missing $dll" >&2; exit 5; }
  cp "$PFXSRC/drive_c/windows/system32/$dll" "$RT/backends/wine/x64/$dll"
done
sha256sum "$RT/backends/wine/x64"/*.dll >"$RT/backends/wine/SHA256SUMS"
# Make the image writable even on CFWs that launch PortMaster as a non-root user.
find "$PFXSRC" -type d -exec chmod 0777 {} +
find "$PFXSRC" -type f -exec chmod a+rw {} +
truncate -s "${PREFIX_IMAGE_MB}M" "$PFXIMG"
mke2fs -q -t ext2 -F -b 4096 -m 0 -L AW_PREFIX -d "$PFXSRC" "$PFXIMG"
e2fsck -fn "$PFXIMG" >"$OUT/prefix-e2fsck.txt" 2>&1 || { cat "$OUT/prefix-e2fsck.txt" >&2; exit 5; }
debugfs -R 'stat /system.reg' "$PFXIMG" >"$OUT/prefix-debugfs.txt" 2>&1
debugfs -R 'stat /dosdevices/c:' "$PFXIMG" >>"$OUT/prefix-debugfs.txt" 2>&1
grep -q 'Type: regular' "$OUT/prefix-debugfs.txt"
grep -q 'Type: symlink' "$OUT/prefix-debugfs.txt"
sha256sum "$PFXIMG" >"$OUT/prefix-sha256.txt"
unset WINEPREFIX WINEARCH WINEDEBUG WINEDLLOVERRIDES
rm -rf "$PFXSRC"

fetch_vkd3d(){ v=$1; dest="$RT/backends/vkd3d-$v"; mkdir -p "$WORK/vkd3d-$v" "$dest/x64"; api="https://api.github.com/repos/HansKristian-Work/vkd3d-proton/releases/tags/v$v"; url=$(curl -fsSL "$api"|python3 -c 'import json,sys;j=json.load(sys.stdin);a=[x["browser_download_url"] for x in j.get("assets",[]) if x["name"].endswith((".tar.zst",".tar.gz")) and "vkd3d-proton" in x["name"]];print(a[0] if a else "")'); [ -n "$url" ] || exit 4; case "$url" in *.tar.zst) curl -fL --retry 5 "$url"|tar --zstd -xf - -C "$WORK/vkd3d-$v";; *.tar.gz) curl -fL --retry 5 "$url"|tar -xzf - -C "$WORK/vkd3d-$v";; esac; d=$(find "$WORK/vkd3d-$v" -type f -path '*/x64/d3d12.dll'|head -1); c=$(find "$WORK/vkd3d-$v" -type f -path '*/x64/d3d12core.dll'|head -1 || true); [ -n "$d" ] || exit 4; cp "$d" "$dest/x64/"; [ -z "$c" ] || cp "$c" "$dest/x64/"; sha256sum "$dest/x64"/*.dll >"$dest/SHA256SUMS"; }
fetch_vkd3d 2.6; fetch_vkd3d 3.0.1

chmod +x "$WORK/package/Animal Well.sh" "$WORK/package/Animal Well Diagnose.sh" "$WORK/package/animalwell/diagnose.sh" "$RT/box64/box64" "$RT/tools/vkprobe"
printf 'box64_ref=%s\nwine=%s\nvkd3d=2.6,3.0.1\nglibc_ceiling=2.31\nglibcxx_ceiling=3.4.28\nprefix_fs=ext2\nprefix_image_mb=%s\n' "$BOX64_REF" "$WINE_VER" "$PREFIX_IMAGE_MB" >"$RT/BUILD-MANIFEST.txt"

readelf -h "$RT/box64/box64" >"$OUT/box64-readelf.txt"
readelf -d "$RT/box64/box64" >>"$OUT/box64-readelf.txt"
{ readelf --version-info "$RT/box64/box64" 2>/dev/null | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sort -Vu || true; } >"$OUT/box64-glibc-symbols.txt"
echo "max_box64_required_glibc=$(tail -1 "$OUT/box64-glibc-symbols.txt" 2>/dev/null || true)" >"$OUT/compatibility.txt"

if find "$WORK/package" -type f \( -iname 'Animal Well.exe' -o -iname 'steam_api64.dll' \)|grep -q .; then echo 'proprietary game binary found in package' >&2; exit 8; fi
(cd "$WORK" && zip -qr "$OUT/animalwell-portmaster-runtime.zip" package)
sha256sum "$OUT/animalwell-portmaster-runtime.zip" >"$OUT/SHA256SUMS"
