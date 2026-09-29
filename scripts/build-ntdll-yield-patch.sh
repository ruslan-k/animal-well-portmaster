#!/bin/bash
# Rebuild wine's unix ntdll.so with the NtYieldExecution syscall storm removed.
#
# Wine's NtYieldExecution (Windows SwitchToThread) costs THREE syscalls per
# call: getrusage(RUSAGE_THREAD) -> sched_yield -> getrusage(RUSAGE_THREAD)
# (the two probes compare ru_nvcsw/ru_nivcsw to report STATUS_NO_YIELD_PERFORMED).
# Games that spin on SwitchToThread (Animal Well: ~19k iterations/s on the main
# thread) turn this into a ~57k syscalls/s storm: ~23% of one core in kernel time.
#
# The patch removes both getrusage probes and keeps sched_yield + STATUS_SUCCESS.
# Measured on the TSPS: 80,555 -> 33,533 traced syscalls per 4 s (-58%),
# getrusage eliminated entirely.
#
# Build environment: Ubuntu 20.04 (glibc 2.31, matching the device) with
# gcc-mingw-w64-x86-64 for the PE parts, --enable-archs=x86_64.
#
# NOTE: the device's ntdll.so additionally carries a UTF-16 byte patch of
# "C:\\windows\\system32\\wineboot.exe" --init -> --help (a hang workaround);
# re-apply it after building, or wineboot --init wedges the first run.
#
# Usage: build-ntdll-yield-patch.sh <wine-source-dir> <out.so>
set -e
WINE_SRC=$1; OUT=${2:-ntdll.so}
cd "$WINE_SRC"
# 1. Patch NtYieldExecution in dlls/ntdll/unix/sync.c
perl -0777 -pi -e '
  s/    ret = getrusage\( RUSAGE_THREAD, &u1 \);\n//;
  s/    if \(!ret\) ret = getrusage\( RUSAGE_THREAD, &u2 \);\n//;
  s/    if \(!ret && u1\.ru_nvcsw == u2\.ru_nvcsw && u1\.ru_nivcsw == u2\.ru_nivcsw\) return STATUS_NO_YIELD_PERFORMED;\n//;
  s/    struct rusage u1, u2;\n    int ret;\n//;
' dlls/ntdll/unix/sync.c
# 2. Configure + build only the unix ntdll.so
./configure --enable-archs=x86_64 --without-x --without-freetype --without-fontconfig \
    --without-gnutls --without-alsa --without-pulse --without-oss --without-capi \
    --without-cups --without-dbus --without-ldap --without-netapi --without-opencl \
    --without-opengl --without-osmesa --without-pcap --without-sane --without-udev \
    --without-usb --without-v4l2 --without-wayland
make -j4 dlls/ntdll/ntdll.so
cp dlls/ntdll/ntdll.so "$OUT"
# 3. Re-apply the wineboot -> --help byte patch (UTF-16LE) if built from clean sources
python3 - "$OUT" <<'PYEOF'
import sys
p = sys.argv[1]
data = open(p, "rb").read()
n = "--init".encode("utf-16-le")
if data.count(n) == 1:
    open(p, "wb").write(data.replace(n, "--help".encode("utf-16-le")))
    print("re-applied wineboot --init -> --help byte patch")
PYEOF
sha256sum "$OUT"
