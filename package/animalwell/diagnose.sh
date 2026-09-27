#!/usr/bin/env bash
set -u
GAMEDIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$GAMEDIR/diagnostics-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
exec > >(tee "$OUT/diagnose.log") 2>&1

echo '=== system ==='
uname -a || true
(getconf GNU_LIBC_VERSION || ldd --version | head -n1) 2>/dev/null || true
free -m 2>/dev/null || cat /proc/meminfo | head -n20
printf '\n=== zram ===\n'; cat /proc/swaps 2>/dev/null || true
printf '\n=== display ===\n'; echo "DISPLAY=${DISPLAY:-unset}"; ps 2>/dev/null | grep -E 'Xorg|Xwayland|weston' || true
printf '\n=== runtime ===\n'; file "$GAMEDIR/runtime/box64/bin/box64" "$GAMEDIR/runtime/wine/bin/wine" || true
"$GAMEDIR/runtime/box64/bin/box64" -v 2>&1 || true

printf '\n=== Vulkan ===\n'
if command -v vulkaninfo >/dev/null 2>&1; then
  vulkaninfo --summary >"$OUT/vulkan-summary.txt" 2>&1 || true
  vulkaninfo >"$OUT/vulkan-full.txt" 2>&1 || true
  cat "$OUT/vulkan-summary.txt"
else
  echo 'vulkaninfo not installed; checking loader/ICD files only'
  find /usr /lib /vendor -maxdepth 5 \( -name 'libvulkan.so*' -o -name '*vulkan*.json' \) 2>/dev/null | head -n100 | tee "$OUT/vulkan-files.txt"
fi

printf '\n=== game ===\n'
EXE="$GAMEDIR/game/Animal Well.exe"
if [ -f "$EXE" ]; then
  sha256sum "$EXE" | tee "$OUT/game-sha256.txt"
  file "$EXE" || true
else
  echo "Missing $EXE"
fi

run_with_timeout() {
  local sec="$1"; shift
  "$@" & local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$sec" ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; sleep 2; kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 124; fi
  wait "$pid"; return $?
}

printf '\n=== startup matrix ===\n'
for backend in wine proton214 proton301; do
  echo "--- $backend ---"
  ANIMALWELL_BACKEND="$backend" BOX64_LOG=2 VKD3D_DEBUG=info run_with_timeout "${ANIMALWELL_TEST_SECONDS:-25}" "$GAMEDIR/launch.sh"
  rc=$?
  echo "$backend rc=$rc" | tee "$OUT/result-$backend.txt"
  cp -a "$GAMEDIR/logs/$backend" "$OUT/logs-$backend" 2>/dev/null || true
done

dmesg >"$OUT/dmesg.txt" 2>&1 || true
(cd "$GAMEDIR" && tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")")
echo "Diagnostics: $OUT.tar.gz"
