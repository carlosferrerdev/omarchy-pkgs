#!/bin/bash
# End-to-end trust-boundary tests using disposable OpenPGP keys and artifacts.

set -euo pipefail

ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}
TEST_ROOT=$(mktemp -d "$TMP_BASE/opst.XXXXXX")
PASSPHRASE="omarchy-signing-test"
FAILURES=0

cleanup() {
  case "$TEST_ROOT" in
  "$TMP_BASE"/opst.*) rm -rf -- "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

assert_success() {
  local name="$1"
  shift
  if "$@" >"$TEST_ROOT/last-command.log" 2>&1; then
    pass "$name"
  else
    sed 's/^/  /' "$TEST_ROOT/last-command.log" >&2
    fail "$name"
  fi
}

assert_failure() {
  local name="$1"
  shift
  if "$@" >"$TEST_ROOT/last-command.log" 2>&1; then
    fail "$name"
  else
    pass "$name"
  fi
}

make_key() {
  local key_home="$1"
  local identity="$2"

  mkdir -m 700 "$key_home"
  GNUPGHOME="$key_home" gpg --batch --pinentry-mode loopback \
    --passphrase "$PASSPHRASE" --quick-generate-key "$identity" rsa2048 sign 0 \
    >/dev/null 2>&1
}

make_subkey_signer() {
  local key_home="$1"
  local identity="$2"
  local primary_fingerprint

  mkdir -m 700 "$key_home"
  GNUPGHOME="$key_home" gpg --batch --pinentry-mode loopback \
    --passphrase "$PASSPHRASE" --quick-generate-key "$identity" rsa2048 cert 0 \
    >/dev/null 2>&1
  primary_fingerprint=$(key_fingerprint "$key_home")
  GNUPGHOME="$key_home" gpg --batch --pinentry-mode loopback \
    --passphrase "$PASSPHRASE" --quick-add-key "$primary_fingerprint" rsa2048 sign 0 \
    >/dev/null 2>&1
}

key_fingerprint() {
  GNUPGHOME="$1" gpg --batch --with-colons --fingerprint --list-secret-keys 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }'
}

last_key_fingerprint() {
  GNUPGHOME="$1" gpg --batch --with-colons --fingerprint --fingerprint --list-secret-keys 2>/dev/null |
    awk -F: '$1 == "fpr" { fingerprint=$10 } END { print fingerprint }'
}

export_private_key() {
  GNUPGHOME="$1" gpg --batch --pinentry-mode loopback --passphrase "$PASSPHRASE" \
    --armor --export-secret-keys "$2"
}

export_public_key() {
  GNUPGHOME="$1" gpg --batch --armor --export "$2" >"$3"
}

make_package() {
  mkdir -p "$1"
  printf 'fixture package payload: %s\n' "$2" >"$1/$2"
}

run_sign() {
  local output_dir="$1"
  local private_key="$2"
  local fingerprint="$3"
  local passphrase="${4:-$PASSPHRASE}"
  local private_key_file="$output_dir/.signing-private-key"
  local passphrase_file="$output_dir/.signing-passphrase"
  local status

  printf '%s' "$private_key" >"$private_key_file"
  printf '%s' "$passphrase" >"$passphrase_file"
  chmod 0600 "$private_key_file" "$passphrase_file"
  if env \
    BUILD_OUTPUT_DIR="$output_dir" \
    GPG_PRIVATE_KEY_FILE="$private_key_file" \
    GPG_PASSPHRASE_FILE="$passphrase_file" \
    OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT="$fingerprint" \
    "$BASH" "$ROOT_DIR/build/sign.sh"; then
    status=0
  else
    status=$?
  fi
  rm -f -- "$private_key_file" "$passphrase_file"
  return "$status"
}

