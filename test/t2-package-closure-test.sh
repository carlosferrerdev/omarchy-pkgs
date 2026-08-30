#!/bin/bash

set -euo pipefail

ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
POLICY="$ROOT_DIR/policy/t2-packages.json"
FAILURES=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

command -v jq >/dev/null 2>&1 || {
  echo 'SKIP: jq is required'
  exit 0
}

expected_required=$(printf '%s\n' \
  apple-bcm-firmware \
  apple-t2-audio-config \
  linux-t2 \
  linux-t2-headers \
  t2fanrd | sort)
actual_required=$(jq -r '.required_packages[]' "$POLICY" | sort)
if [[ $actual_required == "$expected_required" ]]; then
  pass 'T2 policy tracks all five ISO package names'
else
  fail 'T2 policy tracks all five ISO package names'
fi

actual_outputs=$(
  printf '%s\n' apple-t2-audio-config t2fanrd
  (
    cd "$ROOT_DIR/pkgbuilds/linux-t2"
    bash -c 'source ./PKGBUILD; printf "%s\n" "${pkgname[@]}"'
  )
)
expected_outputs=$(jq -r '.redistributable_recipes[]' "$POLICY")
if [[ $(printf '%s\n' "$actual_outputs" | sort) == $(printf '%s\n' "$expected_outputs" | sort) ]]; then
  pass 'redistributable recipes produce the four safe T2 package names'
else
  fail 'redistributable recipes produce the four safe T2 package names'
fi

for recipe in apple-t2-audio-config linux-t2 t2fanrd; do
  pkgbuild="$ROOT_DIR/pkgbuilds/$recipe/PKGBUILD"
  metadata="$ROOT_DIR/pkgbuilds/$recipe/.omarchy/package.json"

  if [[ -f $pkgbuild && -f $metadata ]] &&
    bash -n "$pkgbuild" &&
    [[ $(jq -r '.source' "$metadata") == local ]]; then
    pass "$recipe has a valid local recipe contract"
  else
    fail "$recipe has a valid local recipe contract"
  fi

  if grep -Eq 'git\+|#(branch|tag)=' "$pkgbuild"; then
    fail "$recipe avoids mutable VCS sources"
  else
    pass "$recipe avoids mutable VCS sources"
  fi
done

if grep -R -Eqi \
  'mirror\.funami\.tech|\[arch-mact2\]|SigLevel[[:space:]]*=[[:space:]]*Never' \
  "$ROOT_DIR/pkgbuilds/apple-t2-audio-config" \
  "$ROOT_DIR/pkgbuilds/linux-t2" \
  "$ROOT_DIR/pkgbuilds/t2fanrd"; then
  fail 'T2 recipes contain no legacy unsigned repository dependency'
else
  pass 'T2 recipes contain no legacy unsigned repository dependency'
fi

if [[ ! -e $ROOT_DIR/pkgbuilds/apple-bcm-firmware ]] &&
  [[ $(jq -r '.blocked["apple-bcm-firmware"].reason // empty' "$POLICY") == *license* ]] &&
  [[ $(jq -r '.blocked["apple-bcm-firmware"].resolution // empty' "$POLICY") == *user-supplied* ]]; then
  pass 'unlicensed Apple firmware remains an explicit fail-closed blocker'
else
  fail 'unlicensed Apple firmware remains an explicit fail-closed blocker'
fi

if grep -Eq '^sha256sums=' "$ROOT_DIR/pkgbuilds/apple-t2-audio-config/PKGBUILD" &&
  grep -Eq '^sha256sums=' "$ROOT_DIR/pkgbuilds/linux-t2/PKGBUILD" &&
  grep -Eq '^sha256sums=' "$ROOT_DIR/pkgbuilds/t2fanrd/PKGBUILD"; then
  pass 'all redistributable source recipes declare integrity hashes'
else
  fail 'all redistributable source recipes declare integrity hashes'
fi

if [[ $FAILURES -ne 0 ]]; then
  printf '%s T2 package closure test(s) failed\n' "$FAILURES" >&2
  exit 1
fi

echo 'All T2 package closure tests passed'
