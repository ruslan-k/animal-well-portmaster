#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-"$ROOT/.work"}
OUT=${OUT:-"$ROOT/dist"}
BOX64_REF=${BOX64_REF:-v0.4.4}
WINE_VER=${WINE_VER:-11.18}
WINE_SHA=${WINE_SHA:-f899879b8c37e0b20adca19d147cf77436f3f1a37bf16d08d27fa7137a52b9ba}
JOBS=${JOBS:-2}

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"
cp -a "$ROOT/package" "$WORK/package"
RT="$WORK/package/animalwell/runtime"
mkdir -p "$RT/box64" "$RT/wine" "$RT/backends" "$RT/tools"

for x in git cmake curl tar xz python3 aarch64-linux-gnu-gcc x86_64-w64-mingw32-gcc readelf file; do
  command -v "$x" >/dev/null || { echo "missing $x" >&2; exit 2; }
done

# Box64 ARM64, built against Ubuntu Focal / glibc 2.31.
git clone -q --depth 1 --branch "$BOX64_REF" https://github.com/ptitSeb/box64.git "$WORK/box64"
cat >"$WORK/toolchain.cmake" <<'TC'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
TC
cmake -S "$WORK/box64" -B "$WORK/box64-build" \
  -DCMAKE_TOOLCHAIN_FILE="$WORK/toolchain.cmake" \
  -DARM64=1 -DBOX32=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build "$WORK/box64-build" -j"$JOBS"
cp "$WORK/box64-build/box64" "$RT/box64/box64"

# Ship only x86-64 guest helper libraries from the same Focal baseline.
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

# Probes.
aarch64-linux-gnu-gcc -O2 -Wall -Wextra -o "$RT/tools/vkprobe" "$ROOT/scripts/vkprobe.c" -ldl
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o "$RT/tools/d3d12_smoke.exe" "$ROOT/scripts/d3d12_smoke.c"

# Portable x86-64 WOW64 Wine.
WF="wine-${WINE_VER}-amd64-wow64.tar.xz"
curl -fL --retry 5 -o "$WORK/$WF" "https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VER}/${WF}"
echo "$WINE_SHA  $WORK/$WF" | sha256sum -c -
tar -xJf "$WORK/$WF" -C "$WORK"
WD=$(find "$WORK" -maxdepth 1 -type d -name "wine-${WINE_VER}*wow64*" | head -1)
[ -n "$WD" ] || { echo 'Wine extract dir missing' >&2; exit 3; }
cp -a "$WD"/. "$RT/wine/"

# TSPS/Box64 diagnostic patch: disable only Wine win32u's internal D3DKMT
# Vulkan instance. D3DKMT already treats a missing internal Vulkan instance as
# non-fatal and still allocates/returns an adapter handle. This leaves the
# process-wide Vulkan loader fully available to VKD3D/D3D12 itself.
WIN32U="$RT/wine/lib/wine/x86_64-unix/win32u.so"
WIN32U_ORIG_SHA=ae1d4166fda55ab9a9e0ac0ce2cbb93f425b2f3fdcbbb92e293c68629ed30ba4
WIN32U_PATCH_SHA=ae33290fb4eec697dc93ea0302b2a878eab30db10e4642313e65723f270c2c2b
echo "$WIN32U_ORIG_SHA  $WIN32U" | sha256sum -c -
WIN32U_SYM=$(nm -an "$WIN32U" | awk '$3 == "d3dkmt_init_vulkan" {print $1; exit}')
[ "$WIN32U_SYM" = "0000000000044940" ] || {
  echo "unexpected d3dkmt_init_vulkan symbol address: $WIN32U_SYM" >&2
  exit 6
}
python3 - "$WIN32U" "$WIN32U_SYM" <<'PY'
import sys
path, sym = sys.argv[1], int(sys.argv[2], 16)
with open(path, "r+b") as f:
    f.seek(sym)
    old = f.read(4)
    if old != bytes.fromhex("4883ec08"):
        raise SystemExit(f"unexpected d3dkmt_init_vulkan prologue: {old.hex()}")
    f.seek(sym)
    f.write(b"\xc3")
PY
echo "$WIN32U_PATCH_SHA  $WIN32U" | sha256sum -c -
mkdir -p "$RT/wine-patches"
cat >"$RT/wine-patches/D3DKMT-NOVULKAN.txt" <<EOF
wine=$WINE_VER
file=lib/wine/x86_64-unix/win32u.so
symbol=d3dkmt_init_vulkan
symbol_address=0x44940
original_sha256=$WIN32U_ORIG_SHA
patched_sha256=$WIN32U_PATCH_SHA
patch=first byte 0x48 -> 0xc3 (ret)
reason=avoid Box64 crash in Wine D3DKMT-internal Vulkan instance; VKD3D Vulkan remains enabled
EOF