make_promote_sandbox() {
  local sandbox="$1"

  mkdir -p "$sandbox/bin" "$sandbox/helpers" "$sandbox/fake-bin"
  cp "$ROOT_DIR/bin/promote-build" "$sandbox/bin/promote-build"
  cp "$ROOT_DIR/helpers/message-helpers.sh" "$sandbox/helpers/message-helpers.sh"
  cp "$ROOT_DIR/helpers/paths.sh" "$sandbox/helpers/paths.sh"
  cp "$ROOT_DIR/helpers/lock-helpers.sh" "$sandbox/helpers/lock-helpers.sh"
  printf '#!/bin/sh\nexit 0\n' >"$sandbox/fake-bin/flock"
  chmod +x "$sandbox/bin/promote-build" "$sandbox/fake-bin/flock"
}

make_sign_sandbox() {
  local sandbox="$1"

  mkdir -p "$sandbox/bin" "$sandbox/helpers" "$sandbox/build" \
    "$sandbox/build-output/edge/x86_64" "$sandbox/fake-bin"
  cp "$ROOT_DIR/bin/sign" "$sandbox/bin/sign"
  cp "$ROOT_DIR/helpers/message-helpers.sh" "$sandbox/helpers/message-helpers.sh"
  cp "$ROOT_DIR/helpers/paths.sh" "$sandbox/helpers/paths.sh"
  cp "$ROOT_DIR/helpers/signing-secret-helpers.sh" "$sandbox/helpers/signing-secret-helpers.sh"
  printf '%s\n' \
    '#!/bin/sh' \
    'exit 92' >"$sandbox/fake-bin/docker"
  cat >"$sandbox/build/sign.sh" <<'STUB'
#!/bin/bash
set -eu
[[ -z ${GPG_PRIVATE_KEY+x} && -z ${GPG_PASSPHRASE+x} ]] || exit 91
[[ -f $GPG_PRIVATE_KEY_FILE && ! -L $GPG_PRIVATE_KEY_FILE ]] || exit 93
[[ -f $GPG_PASSPHRASE_FILE && ! -L $GPG_PASSPHRASE_FILE ]] || exit 94
printf 'fingerprint=%s\nprivate=%s\npassphrase=%s\n' \
  "$OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT" "$GPG_PRIVATE_KEY_FILE" \
  "$GPG_PASSPHRASE_FILE" >"$SIGN_WRAPPER_LOG"
STUB
  chmod +x "$sandbox/bin/sign" "$sandbox/build/sign.sh" "$sandbox/fake-bin/docker"
}

run_promote() {
  local sandbox="$1"
  local repo_root="$2"
  local public_key_file="$3"
  local trust_fingerprint="$4"
  local signing_fingerprint="$5"

  env \
    PATH="$sandbox/fake-bin:$PATH" \
    OMARCHY_REPO_ROOT="$repo_root" \
    OMARCHY_PKGS_SIGNING_PUBLIC_KEY_FILE="$public_key_file" \
    OMARCHY_PKGS_TRUST_KEY_FINGERPRINT="$trust_fingerprint" \
    OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT="$signing_fingerprint" \
    "$BASH" "$sandbox/bin/promote-build" --mirror edge --arch x86_64
}

command -v gpg >/dev/null 2>&1 || {
  echo "SKIP: gpg is required"
  exit 0
}

SIGN_WRAPPER="$TEST_ROOT/sign-wrapper"
make_sign_sandbox "$SIGN_WRAPPER"
SIGN_WRAPPER_LOG="$SIGN_WRAPPER/sign-wrapper.log"
WRAPPER_FINGERPRINT="0123456789abcdef0123456789abcdef01234567"
printf 'fixture private key\n' >"$SIGN_WRAPPER/private-key.asc"
printf 'fixture passphrase\n' >"$SIGN_WRAPPER/passphrase"
chmod 0600 "$SIGN_WRAPPER/private-key.asc" "$SIGN_WRAPPER/passphrase"
assert_success "sign wrapper validates and forwards the canonical fingerprint" \
  env PATH="$SIGN_WRAPPER/fake-bin:$PATH" SIGN_WRAPPER_LOG="$SIGN_WRAPPER_LOG" \
  GPG_PRIVATE_KEY=retired-inline-secret GPG_PASSPHRASE=retired-inline-secret \
  OMARCHY_PKGS_SIGNING_PRIVATE_KEY_FILE="$SIGN_WRAPPER/private-key.asc" \
  OMARCHY_PKGS_SIGNING_PASSPHRASE_FILE="$SIGN_WRAPPER/passphrase" \
  OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT="$WRAPPER_FINGERPRINT" \
  "$BASH" "$SIGN_WRAPPER/bin/sign"
