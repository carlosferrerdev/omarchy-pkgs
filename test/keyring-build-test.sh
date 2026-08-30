#!/bin/bash
# Trust-root builder tests with disposable OpenPGP keys and a fake Docker CLI.

set -euo pipefail

ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}
TEST_ROOT=$(mktemp -d "$TMP_BASE/okbt.XXXXXX")
FAILURES=0

cleanup() {
  case "$TEST_ROOT" in
  "$TMP_BASE"/okbt.*) rm -rf -- "$TEST_ROOT" ;;
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
  local key_home="$1" identity="$2"

  mkdir -m 700 "$key_home"
  GNUPGHOME="$key_home" gpg --batch --passphrase '' \
    --quick-generate-key "$identity" rsa1024 cert 1d >/dev/null 2>&1
  local fingerprint
  fingerprint=$(public_fingerprint "$key_home")
  GNUPGHOME="$key_home" gpg --batch --passphrase '' \
    --quick-add-key "$fingerprint" rsa1024 sign 1d >/dev/null 2>&1
}

public_fingerprint() {
  GNUPGHOME="$1" gpg --batch --with-colons --fingerprint --list-keys 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }'
}

make_sandbox() {
  local sandbox="$1"

  mkdir -p "$sandbox/bin" "$sandbox/helpers" "$sandbox/build" \
    "$sandbox/pkgbuilds/omarchy-keyring" "$sandbox/fake-bin"
  cp "$ROOT_DIR/bin/build" "$sandbox/bin/build"
  cp "$ROOT_DIR/helpers/message-helpers.sh" "$sandbox/helpers/message-helpers.sh"
  cp "$ROOT_DIR/helpers/docker-helpers.sh" "$sandbox/helpers/docker-helpers.sh"
  cp "$ROOT_DIR/helpers/paths.sh" "$sandbox/helpers/paths.sh"
  cp "$ROOT_DIR/helpers/package-metadata.sh" "$sandbox/helpers/package-metadata.sh"
  cp "$ROOT_DIR/helpers/trust-helpers.sh" "$sandbox/helpers/trust-helpers.sh"
  cp -R "$ROOT_DIR/pkgbuilds/omarchy-keyring/." "$sandbox/pkgbuilds/omarchy-keyring/"
  cp "$ROOT_DIR/build/Dockerfile" "$sandbox/build/Dockerfile"
  printf '#!/bin/bash\nexit 0\n' >"$sandbox/build/build.sh"
  chmod +x "$sandbox/bin/build" "$sandbox/build/build.sh"

  cat >"$sandbox/fake-bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
command=${1:-}
shift || true
if [[ $command == info || $command == buildx || $command == start || $command == rm ]]; then
  exit 0
fi
for argument in "$@"; do
  case "$argument" in
  *:/pkgbuilds/omarchy-keyring:ro)
    source_dir=${argument%:/pkgbuilds/omarchy-keyring:ro}
    printf '%s\n' "$source_dir" >"$STAGING_PATH_LOG"
    mkdir -p "$CAPTURE_DIR"
    cp -R "$source_dir/." "$CAPTURE_DIR/"
    ;;
  esac
done
case "$command" in
create)
  if [[ " $* " == *" BUILD_PLAN_FILE=/tmp/gomarchy-build-plan "* ]]; then
    printf 'plan-container\n'
  else
    printf 'build-container\n'
  fi
  ;;
cp)
  source_path=$1
  destination=$2
  case "$source_path" in
  plan-container:*) printf 'omarchy-keyring\n' >"$destination" ;;
  build-container:*)
    mkdir -p "$destination"
    printf 'fixture package\n' >"$destination/omarchy-keyring-1-1-any.pkg.tar.zst"
    if [[ ${TEST_EXTRA_ARTIFACT:-0} == 1 ]]; then
      printf 'injected package\n' >"$destination/injected-1-1-any.pkg.tar.zst"
    fi
    ;;
  *) exit 93 ;;
  esac
  ;;
*) exit 94 ;;
esac
EOF
  cat >"$sandbox/fake-bin/bsdtar" <<'EOF'
#!/bin/bash
case "$2" in
*omarchy-keyring-*.pkg.tar.*) printf 'pkgname = omarchy-keyring\n' ;;
*injected-*.pkg.tar.*) printf 'pkgname = injected\n' ;;
*) exit 1 ;;
esac
EOF
  printf '#!/bin/bash\nexit 1\n' >"$sandbox/fake-bin/sudo"
  chmod +x "$sandbox/fake-bin/docker" "$sandbox/fake-bin/bsdtar" "$sandbox/fake-bin/sudo"
}

