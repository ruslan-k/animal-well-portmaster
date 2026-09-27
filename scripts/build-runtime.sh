#!/usr/bin/env bash
set -euo pipefail

BOX64_TAG="${BOX64_TAG:-v0.4.4}"
WINE_TAG="${WINE_TAG:-wine-11.0}"
VKD3D_TAG="${VKD3D_TAG:-v3.0.1}"
DXVK_TAG="${DXVK_TAG:-v2.6.2}"
OUT="${OUT:-/out}"
JOBS="${JOBS:-$(nproc)}"

rm -rf /build
mkdir -p /build "$OUT/runtime/bin" "$OUT/runtime/lib" "$OUT/runtime/wine" \
  "$OUT/runtime/vkd3d" "$OUT/runtime/dxvk" "$OUT/reports"

echo "== build Box64 $BOX64_TAG for aarch64 =="
git clone --depth 1 --branch "$BOX64_TAG" https://github.com/ptitSeb/box64.git /build/box64
cmake -S /build/box64 -B /build/box64/build \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DARM64=1 -DARM_DYNAREC=ON -DSAVE_MEM=ON \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build /build/box64/build -j"$JOBS"
install -m755 /build/box64/build/box64 "$OUT/runtime/bin/box64"
cp -a /build/box64/x64lib "$OUT/runtime/lib/box64-x86_64-linux-gnu"

echo "== build Wine64 $WINE_TAG on Focal =="
git clone --depth 1 --branch "$WINE_TAG" https://github.com/wine-mirror/wine.git /build/wine
mkdir -p /build/wine-build
cd /build/wine-build
/build/wine/configure \
  --enable-win64 \
  --disable-tests \
  --prefix="$OUT/runtime/wine" \
  --without-cups --without-dbus --without-gphoto --without-gstreamer \
  --without-oss --without-pulse --without-sane --without-udev \
  --without-usb --without-v4l2 --without-wayland \
  --with-x
make -j"$JOBS"
make install

echo "== build vkd3d-proton $VKD3D_TAG (Win64 DLLs) =="
git clone --recursive --depth 1 --branch "$VKD3D_TAG" \
  https://github.com/HansKristian-Work/vkd3d-proton.git /build/vkd3d-proton
meson setup /build/vkd3d-proton/build.64 \
  --cross-file /build/vkd3d-proton/build-win64.txt \
  --buildtype release --strip \
  --prefix "$OUT/runtime/vkd3d" \
  --bindir x64 --libdir x64 \
  /build/vkd3d-proton
ninja -C /build/vkd3d-proton/build.64 install

echo "== build DXVK $DXVK_TAG (Win64 DXGI) =="
git clone --recursive --depth 1 --branch "$DXVK_TAG" \
  https://github.com/doitsujin/dxvk.git /build/dxvk
meson setup /build/dxvk/build.64 \
  --cross-file /build/dxvk/build-win64.txt \
  --buildtype release --strip \
  --prefix "$OUT/runtime/dxvk" \
  --bindir x64 --libdir x64 \
  /build/dxvk
ninja -C /build/dxvk/build.64 install

cat > "$OUT/runtime/VERSIONS" <<EOF
box64=$BOX64_TAG
wine=$WINE_TAG
vkd3d-proton=$VKD3D_TAG
dxvk=$DXVK_TAG
glibc-baseline=2.31
EOF

/src/scripts/check-glibc.sh "$OUT/runtime" | tee "$OUT/reports/glibc-audit.txt"
/src/scripts/test-runtime.sh "$OUT/runtime" | tee "$OUT/reports/runtime-smoke.txt"

tar -C "$OUT" -caf "$OUT/animal-well-runtime-aarch64.tar.xz" runtime reports
sha256sum "$OUT/animal-well-runtime-aarch64.tar.xz" > "$OUT/animal-well-runtime-aarch64.tar.xz.sha256"