grep -qx 'fingerprint=0123456789ABCDEF0123456789ABCDEF01234567' "$SIGN_WRAPPER_LOG" &&
  pass "sign wrapper passes the full expected fingerprint to the isolated signer" ||
  fail "sign wrapper passes the full expected fingerprint to the isolated signer"
grep -Eq '^private=.*/gomarchy-sign\.[^/]+/private-key\.asc$' "$SIGN_WRAPPER_LOG" &&
  grep -Eq '^passphrase=.*/gomarchy-sign\.[^/]+/passphrase$' "$SIGN_WRAPPER_LOG" &&
  pass "sign wrapper uses an ephemeral owner-only snapshot without Docker" ||
  fail "sign wrapper uses an ephemeral owner-only snapshot without Docker"
chmod 0644 "$SIGN_WRAPPER/passphrase"
assert_failure "sign wrapper rejects group/world-readable secret files" \
  env PATH="$SIGN_WRAPPER/fake-bin:$PATH" SIGN_WRAPPER_LOG="$SIGN_WRAPPER_LOG" \
  OMARCHY_PKGS_SIGNING_PRIVATE_KEY_FILE="$SIGN_WRAPPER/private-key.asc" \
  OMARCHY_PKGS_SIGNING_PASSPHRASE_FILE="$SIGN_WRAPPER/passphrase" \
  OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT="$WRAPPER_FINGERPRINT" \
  "$BASH" "$SIGN_WRAPPER/bin/sign"
chmod 0600 "$SIGN_WRAPPER/passphrase"
for verifier in "$ROOT_DIR/build/sign.sh" "$ROOT_DIR/bin/promote-build"; do
  grep -Fq 'EXPKEYSIG|REVKEYSIG' "$verifier" ||
    fail "$(basename "$verifier") rejects expired and revoked signing identities"
done
pass "signing and promotion reject unsafe GnuPG signature status"

make_key "$TEST_ROOT/key-a" "Signing Test A <signing-a@example.invalid>"
make_subkey_signer "$TEST_ROOT/key-b" "Signing Test B <signing-b@example.invalid>"
FINGERPRINT_A=$(key_fingerprint "$TEST_ROOT/key-a")
PRIMARY_FINGERPRINT_B=$(key_fingerprint "$TEST_ROOT/key-b")
FINGERPRINT_B=$(last_key_fingerprint "$TEST_ROOT/key-b")
PRIVATE_A=$(export_private_key "$TEST_ROOT/key-a" "$FINGERPRINT_A")
PRIVATE_B=$(export_private_key "$TEST_ROOT/key-b" "$FINGERPRINT_B")
PRIVATE_BUNDLE="$PRIVATE_A
$PRIVATE_B"
PUBLIC_A="$TEST_ROOT/signing-a.asc"
PUBLIC_B="$TEST_ROOT/signing-b.asc"
export_public_key "$TEST_ROOT/key-a" "$FINGERPRINT_A" "$PUBLIC_A"
export_public_key "$TEST_ROOT/key-b" "$FINGERPRINT_B" "$PUBLIC_B"

# The expected key may be second in a multi-key secret bundle; selection must
# never fall back to the first imported key.
SIGN_OUTPUT="$TEST_ROOT/sign-output"
PACKAGE_NAME="fixture-1-1-x86_64.pkg.tar.zst"
make_package "$SIGN_OUTPUT" "$PACKAGE_NAME"
assert_success "sign selects the exact fingerprint from a multi-key bundle" \
  run_sign "$SIGN_OUTPUT" "$PRIVATE_BUNDLE" "$FINGERPRINT_B"

