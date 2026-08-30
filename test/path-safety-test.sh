#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

expect_rejection() {
  local description="$1"
  shift
  if "$@" >"$work/out" 2>"$work/err"; then
    fail "$description"
  fi
  if ! { cat "$work/out"; cat "$work/err"; } | grep -Eq 'Invalid (architecture|mirror)'; then
    sed 's/^/  /' "$work/out" >&2
    sed 's/^/  /' "$work/err" >&2
    fail "$description did not report the invalid path component"
  fi
  pass "$description"
}

expect_rejection "inherited architecture traversal fails while paths initialize" \
  env ARCH='../escape' BUILD_ROOT="$ROOT" bash -c 'source "$BUILD_ROOT/helpers/paths.sh"'
expect_rejection "inherited mirror traversal fails while paths initialize" \
  env MIRROR='edge/../../escape' BUILD_ROOT="$ROOT" bash -c 'source "$BUILD_ROOT/helpers/paths.sh"'

commands=(
  build sign promote-build sync-repo update-repo remove-package clean-repo
  release advance-channel upload-prebuilt
)
for command_name in "${commands[@]}"; do
  expect_rejection "$command_name rejects architecture traversal before work" \
    "$ROOT/bin/$command_name" --arch '../escape'
done

expect_rejection "sign rejects mirror traversal before reading signing secrets" \
  "$ROOT/bin/sign" --mirror 'edge/../../escape'

printf 'All release path safety tests passed\n'