run_build() {
  local sandbox="$1" public_key_file="$2" fingerprint="$3" base_url="$4"

  env PATH="$sandbox/fake-bin:$PATH" TMPDIR="$sandbox/tmp" \
    DOCKER_LOG="$sandbox/docker.log" CAPTURE_DIR="$sandbox/captured-keyring" \
    STAGING_PATH_LOG="$sandbox/staging-path.log" \
    OMARCHY_PKGS_DB_BASE="$base_url" \
    OMARCHY_PKGS_TRUST_KEY_FINGERPRINT="$fingerprint" \
    OMARCHY_PKGS_SIGNING_PUBLIC_KEY_FILE="$public_key_file" \
    "$sandbox/bin/build" --arch x86_64 --mirror edge --package omarchy-keyring
}

command -v gpg >/dev/null 2>&1 || {
  echo "SKIP: gpg is required"
  exit 0
}

grep -Fq 'https://geo.mirror.pkgbuild.com/$repo/os/$arch' "$ROOT_DIR/build/Dockerfile" &&
  pass "x86_64 builder uses the official Arch geo mirror" ||
  fail "x86_64 builder uses the official Arch geo mirror"
if grep -Eqi 'pkgs\.omarchy\.org|mirror\.omarchy\.org|recv-keys|keyserver|40DFB630FF42BCFFB047046CF0134EE680CAC571' \
  "$ROOT_DIR/build/Dockerfile"; then
  fail "builder image contains no upstream package bootstrap"
else
  pass "builder image contains no upstream package bootstrap"
fi
grep -Fq -- '--fingerprint --fingerprint' "$ROOT_DIR/helpers/trust-helpers.sh" &&
  grep -Fq 'primary_unsafe_count' "$ROOT_DIR/helpers/trust-helpers.sh" &&
  pass "keyring preflight inspects subkey fingerprints and rejects an unsafe primary" ||
  fail "keyring preflight inspects subkey fingerprints and rejects an unsafe primary"
if grep -Fq 'Optional TrustAll' "$ROOT_DIR/build/build.sh"; then
  fail "isolated file repositories do not pretend to establish package trust"
elif [[ "$(grep -Fc 'SigLevel = Never' "$ROOT_DIR/build/build.sh")" -ge 2 ]]; then
  pass "isolated build repositories defer signature trust to promotion"
else
  fail "isolated build repositories defer signature trust to promotion"
fi
[[ ! -e "$ROOT_DIR/pkgbuilds/omarchy-keyring/omarchy.gpg" &&
  ! -e "$ROOT_DIR/pkgbuilds/omarchy-keyring/omarchy-trusted" ]] &&
  pass "upstream public trust files are not versioned" ||
  fail "upstream public trust files are not versioned"

make_key "$TEST_ROOT/key-a" "Gomarchy Build Test A <a@example.invalid>"
make_key "$TEST_ROOT/key-b" "Gomarchy Build Test B <b@example.invalid>"
FINGERPRINT_A=$(public_fingerprint "$TEST_ROOT/key-a")
FINGERPRINT_B=$(public_fingerprint "$TEST_ROOT/key-b")
PUBLIC_A="$TEST_ROOT/public-a.asc"
PUBLIC_B="$TEST_ROOT/public-b.asc"
SECRET_A="$TEST_ROOT/secret-a.asc"
PUBLIC_BUNDLE="$TEST_ROOT/public-bundle.asc"
GNUPGHOME="$TEST_ROOT/key-a" gpg --batch --armor --export "$FINGERPRINT_A" >"$PUBLIC_A"
GNUPGHOME="$TEST_ROOT/key-b" gpg --batch --armor --export "$FINGERPRINT_B" >"$PUBLIC_B"
GNUPGHOME="$TEST_ROOT/key-a" gpg --batch --armor --export-secret-keys "$FINGERPRINT_A" >"$SECRET_A"
printf '%s\n' "$(<"$PUBLIC_A")" "$(<"$PUBLIC_B")" >"$PUBLIC_BUNDLE"

MISSING="$TEST_ROOT/missing-contract"
make_sandbox "$MISSING"
mkdir "$MISSING/tmp"
assert_failure "normal build requires the explicit trust contract" \
  env PATH="$MISSING/fake-bin:$PATH" TMPDIR="$MISSING/tmp" \
  DOCKER_LOG="$MISSING/docker.log" "$MISSING/bin/build" --package omarchy-keyring