VERIFY_HOME="$TEST_ROOT/verify-b"
mkdir -m 700 "$VERIFY_HOME"
GNUPGHOME="$VERIFY_HOME" gpg --batch --import "$PUBLIC_B" >/dev/null 2>&1
if STATUS=$(GNUPGHOME="$VERIFY_HOME" gpg --batch --status-fd 1 \
  --verify "$SIGN_OUTPUT/$PACKAGE_NAME.sig" "$SIGN_OUTPUT/$PACKAGE_NAME" 2>/dev/null) &&
  awk -v wanted="$FINGERPRINT_B" \
    '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $3 == wanted { exact++ }
     END { exit !(exact == 1) }' <<<"$STATUS"; then
  pass "produced signature verifies with the configured exact signer"
else
  fail "produced signature verifies with the configured exact signer"
fi

VALID_SIGNATURE_CHECKSUM=$(cksum <"$SIGN_OUTPUT/$PACKAGE_NAME.sig")
assert_failure "failed signing retry reports an invalid passphrase" \
  run_sign "$SIGN_OUTPUT" "$PRIVATE_B" "$FINGERPRINT_B" wrong-passphrase
[[ $(cksum <"$SIGN_OUTPUT/$PACKAGE_NAME.sig") == "$VALID_SIGNATURE_CHECKSUM" ]] &&
  pass "failed signing retry preserves the previous valid signature" ||
  fail "failed signing retry preserves the previous valid signature"

WRONG_OUTPUT="$TEST_ROOT/wrong-output"
make_package "$WRONG_OUTPUT" "$PACKAGE_NAME"
assert_failure "sign rejects a fingerprint absent from private material" \
  run_sign "$WRONG_OUTPUT" "$PRIVATE_A" "$FINGERPRINT_B"
[[ ! -e "$WRONG_OUTPUT/$PACKAGE_NAME.sig" ]] &&
  pass "failed signing leaves no detached signature" ||
  fail "failed signing leaves no detached signature"

SHORT_OUTPUT="$TEST_ROOT/short-output"
make_package "$SHORT_OUTPUT" "$PACKAGE_NAME"
assert_failure "sign rejects a short key id" \
  run_sign "$SHORT_OUTPUT" "$PRIVATE_A" "${FINGERPRINT_A: -16}"

# Promotion verifies all inputs before creating its repository destination.
BAD_PROMOTE="$TEST_ROOT/promote-wrong-key"
make_promote_sandbox "$BAD_PROMOTE"
make_package "$BAD_PROMOTE/build-output/edge/x86_64" "$PACKAGE_NAME"
run_sign "$BAD_PROMOTE/build-output/edge/x86_64" "$PRIVATE_B" "$FINGERPRINT_B" >/dev/null
assert_failure "promote rejects a public key that lacks the expected signer" \
  run_promote "$BAD_PROMOTE" "$BAD_PROMOTE/destination" "$PUBLIC_A" \
  "$FINGERPRINT_A" "$FINGERPRINT_B"
[[ ! -e "$BAD_PROMOTE/destination" ]] &&
  pass "failed trust preflight does not create the destination" ||
  fail "failed trust preflight does not create the destination"
[[ -f "$BAD_PROMOTE/build-output/edge/x86_64/$PACKAGE_NAME" ]] &&
  pass "failed trust preflight does not move the package" ||
  fail "failed trust preflight does not move the package"

SECRET_KEY_FILE="$TEST_ROOT/signing-a-secret.asc"
printf '%s' "$PRIVATE_A" >"$SECRET_KEY_FILE"
SECRET_PROMOTE="$TEST_ROOT/promote-secret-key-file"
make_promote_sandbox "$SECRET_PROMOTE"
make_package "$SECRET_PROMOTE/build-output/edge/x86_64" "$PACKAGE_NAME"
assert_failure "promote rejects secret material in the configured public-key file" \
  run_promote "$SECRET_PROMOTE" "$SECRET_PROMOTE/destination" "$SECRET_KEY_FILE" \
  "$FINGERPRINT_A" "$FINGERPRINT_A"
[[ ! -e "$SECRET_PROMOTE/destination" ]] &&
  pass "secret-key rejection occurs before destination creation" ||
  fail "secret-key rejection occurs before destination creation"

