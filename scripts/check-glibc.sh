#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?usage: check-glibc.sh <runtime-dir>}"
BASELINE="${GLIBC_BASELINE:-2.31}"
fail=0

version_gt() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" = "$1" ] && [ "$1" != "$2" ]
}

echo "GLIBC baseline: <= $BASELINE"
while IFS= read -r -d '' f; do
  if ! file -b "$f" | grep -q 'ELF'; then
    continue
  fi
  max="$(readelf --version-info "$f" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+\.[0-9]+' \
    | sed 's/GLIBC_//' | sort -Vu | tail -n1 || true)"
  [ -n "$max" ] || max="none"
  printf '%-70s %s\n' "${f#$ROOT/}" "$max"
  if [ "$max" != "none" ] && version_gt "$max" "$BASELINE"; then
    echo "ERROR: $f requires GLIBC_$max > GLIBC_$BASELINE" >&2
    fail=1
  fi
done < <(find "$ROOT" -type f -print0)

exit "$fail"
