#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/helpers/repository-signature-helpers.sh"

TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}
work=$(mktemp -d "$TMP_BASE/grsv.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

expect_failure() {
  local description="$1"
  shift
  if "$@" >"$work/failure.out" 2>"$work/failure.err"; then
    fail "$description"
  fi
  pass "$description"
}

make_key() {
  local home="$1" identity="$2"
  mkdir -m 0700 "$home"
  gpg --batch --no-options --homedir "$home" --passphrase '' \
    --quick-generate-key "$identity" ed25519 sign 0 >/dev/null 2>&1
}

fingerprint() {
  gpg --batch --no-options --homedir "$1" --with-colons --fingerprint \
    --list-secret-keys | awk -F: '
      $1 == "sec" { primary = 1; next }
      primary && $1 == "fpr" { print toupper($10); exit }
    '
}

command -v gpg >/dev/null 2>&1 || {
  echo "SKIP: gpg is required"
  exit 0
}

make_key "$work/correct" 'Gomarchy Repository Test <repository@gomarchy.invalid>'
make_key "$work/foreign" 'Foreign Repository Test <foreign@gomarchy.invalid>'
correct_fingerprint=$(fingerprint "$work/correct")
foreign_fingerprint=$(fingerprint "$work/foreign")
correct_public="$work/correct-public.gpg"
foreign_public="$work/foreign-public.gpg"
gpg --batch --no-options --homedir "$work/correct" --armor --export "$correct_fingerprint" >"$correct_public"
gpg --batch --no-options --homedir "$work/foreign" --armor --export "$foreign_fingerprint" >"$foreign_public"

verify_home="$work/verify"
mkdir -m 0700 "$verify_home"
repository_signature_prepare_keyring "$verify_home" "$correct_public" \
  "$correct_fingerprint" "$correct_fingerprint"
pass "one configured primary signer prepares an isolated verification keyring"

artifact="$work/omarchy.db.tar.zst"
signature="$artifact.sig"
printf 'signed repository database fixture\n' >"$artifact"
gpg --batch --yes --no-options --homedir "$work/correct" \
  --local-user "$correct_fingerprint!" --detach-sign --output "$signature" "$artifact"
repository_signature_verify_exact "$verify_home" "$correct_fingerprint" "$artifact" "$signature"
pass "exact configured signer verifies the repository artifact"

printf 'tampered\n' >>"$artifact"
expect_failure "tampered repository artifact is rejected" \
  repository_signature_verify_exact "$verify_home" "$correct_fingerprint" "$artifact" "$signature"
printf 'signed repository database fixture\n' >"$artifact"

gpg --batch --yes --no-options --homedir "$work/foreign" \
  --local-user "$foreign_fingerprint!" --detach-sign --output "$work/foreign.sig" "$artifact"
expect_failure "foreign repository signer is rejected" \
  repository_signature_verify_exact "$verify_home" "$correct_fingerprint" "$artifact" "$work/foreign.sig"

bundle="$work/multiple-primary.gpg"
printf '%s\n%s\n' "$(<"$correct_public")" "$(<"$foreign_public")" >"$bundle"
mkdir -m 0700 "$work/multiple-verify"
expect_failure "multiple primary keys are rejected" \
  repository_signature_prepare_keyring "$work/multiple-verify" "$bundle" \
  "$correct_fingerprint" "$correct_fingerprint"

secret="$work/secret.gpg"
gpg --batch --no-options --homedir "$work/correct" --armor --export-secret-keys \
  "$correct_fingerprint" >"$secret"
mkdir -m 0700 "$work/secret-verify"
expect_failure "secret key material is rejected from the public trust input" \
  repository_signature_prepare_keyring "$work/secret-verify" "$secret" \
  "$correct_fingerprint" "$correct_fingerprint"

expect_failure "historical upstream fingerprint is rejected" \
  repository_signature_normalize_fingerprint OMARCHY_PKGS_TRUST_KEY_FINGERPRINT \
  40DFB630FF42BCFFB047046CF0134EE680CAC571

printf 'All repository signature helper tests passed\n'