[[ ! -e "$MISSING/docker.log" && ! -e "$MISSING/build-output" ]] &&
  pass "missing contract fails before Docker and output mutation" ||
  fail "missing contract fails before Docker and output mutation"

DRY_RUN="$TEST_ROOT/dry-run"
make_sandbox "$DRY_RUN"
DRY_RUN_REAL=$(realpath "$DRY_RUN")
assert_success "dry-run does not require release credentials" \
  env PATH="$DRY_RUN/fake-bin:$PATH" DOCKER_LOG="$DRY_RUN/docker.log" \
  "$DRY_RUN/bin/build" --package omarchy-keyring --dry-run
if grep -Fq -- "-v $DRY_RUN_REAL/pkgbuilds:/pkgbuilds:ro" "$DRY_RUN/docker.log" &&
  grep -Fq -- "-v $DRY_RUN_REAL/pkgs.omarchy.org:/pkgs.omarchy.org:ro" "$DRY_RUN/docker.log" &&
  ! grep -Fq -- ':/build-output' "$DRY_RUN/docker.log" &&
  [[ ! -e "$DRY_RUN/build-output" ]]; then
  pass "dry-run evaluates package recipes only in a read-only container"
else
  sed 's/^/  docker: /' "$DRY_RUN/docker.log" >&2
  fail "dry-run evaluates package recipes only in a read-only container"
fi

SHORT="$TEST_ROOT/short-fingerprint"
make_sandbox "$SHORT"
mkdir "$SHORT/tmp"
assert_failure "build rejects a short key id" \
  run_build "$SHORT" "$PUBLIC_A" "${FINGERPRINT_A: -16}" "https://packages.gomarchy.invalid"
[[ ! -e "$SHORT/docker.log" && ! -e "$SHORT/build-output" ]] &&
  pass "short fingerprint fails before Docker and output mutation" ||
  fail "short fingerprint fails before Docker and output mutation"

UPSTREAM="$TEST_ROOT/upstream-base"
make_sandbox "$UPSTREAM"
mkdir "$UPSTREAM/tmp"
assert_failure "build rejects an upstream Omarchy database" \
  run_build "$UPSTREAM" "$PUBLIC_A" "$FINGERPRINT_A" "https://pkgs.omarchy.org"
[[ ! -e "$UPSTREAM/docker.log" && ! -e "$UPSTREAM/build-output" ]] &&
  pass "upstream database fails before Docker and output mutation" ||
  fail "upstream database fails before Docker and output mutation"

UPSTREAM_ROOT_DOT="$TEST_ROOT/upstream-root-dot"
make_sandbox "$UPSTREAM_ROOT_DOT"
mkdir "$UPSTREAM_ROOT_DOT/tmp"
assert_failure "build rejects the upstream database with a DNS root dot" \
  run_build "$UPSTREAM_ROOT_DOT" "$PUBLIC_A" "$FINGERPRINT_A" \
  "https://PKGS.OMARCHY.ORG./edge"
[[ ! -e "$UPSTREAM_ROOT_DOT/docker.log" && ! -e "$UPSTREAM_ROOT_DOT/build-output" ]] &&
  pass "root-dot upstream database fails before Docker and output mutation" ||
  fail "root-dot upstream database fails before Docker and output mutation"

for invalid_case in trailing-slash unsupported-path localhost; do
  INVALID_BASE="$TEST_ROOT/invalid-base-$invalid_case"
  make_sandbox "$INVALID_BASE"
  mkdir "$INVALID_BASE/tmp"
  case $invalid_case in
  trailing-slash) invalid_base='https://packages.gomarchy.invalid/releases/' ;;
  unsupported-path) invalid_base='https://packages.gomarchy.invalid/releases%20name' ;;
  localhost) invalid_base='https://localhost/releases' ;;
  esac
  assert_failure "build rejects repository base: $invalid_case" \
    run_build "$INVALID_BASE" "$PUBLIC_A" "$FINGERPRINT_A" "$invalid_base"
  [[ ! -e "$INVALID_BASE/docker.log" && ! -e "$INVALID_BASE/build-output" ]] &&
    pass "$invalid_case base fails before Docker and output mutation" ||
    fail "$invalid_case base fails before Docker and output mutation"
done