WRONG_SIGNER_PROMOTE="$TEST_ROOT/promote-wrong-signer"
make_promote_sandbox "$WRONG_SIGNER_PROMOTE"
make_package "$WRONG_SIGNER_PROMOTE/build-output/edge/x86_64" "$PACKAGE_NAME"
run_sign "$WRONG_SIGNER_PROMOTE/build-output/edge/x86_64" "$PRIVATE_B" "$FINGERPRINT_B" >/dev/null
assert_failure "promote rejects a package signed by a different key" \
  run_promote "$WRONG_SIGNER_PROMOTE" "$WRONG_SIGNER_PROMOTE/destination" \
  "$PUBLIC_A" "$FINGERPRINT_A" "$FINGERPRINT_A"
[[ ! -e "$WRONG_SIGNER_PROMOTE/destination" ]] &&
  pass "wrong-signer rejection occurs before destination creation" ||
  fail "wrong-signer rejection occurs before destination creation"

TAMPERED_PROMOTE="$TEST_ROOT/promote-tampered"
make_promote_sandbox "$TAMPERED_PROMOTE"
make_package "$TAMPERED_PROMOTE/build-output/edge/x86_64" "$PACKAGE_NAME"
run_sign "$TAMPERED_PROMOTE/build-output/edge/x86_64" "$PRIVATE_A" "$FINGERPRINT_A" >/dev/null
printf 'tampered after signing\n' >>"$TAMPERED_PROMOTE/build-output/edge/x86_64/$PACKAGE_NAME"
assert_failure "promote rejects package content changed after signing" \
  run_promote "$TAMPERED_PROMOTE" "$TAMPERED_PROMOTE/destination" \
  "$PUBLIC_A" "$FINGERPRINT_A" "$FINGERPRINT_A"
[[ ! -e "$TAMPERED_PROMOTE/destination" ]] &&
  pass "cryptographic failure occurs before destination creation" ||
  fail "cryptographic failure occurs before destination creation"

ORPHAN_PROMOTE="$TEST_ROOT/promote-orphan-signature"
make_promote_sandbox "$ORPHAN_PROMOTE"
make_package "$ORPHAN_PROMOTE/build-output/edge/x86_64" "$PACKAGE_NAME"
run_sign "$ORPHAN_PROMOTE/build-output/edge/x86_64" "$PRIVATE_A" "$FINGERPRINT_A" >/dev/null
printf 'not a signature\n' >"$ORPHAN_PROMOTE/build-output/edge/x86_64/orphan-1-1-x86_64.pkg.tar.zst.sig"
assert_failure "promote rejects an orphan signature instead of moving it unverified" \
  run_promote "$ORPHAN_PROMOTE" "$ORPHAN_PROMOTE/destination" \
  "$PUBLIC_A" "$FINGERPRINT_A" "$FINGERPRINT_A"
[[ ! -e "$ORPHAN_PROMOTE/destination" ]] &&
  pass "orphan signature rejection occurs before destination creation" ||
  fail "orphan signature rejection occurs before destination creation"

SYMLINK_PROMOTE="$TEST_ROOT/promote-symlink-key"
make_promote_sandbox "$SYMLINK_PROMOTE"
make_package "$SYMLINK_PROMOTE/build-output/edge/x86_64" "$PACKAGE_NAME"
ln -s "$PUBLIC_A" "$SYMLINK_PROMOTE/public-key-link.asc"
assert_failure "promote rejects a symlink public-key path" \
  run_promote "$SYMLINK_PROMOTE" "$SYMLINK_PROMOTE/destination" \
  "$SYMLINK_PROMOTE/public-key-link.asc" "$FINGERPRINT_A" "$FINGERPRINT_A"

TRUST_MISMATCH_PROMOTE="$TEST_ROOT/promote-trust-mismatch"
make_promote_sandbox "$TRUST_MISMATCH_PROMOTE"
make_package "$TRUST_MISMATCH_PROMOTE/build-output/edge/x86_64" "$PACKAGE_NAME"
assert_failure "promote rejects a public key outside the configured primary trust root" \
  run_promote "$TRUST_MISMATCH_PROMOTE" "$TRUST_MISMATCH_PROMOTE/destination" \
  "$PUBLIC_A" "$PRIMARY_FINGERPRINT_B" "$FINGERPRINT_A"
