#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
MAX_GLIBC="${MAX_GLIBC:-2.31}"
MAX_GLIBCXX="${MAX_GLIBCXX:-3.4.28}"
fail=0
count=0

version_gt() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" = "$1" ] && [ "$1" != "$2" ]
}

printf 'ABI ceiling: GLIBC_%s / GLIBCXX_%s\n' "$MAX_GLIBC" "$MAX_GLIBCXX"
printf 'Scanning: %s\n\n' "$ROOT"

while IFS= read -r -d '' f; do
  if ! file "$f" | grep -q 'ELF '; then
    continue
  fi
  count=$((count + 1))
  desc="$(file -b "$f")"
  glibc="$(readelf --version-info "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -Vu | tail -n1 || true)"
  glibcxx="$(readelf --version-info "$f" 2>/dev/null | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBCXX_//' | sort -Vu | tail -n1 || true)"
  needed="$(readelf -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' | paste -sd, - || true)"

  printf '%s\n' "${f#$ROOT/}"
  printf '  file: %s\n' "$desc"
  printf '  max: GLIBC_%s  GLIBCXX_%s\n' "${glibc:-n/a}" "${glibcxx:-n/a}"
  printf '  needed: %s\n' "${needed:-none}"

  if [ -n "$glibc" ] && version_gt "$glibc" "$MAX_GLIBC"; then
    printf '  ERROR: requires GLIBC_%s > GLIBC_%s\n' "$glibc" "$MAX_GLIBC" >&2
    fail=1
  fi
  if [ -n "$glibcxx" ] && version_gt "$glibcxx" "$MAX_GLIBCXX"; then
    printf '  ERROR: requires GLIBCXX_%s > GLIBCXX_%s\n' "$glibcxx" "$MAX_GLIBCXX" >&2
    fail=1
  fi
done < <(find "$ROOT" -type f -print0)

if [ "$count" -eq 0 ]; then
  echo "ERROR: no ELF files found below $ROOT" >&2
  exit 2
fi

printf '\nScanned ELF files: %d\n' "$count"
if [ "$fail" -ne 0 ]; then
  echo "ABI check: FAIL" >&2
  exit 1
fi
echo "ABI check: PASS"