UPSTREAM_KEY="$TEST_ROOT/upstream-key"
make_sandbox "$UPSTREAM_KEY"
mkdir "$UPSTREAM_KEY/tmp"
assert_failure "build explicitly rejects the upstream Omarchy trust fingerprint" \
  run_build "$UPSTREAM_KEY" "$PUBLIC_A" '40DFB630FF42BCFFB047046CF0134EE680CAC571' \
  "https://packages.gomarchy.invalid"
[[ ! -e "$UPSTREAM_KEY/docker.log" && ! -e "$UPSTREAM_KEY/build-output" ]] &&
  pass "upstream trust fingerprint fails before Docker and output mutation" ||
  fail "upstream trust fingerprint fails before Docker and output mutation"

SYMLINK="$TEST_ROOT/symlink-key"
make_sandbox "$SYMLINK"
mkdir "$SYMLINK/tmp"
ln -s "$PUBLIC_A" "$SYMLINK/public-key.asc"
assert_failure "build rejects a symlink public-key path" \
  run_build "$SYMLINK" "$SYMLINK/public-key.asc" "$FINGERPRINT_A" "https://packages.gomarchy.invalid"
[[ ! -e "$SYMLINK/docker.log" && ! -e "$SYMLINK/build-output" ]] &&
  pass "symlink key fails before Docker and output mutation" ||
  fail "symlink key fails before Docker and output mutation"

SECRET="$TEST_ROOT/secret-key"
make_sandbox "$SECRET"
mkdir "$SECRET/tmp"
assert_failure "build rejects secret key material" \
  run_build "$SECRET" "$SECRET_A" "$FINGERPRINT_A" "https://packages.gomarchy.invalid"
[[ ! -e "$SECRET/docker.log" && ! -e "$SECRET/build-output" ]] &&
  pass "secret key fails before Docker and output mutation" ||
  fail "secret key fails before Docker and output mutation"

MULTIPLE="$TEST_ROOT/multiple-primary"
make_sandbox "$MULTIPLE"
mkdir "$MULTIPLE/tmp"
assert_failure "build rejects a public bundle with multiple primary keys" \
  run_build "$MULTIPLE" "$PUBLIC_BUNDLE" "$FINGERPRINT_A" "https://packages.gomarchy.invalid"
[[ ! -e "$MULTIPLE/docker.log" && ! -e "$MULTIPLE/build-output" ]] &&
  pass "multi-primary bundle fails before Docker and output mutation" ||
  fail "multi-primary bundle fails before Docker and output mutation"

MISMATCH="$TEST_ROOT/fingerprint-mismatch"
make_sandbox "$MISMATCH"
mkdir "$MISMATCH/tmp"
assert_failure "build rejects a primary fingerprint mismatch" \
  run_build "$MISMATCH" "$PUBLIC_A" "$FINGERPRINT_B" "https://packages.gomarchy.invalid"
[[ ! -e "$MISMATCH/docker.log" && ! -e "$MISMATCH/build-output" ]] &&
  pass "fingerprint mismatch fails before Docker and output mutation" ||
  fail "fingerprint mismatch fails before Docker and output mutation"

GOOD="$TEST_ROOT/good"
make_sandbox "$GOOD"
mkdir "$GOOD/tmp"
LOWERCASE_FINGERPRINT_A=$(tr '[:upper:]' '[:lower:]' <<<"$FINGERPRINT_A")
assert_success "build accepts one validated primary with a signing subkey" \
  run_build "$GOOD" "$PUBLIC_A" "$LOWERCASE_FINGERPRINT_A" "https://packages.gomarchy.invalid/releases"

! grep -Fq "$GOOD/build-output:/build-output" "$GOOD/docker.log" &&
  pass "untrusted package containers receive no writable host output mount" ||
  fail "untrusted package containers receive no writable host output mount"

INJECTED="$TEST_ROOT/injected-output"
make_sandbox "$INJECTED"
mkdir "$INJECTED/tmp"
assert_failure "build rejects an undeclared package injected by untrusted build code" \
  env TEST_EXTRA_ARTIFACT=1 PATH="$INJECTED/fake-bin:$PATH" TMPDIR="$INJECTED/tmp" \
  DOCKER_LOG="$INJECTED/docker.log" CAPTURE_DIR="$INJECTED/captured-keyring" \
  STAGING_PATH_LOG="$INJECTED/staging-path.log" \
  OMARCHY_PKGS_DB_BASE="https://packages.gomarchy.invalid/releases" \
  OMARCHY_PKGS_TRUST_KEY_FINGERPRINT="$FINGERPRINT_A" \
  OMARCHY_PKGS_SIGNING_PUBLIC_KEY_FILE="$PUBLIC_A" \
  "$INJECTED/bin/build" --arch x86_64 --mirror edge --package omarchy-keyring
