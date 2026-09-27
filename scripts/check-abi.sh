#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
MAX_GLIBC="${MAX_GLIBC:-2.31}"
MAX_GLIBCXX="${MAX_GLIBCXX:-3.4.28}"
fail=0
count=0

version_gt() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" = "$1" ] && [ "$1" != "$2" ]; }

while IFS= read -r -d '' f; do
  if ! file "$f" | grep -q 'ELF '; then continue; fi
  count=$((count+1))
  arch="$(file -b "$f")"
  glibc="$(readelf --version-info "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -Vu | tail -n1 || true)"
  glibcxx="$(readelf --version-info "$f" 2>/dev/null | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBCXX_//' | sort -Vu | tail -n1 || true)"
  printf '%-70s glibc=%-8s glibcxx=%-10s %s\n' "${f#$ROOT/}" "${glibc:-n/a}" "${glibcxx:-n/a}" "$arch"
  if [ -n "$glibc" ] && version_gt "$glibc" "$MAX_GLIBC"; then
    echo "ERROR: $f requires GLIBC_$glibc > GLIBC_$MAX_GLIBC" >&2; fail=1
  fi
  if [ -n "$glibcxx" ] && version_gt "$glibcxx" "$MAX_GLIBCXX"; then
    echo "ERROR: $f requires GLIBCXX_$glibcxx > GLIBCXX_$MAX_GLIBCXX" >&2; fail=1
  fi
done < <(find "$ROOT" -type f -print0)

[ "$count" -gt 0 ] || { echo "ERROR: no ELF files found below $ROOT" >&2; exit 2; }
exit "$fail"
