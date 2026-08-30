#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper="$ROOT/helpers/docker-helpers.sh"
dockerfile="$ROOT/build/Dockerfile"
build_wrapper="$ROOT/bin/build"
remove_wrapper="$ROOT/bin/remove-package"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

! grep -Eq 'chmod[[:space:]]+-R[[:space:]]+0?777|chmod[[:space:]]+-R[[:space:]]+a\+rwx' "$helper" ||
  fail "Docker writable-path helper must never grant world write access"
grep -Fq 'chmod -R u+rwX,go-w "$dir"' "$helper" ||
  fail "Docker writable-path helper removes group/world write access"
grep -Fq '[[ -d $dir && ! -L $dir ]]' "$helper" ||
  fail "Docker writable-path helper rejects missing paths and symlinks"
grep -Fq -- '--build-arg BUILDER_UID="$builder_uid"' "$helper" ||
  fail "Docker build receives the selected unprivileged UID"
grep -Fq 'ARG BUILDER_UID=1000' "$dockerfile" ||
  fail "builder image has a non-root UID default"
grep -Fq 'useradd -m -u "${BUILDER_UID}"' "$dockerfile" ||
  fail "builder user is created with the selected UID"
grep -Fq -- '-v "$REPO_ROOT:/pkgs.omarchy.org:ro"' "$build_wrapper" ||
  fail "untrusted package builds must receive the final repository read-only"
! grep -Fq 'make_dir_writable "$REPO_DIR"' "$build_wrapper" ||
  fail "build wrapper must not transfer final-repository ownership to the container user"
! grep -Fq 'make_dir_writable "$REPO_DIR"' "$remove_wrapper" ||
  fail "package removal must not transfer final-repository ownership to a container user"
! grep -Fq -- '-v "$REPO_ROOT:/pkgs.omarchy.org"' "$remove_wrapper" ||
  fail "package removal must not expose the complete repository as a writable container mount"
grep -Fq '"$BUILD_ROOT/bin/update-repo"' "$remove_wrapper" ||
  fail "package removal must rebuild a signed database generation transactionally"

printf 'PASS: Docker build paths are least-privilege and the final repository is read-only\n'
