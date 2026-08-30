#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dockerfile="$ROOT/build/Dockerfile"
rebuild_workflow="$ROOT/.github/workflows/sync-rebuilds.yml"
test_workflow="$ROOT/.github/workflows/test.yml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local expected="$1" message="$2"
  grep -Fq -- "$expected" "$dockerfile" || fail "$message"
}

bootstrap_image=$(awk '$1 == "FROM" && $3 == "AS" && $4 == "bootstrapper" { print $2 }' "$dockerfile")
expected_image='docker.io/library/alpine:3.21.7@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d'
[[ "$bootstrap_image" == "$expected_image" ]] ||
  fail "bootstrap image must use the reviewed Alpine version and multi-architecture digest"

if grep -Eq 'raw\.githubusercontent\.com/archlinuxarm/PKGBUILDs/(master|main)/' "$dockerfile"; then
  fail "Arch Linux ARM bootstrap inputs must not follow a mutable branch"
fi
if grep -Fq 'https://archlinux.org/packages/core/any/archlinux-keyring/download' "$dockerfile"; then
  fail "Arch keyring bootstrap must not use the mutable latest-package endpoint"
fi
if grep -R -Eq -- '--privileged|multiarch/qemu-user-static' "$ROOT/bin" "$ROOT/helpers"; then
  fail "package commands must not register emulation through a privileged mutable image"
fi
if grep -Eq 'mirror\.omarchy\.org|pkgs\.omarchy\.org' "$rebuild_workflow"; then
  fail "rebuild automation must not inherit upstream Omarchy package infrastructure"
fi
grep -Fq 'docker.io/archlinux/archlinux:base-20260829.0.582217@sha256:6909c68015469764a98ba84eb5d73a3eb8d92e39b0ee9a21ac35f1dc4746d97b' \
  "$rebuild_workflow" || fail "rebuild automation must use the reviewed immutable Arch image"
grep -Fq 'docker.io/archlinux/archlinux:base-devel-20260829.0.582217@sha256:fdb1815d139014c57a768896ed60d52e67d757914c918b7c3a50b7218373ec5f' \
  "$test_workflow" || fail "tests must use the reviewed immutable Arch development image"
grep -Fq 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' \
  "$rebuild_workflow" || fail "rebuild checkout action must be pinned by commit"
grep -Fq 'peter-evans/create-pull-request@22a9089034f40e5a961c8808d113e2c98fb63676' \
  "$rebuild_workflow" || fail "rebuild pull-request action must be pinned by commit"
grep -Fq 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' \
  "$test_workflow" || fail "test checkout action must be pinned by commit"
if grep -Eq 'uses: [^ ]+@v[0-9]+' "$rebuild_workflow" "$test_workflow"; then
  fail "release workflows must not execute actions through mutable major-version tags"
fi
grep -Fq './bin/sync-rebuilds --self-test' "$test_workflow" ||
  fail "Arch CI must exercise the signed rebuild-floor self-test"
grep -Fq 'pacman -Syu --noconfirm git jq' "$test_workflow" ||
  fail "Arch CI must install the git and jq self-test dependencies"
grep -Fq 'https://geo.mirror.pkgbuild.com/\$repo/os/\$arch' "$rebuild_workflow" ||
  fail "rebuild automation must use the official Arch geo mirror"
for trust_input in \
  OMARCHY_PKGS_DB_BASE \
  OMARCHY_PKGS_TRUST_KEY_FINGERPRINT \
  OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT \
  GOMARCHY_PKGS_SIGNING_PUBLIC_KEY_B64; do
  grep -Fq "$trust_input" "$rebuild_workflow" ||
    fail "rebuild automation is missing repository trust input $trust_input"
done

assert_contains \
  'ALARM_PKGBUILDS_COMMIT="c9df006bd10533df2d59a94cc0c565897cf945b6"' \
  "Arch Linux ARM inputs must use the reviewed upstream commit"
assert_contains \
  'e25f0bc284287342b221377d2a0ca0203eaf13f52d369d6676c4730a8e2b1de1' \
  "Arch Linux ARM mirrorlist must have a reviewed checksum"
assert_contains \
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' \
  "Arch Linux ARM revoked list must have a reviewed checksum"
assert_contains \
  'f2a7250f2a2b77542f82f4219b2bae7895f27b3dcfdf350b497e2be306af776d' \
  "Arch Linux ARM trusted list must have a reviewed checksum"
assert_contains \
  '6ce771e853f04a38a5b533cb33e61f877b9b06b58b6db051eb8a15d737a2332f' \
  "Arch Linux ARM public keyring must have a reviewed checksum"

assert_contains \
  'https://archive.archlinux.org/packages/a/archlinux-keyring/archlinux-keyring-20260727-1-any.pkg.tar.zst' \
  "Arch keyring must come from a versioned official archive URL"
assert_contains \
  '694c4236ff403b5be549436d2df2910092cb6d778bb027fd232be9dddf4ea090' \
  "Arch keyring package must have a reviewed checksum"

checksum_checks=$(grep -Fc 'sha256sum -c -' "$dockerfile")
[[ "$checksum_checks" -eq 5 ]] ||
  fail "every downloaded mirror/keyring bootstrap artifact must be checksum-verified"
assert_contains 'unzstd < "${ARCH_KEYRING_PACKAGE}"' \
  "Arch keyring package must be verified as a file before extraction"

assert_contains 'mkdir -p /home/builder/.gnupg /build-output' \
  "builder image must create the isolated package output directory"
assert_contains 'chown -R builder:builder /home/builder /build-output' \
  "isolated package output must belong to the unprivileged builder"

printf 'PASS: builder bootstrap inputs are immutable and integrity-checked\n'
