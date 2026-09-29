#!/bin/bash
# Build Wine 11.18's xaudio2_9.dll (the PE XAudio2/FAudio module) against a
# post-26.09 FAudio snapshot, to fix the FAudio 26.09 out-of-bounds mix bug
# (upstream FAudio issue #404 / Wine bug 60294) that crashed Animal Well in the
# mix loop (xaudio2_9.dll+0x12c38, MOVAPS store into a guard page).
#
# Verified build: Wine 11.18 + FAudio 0d03cb04c3c2bacf5e69d0d7e58b65d7202fc618
# Result (stripped): sha256 04ae9105375fe9be7724133783eb3fb328e62502bd0a7faf9ec23aba738c3abd
# Runtime proof: trace:xaudio2 DllMain "Using FAudio version 260901"
#   (FAUDIO_PATCH_VERSION bumped to 1 so the log proves the build is active).
#
# Usage: build-xaudio2-faudio.sh <wine-src-dir> <faudio-src-dir> <out.dll>
set -e
WINE_SRC=$1; FAUDIO_SRC=$2; OUT=${3:-xaudio2_9.dll}
cd "$WINE_SRC"
# 1. Replace the bundled FAudio sources with the newer snapshot
#    (keep wine's Makefile.in and platform glue in place).
cp -f "$FAUDIO_SRC"/src/*.c "$FAUDIO_SRC"/src/*.h "$FAUDIO_SRC"/src/*.inl libs/faudio/src/
cp -f "$FAUDIO_SRC"/include/*.h libs/faudio/include/
# 2. Duplicate-symbol fix: FAudio master defines MFAudioFormat_XMAudio2 in both
#    FAudio_platform_win32.c and FAudio_platform_win32_wmadec.c; wine builds with
#    -DHAVE_WMADEC so the link fails. Guard the platform_win32.c definition.
if ! grep -q "#ifndef HAVE_WMADEC" libs/faudio/src/FAudio_platform_win32.c; then
    sed -i 's|^DEFINE_MEDIATYPE_GUID(MFAudioFormat_XMAudio2, FAUDIO_FORMAT_XMAUDIO2);$|#ifndef HAVE_WMADEC\nDEFINE_MEDIATYPE_GUID(MFAudioFormat_XMAudio2, FAUDIO_FORMAT_XMAUDIO2);\n#endif|' \
        libs/faudio/src/FAudio_platform_win32.c
fi
# 3. Bump the patch version so the device log proves which FAudio is active.
sed -i 's/#define FAUDIO_PATCH_VERSION\t 0/#define FAUDIO_PATCH_VERSION\t 1/' libs/faudio/include/FAudio.h
# 4. 64-bit-only minimal configure + build of just the XAudio2 module.
./configure --enable-archs=x86_64 --without-x --without-freetype --without-fontconfig \
    --without-gnutls --without-alsa --without-pulse --without-oss --without-capi \
    --without-cups --without-dbus --without-ldap --without-netapi --without-opencl \
    --without-opengl --without-osmesa --without-pcap --without-sane --without-udev \
    --without-usb --without-v4l2 --without-wayland
make -j4 dlls/xaudio2_9/x86_64-windows/xaudio2_9.dll
x86_64-w64-mingw32-strip --strip-unneeded dlls/xaudio2_9/x86_64-windows/xaudio2_9.dll 2>/dev/null || true
cp dlls/xaudio2_9/x86_64-windows/xaudio2_9.dll "$OUT"
sha256sum "$OUT"
