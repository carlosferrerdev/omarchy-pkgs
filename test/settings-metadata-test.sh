#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

stale_backup_entries=(
  'etc/systemd/zram-generator.conf'
  'etc/udev/rules.d/99-omarchy-power-profile.rules'
  'etc/udev/rules.d/99-omarchy-wifi-powersave.rules'
)
expected_zram_optdepend='zram-generator: Reads the shipped /usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf to create the compressed swap device'

for recipe in omarchy-settings omarchy-settings-dev; do
  pkgbuild="$ROOT_DIR/pkgbuilds/$recipe/PKGBUILD"
  metadata=$(bash -c '
    source "$1"
    printf "backup=%s\n" "${backup[@]}"
    printf "optdepend=%s\n" "${optdepends[@]}"
  ' _ "$pkgbuild")

  for stale in "${stale_backup_entries[@]}"; do
    ! grep -Fxq "backup=$stale" <<<"$metadata" ||
      fail "$recipe still declares an unowned backup path: $stale"
  done

  grep -Fxq "optdepend=$expected_zram_optdepend" <<<"$metadata" ||
    fail "$recipe does not describe the packaged zram drop-in"
done

printf 'PASS: settings recipes contain no known stale backup paths and describe the packaged zram drop-in\n'