[[ ! -e "$TRUST_MISMATCH_PROMOTE/destination" ]] &&
  pass "primary trust mismatch occurs before destination creation" ||
  fail "primary trust mismatch occurs before destination creation"

DRY_RUN="$TEST_ROOT/promote-dry-run"
make_promote_sandbox "$DRY_RUN"
make_package "$DRY_RUN/build-output/edge/x86_64" "$PACKAGE_NAME"
assert_success "promote dry-run needs no signing credentials" \
  env PATH="$DRY_RUN/fake-bin:$PATH" OMARCHY_REPO_ROOT="$DRY_RUN/destination" \
  "$BASH" "$DRY_RUN/bin/promote-build" --mirror edge --arch x86_64 --dry-run
[[ ! -e "$DRY_RUN/destination" ]] &&
  pass "promote dry-run does not create the destination" ||
  fail "promote dry-run does not create the destination"

if ((BASH_VERSINFO[0] >= 4)); then
  GOOD_PROMOTE="$TEST_ROOT/promote-good"
  make_promote_sandbox "$GOOD_PROMOTE"
  make_package "$GOOD_PROMOTE/build-output/edge/x86_64" "$PACKAGE_NAME"
  run_sign "$GOOD_PROMOTE/build-output/edge/x86_64" "$PRIVATE_B" "$FINGERPRINT_B" >/dev/null
  assert_success "promote accepts a signing subkey belonging to the trusted primary" \
    run_promote "$GOOD_PROMOTE" "$GOOD_PROMOTE/destination" "$PUBLIC_B" \
    "$PRIMARY_FINGERPRINT_B" "$FINGERPRINT_B"
  [[ -f "$GOOD_PROMOTE/destination/edge/x86_64/$PACKAGE_NAME" &&
    -f "$GOOD_PROMOTE/destination/edge/x86_64/$PACKAGE_NAME.sig" ]] &&
    pass "successful promotion preserves the package-signature pair" ||
    fail "successful promotion preserves the package-signature pair"

  REPAIR_PROMOTE="$TEST_ROOT/promote-repair-signature"
  make_promote_sandbox "$REPAIR_PROMOTE"
  make_package "$REPAIR_PROMOTE/build-output/edge/x86_64" "$PACKAGE_NAME"
  run_sign "$REPAIR_PROMOTE/build-output/edge/x86_64" "$PRIVATE_A" "$FINGERPRINT_A" >/dev/null
  mkdir -p "$REPAIR_PROMOTE/destination/edge/x86_64"
  cp "$REPAIR_PROMOTE/build-output/edge/x86_64/$PACKAGE_NAME" \
    "$REPAIR_PROMOTE/destination/edge/x86_64/$PACKAGE_NAME"
  printf 'corrupt published signature\n' \
    >"$REPAIR_PROMOTE/destination/edge/x86_64/$PACKAGE_NAME.sig"
  assert_success "promotion repairs an invalid signature for an identical published package" \
    run_promote "$REPAIR_PROMOTE" "$REPAIR_PROMOTE/destination" "$PUBLIC_A" \
    "$FINGERPRINT_A" "$FINGERPRINT_A"
  VERIFY_REPAIR_HOME="$TEST_ROOT/verify-repair"
  mkdir -m 0700 "$VERIFY_REPAIR_HOME"
  GNUPGHOME="$VERIFY_REPAIR_HOME" gpg --batch --import "$PUBLIC_A" >/dev/null 2>&1
  GNUPGHOME="$VERIFY_REPAIR_HOME" gpg --batch --verify \
    "$REPAIR_PROMOTE/destination/edge/x86_64/$PACKAGE_NAME.sig" \
    "$REPAIR_PROMOTE/destination/edge/x86_64/$PACKAGE_NAME" >/dev/null 2>&1 &&
    pass "published signature repair leaves a cryptographically valid pair" ||
    fail "published signature repair leaves a cryptographically valid pair"
else
  echo "SKIP: successful promote case requires Bash 4+ (promote-build already uses associative arrays)"
fi

if [[ $FAILURES -gt 0 ]]; then
  echo "$FAILURES signing trust test(s) failed" >&2
  exit 1
fi

echo "All signing trust tests passed"