# Generate a matching Wine 11.18 registry template on a real Unix filesystem.
# The target SD card may be FAT/exFAT, so the launcher recreates only a tiny
# writable prefix in /tmp and symlinks system32/syswow64 back to the bundled
# Wine PE directories. This avoids both FAT symlink failures and a huge tmpfs copy.
PFXSRC="$WORK/prefix-root"
PFXTPL="$WORK/package/animalwell/prefix-template"
rm -rf "$PFXSRC" "$PFXTPL"
mkdir -p "$PFXSRC" "$PFXTPL"
export WINEPREFIX="$PFXSRC" WINEARCH=win64 WINEDEBUG=-all
export WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree=d;mshtml=d'
"$WD/bin/wine" wineboot -u >"$OUT/prefix-wineboot.log" 2>&1 || {
  cat "$OUT/prefix-wineboot.log" >&2
  exit 5
}
"$WD/bin/wineserver" -w >>"$OUT/prefix-wineboot.log" 2>&1 || true
for f in system.reg user.reg userdef.reg .update-timestamp; do
  [ -f "$PFXSRC/$f" ] || { echo "Wine prefix template missing $f" >&2; exit 5; }
  cp -a "$PFXSRC/$f" "$PFXTPL/$f"
done
printf 'wine=%s\nlayout=tmp-symlink-prefix-v1\n' "$WINE_VER" >"$PFXTPL/MANIFEST"
unset WINEPREFIX WINEARCH WINEDEBUG WINEDLLOVERRIDES
rm -rf "$PFXSRC"

fetch_vkd3d() {
  v=$1
  dest="$RT/backends/vkd3d-$v"
  mkdir -p "$WORK/vkd3d-$v" "$dest/x64"
  api="https://api.github.com/repos/HansKristian-Work/vkd3d-proton/releases/tags/v$v"
  url=$(curl -fsSL "$api" | python3 -c 'import json,sys;j=json.load(sys.stdin);a=[x["browser_download_url"] for x in j.get("assets",[]) if x["name"].endswith((".tar.zst",".tar.gz")) and "vkd3d-proton" in x["name"]];print(a[0] if a else "")')
  [ -n "$url" ] || exit 4
  case "$url" in
    *.tar.zst) curl -fL --retry 5 "$url" | tar --zstd -xf - -C "$WORK/vkd3d-$v" ;;
    *.tar.gz) curl -fL --retry 5 "$url" | tar -xzf - -C "$WORK/vkd3d-$v" ;;
  esac
  d=$(find "$WORK/vkd3d-$v" -type f -path '*/x64/d3d12.dll' | head -1)
  c=$(find "$WORK/vkd3d-$v" -type f -path '*/x64/d3d12core.dll' | head -1 || true)
  [ -n "$d" ] || exit 4
  cp "$d" "$dest/x64/"
  [ -z "$c" ] || cp "$c" "$dest/x64/"
  sha256sum "$dest/x64"/*.dll >"$dest/SHA256SUMS"
}
fetch_vkd3d 2.6
fetch_vkd3d 3.0.1

chmod +x "$WORK/package/Animal Well.sh" "$WORK/package/Animal Well Diagnose.sh" \
  "$WORK/package/animalwell/diagnose.sh" "$RT/box64/box64" "$RT/tools/vkprobe"

printf 'box64_ref=%s\nwine=%s\nvkd3d=2.6,3.0.1\nglibc_ceiling=2.31\nglibcxx_ceiling=3.4.28\nprefix_layout=tmp-symlink-prefix-v1\n' \
  "$BOX64_REF" "$WINE_VER" >"$RT/BUILD-MANIFEST.txt"

readelf -h "$RT/box64/box64" >"$OUT/box64-readelf.txt"
readelf -d "$RT/box64/box64" >>"$OUT/box64-readelf.txt"
{ readelf --version-info "$RT/box64/box64" 2>/dev/null | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sort -Vu || true; } >"$OUT/box64-glibc-symbols.txt"
echo "max_box64_required_glibc=$(tail -1 "$OUT/box64-glibc-symbols.txt" 2>/dev/null || true)" >"$OUT/compatibility.txt"

if find "$WORK/package" -type f \( -iname 'Animal Well.exe' -o -iname 'steam_api64.dll' \) | grep -q .; then
  echo 'proprietary game binary found in package' >&2
  exit 8
fi

(cd "$WORK" && zip -qr "$OUT/animalwell-portmaster-runtime.zip" package)
sha256sum "$OUT/animalwell-portmaster-runtime.zip" >"$OUT/SHA256SUMS"