[[ ! -e "$INJECTED/build-output/edge/x86_64/injected-1-1-any.pkg.tar.zst" ]] &&
  pass "undeclared package never enters the signing workspace" ||
  fail "undeclared package never enters the signing workspace"

mkdir -m 0700 "$TEST_ROOT/generated-inspection-home"
GENERATED_FINGERPRINT=$(gpg --batch --no-options --homedir "$TEST_ROOT/generated-inspection-home" \
  --show-keys --with-colons \
  "$GOOD/captured-keyring/omarchy.gpg" 2>/dev/null |
  awk -F: '$1 == "fpr" { print $10; exit }')
[[ "$GENERATED_FINGERPRINT" == "$FINGERPRINT_A" ]] &&
  pass "generated keyring contains the configured primary" ||
  fail "generated keyring contains the configured primary"
GENERATED_SUBKEY_COUNT=$(gpg --batch --no-options --homedir "$TEST_ROOT/generated-inspection-home" \
  --show-keys --with-colons \
  "$GOOD/captured-keyring/omarchy.gpg" 2>/dev/null |
  awk -F: '$1 == "sub" { count++ } END { print count + 0 }')
[[ "$GENERATED_SUBKEY_COUNT" == 1 ]] &&
  pass "generated keyring preserves the primary signing subkey" ||
  fail "generated keyring preserves the primary signing subkey"
[[ "$(<"$GOOD/captured-keyring/omarchy-trusted")" == "$FINGERPRINT_A:4:" ]] &&
  pass "generated trusted-owner file pins the configured primary" ||
  fail "generated trusted-owner file pins the configured primary"
EXPECTED_CONTRACT="schema=1
base_url=https://packages.gomarchy.invalid/releases
trust_fingerprint=$FINGERPRINT_A"
[[ "$(<"$GOOD/captured-keyring/repository.conf")" == "$EXPECTED_CONTRACT" ]] &&
  pass "generated repository contract is exact and upgradeable" ||
  fail "generated repository contract is exact and upgradeable"
if [[ $(uname -s) == Darwin ]]; then
  CONTRACT_MODE=$(stat -f '%Lp' "$GOOD/captured-keyring/repository.conf")
else
  CONTRACT_MODE=$(stat -c '%a' "$GOOD/captured-keyring/repository.conf")
fi
[[ "$CONTRACT_MODE" == 644 ]] &&
  pass "generated repository contract has mode 0644" ||
  fail "generated repository contract has mode 0644"
STAGING_PATH=$(<"$GOOD/staging-path.log")
grep -Fq -- "-v $STAGING_PATH:/pkgbuilds/omarchy-keyring:ro" "$GOOD/docker.log" &&
  pass "Docker receives only the generated keyring package overlay" ||
  fail "Docker receives only the generated keyring package overlay"
[[ ! -e "$STAGING_PATH" ]] &&
  pass "ephemeral keyring inputs are cleaned after the build" ||
  fail "ephemeral keyring inputs are cleaned after the build"
grep -Fq 'install -D -m0644 repository.conf "${pkgdir}"/etc/omarchy/repository.conf' \
  "$GOOD/captured-keyring/PKGBUILD" &&
  pass "compatibility keyring package owns the installed repository contract" ||
  fail "compatibility keyring package owns the installed repository contract"

assert_success "PKGBUILD revalidates generated trust inputs before packaging" \
  env OMARCHY_PKGS_DB_BASE='https://packages.gomarchy.invalid/releases' \
  OMARCHY_PKGS_TRUST_KEY_FINGERPRINT="$FINGERPRINT_A" \
  bash -c 'cd "$1" && source ./PKGBUILD && prepare' _ "$GOOD/captured-keyring"
assert_failure "PKGBUILD refuses a mismatched trust root even with SKIP checksums" \
  env OMARCHY_PKGS_DB_BASE='https://packages.gomarchy.invalid/releases' \
  OMARCHY_PKGS_TRUST_KEY_FINGERPRINT="$FINGERPRINT_B" \
  bash -c 'cd "$1" && source ./PKGBUILD && prepare' _ "$GOOD/captured-keyring"

if [[ $FAILURES -gt 0 ]]; then
  echo "$FAILURES keyring build test(s) failed" >&2
  exit 1
fi

echo "All keyring build tests passed"
