#!/bin/bash
# Real-GPG regression tests for staged repository database publication.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}
# Keep this short enough for gpg-agent's Unix-domain socket limit on macOS.
work=$(mktemp -d "$TMP_BASE/gds.XXXXXX")
passphrase=gomarchy-database-test

cleanup() {
  rm -rf -- "$work"
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

private_home="$work/private-gnupg"
public_home="$work/public-gnupg"
foreign_home="$work/foreign-gnupg"
mkdir -m 0700 "$private_home" "$public_home" "$foreign_home"
GNUPGHOME="$private_home" gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
  --quick-generate-key 'Gomarchy Database Test <database-test@gomarchy.invalid>' rsa2048 cert 0 \
  >"$work/keygen.log" 2>&1 || {
    sed 's/^/  /' "$work/keygen.log" >&2
    fail "could not generate disposable database signing key"
  }
trust_fingerprint=$(GNUPGHOME="$private_home" gpg --batch --with-colons --fingerprint --list-secret-keys |
  awk -F: '$1 == "sec" { want = 1; next } want && $1 == "fpr" { print toupper($10); exit }')
GNUPGHOME="$private_home" gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
  --quick-add-key "$trust_fingerprint" rsa2048 sign 0 >/dev/null 2>&1
GNUPGHOME="$private_home" gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
  --quick-add-key "$trust_fingerprint" rsa2048 sign 0 >/dev/null 2>&1
fingerprint=$(GNUPGHOME="$private_home" gpg --batch --with-colons --fingerprint --fingerprint \
  --list-secret-keys | awk -F: '$1 == "ssb" { want = 1; next } want && $1 == "fpr" { print toupper($10); exit }')
[[ $trust_fingerprint =~ ^[[:xdigit:]]{40}$ ]] || fail "generated test trust fingerprint is invalid"
[[ $fingerprint =~ ^[[:xdigit:]]{40}$ ]] || fail "generated test fingerprint is invalid"
private_key=$(GNUPGHOME="$private_home" gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
  --armor --export-secret-keys "$trust_fingerprint")
printf '%s' "$private_key" >"$work/private-key.asc"
chmod 0600 "$work/private-key.asc"
GNUPGHOME="$private_home" gpg --batch --armor --export "$trust_fingerprint" > "$work/public.asc"
GNUPGHOME="$public_home" gpg --batch --import "$work/public.asc" >/dev/null 2>&1
GNUPGHOME="$foreign_home" gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
  --quick-generate-key 'Foreign Package Test <foreign-package@gomarchy.invalid>' rsa2048 sign 0 \
  >/dev/null 2>&1
foreign_fingerprint=$(GNUPGHOME="$foreign_home" gpg --batch --with-colons --fingerprint \
  --list-secret-keys | awk -F: '$1 == "sec" { want = 1; next } want && $1 == "fpr" { print toupper($10); exit }')
[[ $foreign_fingerprint =~ ^[[:xdigit:]]{40}$ ]] || fail "generated foreign fingerprint is invalid"

mkdir -p "$work/stubs" "$work/repository/edge/x86_64"
docker_log="$work/docker.log"
: > "$docker_log"

cat > "$work/stubs/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_DOCKER_LOG"
case ${1:-} in
  info) exit 0 ;;
  buildx) exit 0 ;;
  run)
    [[ -z ${GPG_PRIVATE_KEY+x} && -z ${GPG_PASSPHRASE+x} ]] || exit 74
    [[ ${TEST_DOCKER_RUN_FAIL:-0} != 1 ]] || exit 71
    stage=""
    while (($#)); do
      if [[ $1 == -v && $2 == *:/staging ]]; then
        stage=${2%:/staging}
        shift 2
      else
        shift
      fi
    done
    [[ -n $stage && -d $stage ]] || exit 72
    printf '%s\n' "${TEST_DATABASE_CONTENT:-database}" > "$stage/omarchy.db.tar.zst"
    printf '%s\n' "${TEST_FILES_CONTENT:-files}" > "$stage/omarchy.files.tar.zst"
    ln -s omarchy.db.tar.zst "$stage/omarchy.db"
    ln -s omarchy.files.tar.zst "$stage/omarchy.files"
    ;;
  *) exit 73 ;;
esac
STUB
cat > "$work/stubs/flock" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$work/stubs/docker" "$work/stubs/flock"

repo_dir="$work/repository/edge/x86_64"
printf 'package fixture\n' > "$repo_dir/example-1.0-1-any.pkg.tar.zst"
GNUPGHOME="$private_home" gpg --batch --yes --pinentry-mode loopback --passphrase "$passphrase" \
  --local-user "$fingerprint!" --output "$repo_dir/example-1.0-1-any.pkg.tar.zst.sig" \
  --detach-sign "$repo_dir/example-1.0-1-any.pkg.tar.zst"

run_update() {
  printf '%s' "${TEST_PASSPHRASE-$passphrase}" >"$work/passphrase"
  chmod 0600 "$work/passphrase"
  PATH="$work/stubs:$PATH" \
    TEST_DOCKER_LOG="$docker_log" \
    OMARCHY_REPO_ROOT="$work/repository" \
    GPG_PRIVATE_KEY=retired-inline-secret \
    GPG_PASSPHRASE=retired-inline-secret \
    OMARCHY_PKGS_SIGNING_PRIVATE_KEY_FILE="$work/private-key.asc" \
    OMARCHY_PKGS_SIGNING_PASSPHRASE_FILE="$work/passphrase" \
    OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT="${TEST_FINGERPRINT-$fingerprint}" \
    TEST_DOCKER_RUN_FAIL="${TEST_DOCKER_RUN_FAIL-0}" \
    TEST_DATABASE_CONTENT="${TEST_DATABASE_CONTENT-database-one}" \
    TEST_FILES_CONTENT="${TEST_FILES_CONTENT-files-one}" \
    "$ROOT/bin/update-repo" --mirror edge --arch x86_64 > "$work/update.out" 2> "$work/update.err"
}

run_update || {
  sed 's/^/  /' "$work/update.err" >&2
  fail "valid signed database update succeeds"
}
for name in \
  omarchy.db omarchy.db.tar.zst omarchy.files omarchy.files.tar.zst \
  omarchy.db.sig omarchy.db.tar.zst.sig omarchy.files.sig omarchy.files.tar.zst.sig; do
  [[ -L $repo_dir/$name && -s $repo_dir/$name ]] || fail "canonical signed set contains $name"
done
[[ ! -e $repo_dir/.omarchy-db-transaction && ! -L $repo_dir/.omarchy-db-transaction ]] ||
  fail "successful activation clears its transaction marker"
GNUPGHOME="$public_home" gpg --batch --verify "$repo_dir/omarchy.db.sig" "$repo_dir/omarchy.db" >/dev/null 2>&1 ||
  fail "canonical database signature verifies with real GPG"
GNUPGHOME="$public_home" gpg --batch --verify "$repo_dir/omarchy.files.sig" "$repo_dir/omarchy.files" >/dev/null 2>&1 ||
  fail "canonical files signature verifies with real GPG"
pass "real GPG signs and verifies the complete canonical database set"

printf 'tampered\n' >> "$repo_dir/example-1.0-1-any.pkg.tar.zst"
: > "$docker_log"
if run_update; then
  fail "tampered signed package unexpectedly enters a repository database"
fi
[[ ! -s $docker_log ]] || fail "tampered package reaches Docker"
printf 'package fixture\n' > "$repo_dir/example-1.0-1-any.pkg.tar.zst"
pass "every package signature is verified before Docker and database signing"

GNUPGHOME="$foreign_home" gpg --batch --yes --pinentry-mode loopback --passphrase "$passphrase" \
  --local-user "$foreign_fingerprint!" \
  --output "$repo_dir/example-1.0-1-any.pkg.tar.zst.sig" \
  --detach-sign "$repo_dir/example-1.0-1-any.pkg.tar.zst"
: > "$docker_log"
if run_update; then
  fail "package signature from a foreign signer unexpectedly enters the database"
fi
[[ ! -s $docker_log ]] || fail "foreign package signer reaches Docker"
GNUPGHOME="$private_home" gpg --batch --yes --pinentry-mode loopback --passphrase "$passphrase" \
  --local-user "$fingerprint!" --output "$repo_dir/example-1.0-1-any.pkg.tar.zst.sig" \
  --detach-sign "$repo_dir/example-1.0-1-any.pkg.tar.zst"
pass "package signatures must match the configured signer exactly"

original_db_target=$(readlink "$repo_dir/omarchy.db")
: > "$docker_log"
if TEST_FINGERPRINT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA run_update; then
  fail "foreign configured fingerprint unexpectedly succeeds"
fi
[[ ! -s $docker_log ]] || fail "credential mismatch reaches Docker"
[[ $(readlink "$repo_dir/omarchy.db") == "$original_db_target" ]] ||
  fail "credential mismatch changes the published database"
pass "wrong fingerprint fails before Docker and published-tree mutation"

: > "$docker_log"
if TEST_DOCKER_RUN_FAIL=1 run_update; then
  fail "failed staged database build unexpectedly succeeds"
fi
[[ $(readlink "$repo_dir/omarchy.db") == "$original_db_target" ]] ||
  fail "failed Docker build replaces the published database"
[[ -z $(find "$repo_dir" -maxdepth 1 -type d -name '.omarchy-db-stage.*' -print -quit) ]] ||
  fail "failed Docker build leaves a staging directory"
pass "failed staging preserves the complete published generation"

: > "$docker_log"
if TEST_PASSPHRASE=incorrect run_update; then
  fail "failed database signing unexpectedly succeeds"
fi
[[ $(readlink "$repo_dir/omarchy.db") == "$original_db_target" ]] ||
  fail "failed signing replaces the published database"
[[ ! -e $repo_dir/.omarchy-db-transaction ]] || fail "failed signing creates a transaction marker"
pass "failed signing preserves the complete published generation"

source_generation=${original_db_target#*.omarchy-db-generations/}
source_generation=${source_generation%%/*}
recovery_generation=generation-recovery-fixture
cp -R "$repo_dir/.omarchy-db-generations/$source_generation" \
  "$repo_dir/.omarchy-db-generations/$recovery_generation"
printf '%s\n' "$recovery_generation" > "$repo_dir/.omarchy-db-transaction"
ln -sfn .omarchy-db-generations/missing/omarchy.db "$repo_dir/omarchy.db"
if TEST_DOCKER_RUN_FAIL=1 run_update; then
  fail "recovery fixture should fail later at Docker"
fi
[[ $(readlink "$repo_dir/omarchy.db") == ".omarchy-db-generations/$recovery_generation/omarchy.db" ]] ||
  fail "pending signed generation was not recovered before Docker"
[[ ! -e $repo_dir/.omarchy-db-transaction ]] || fail "successful recovery leaves its marker"
pass "an interrupted canonical activation is recoverable and fail-closed"

printf '%s\n%s\n' "$recovery_generation" injected > "$repo_dir/.omarchy-db-transaction"
: > "$docker_log"
if run_update; then
  fail "malformed transaction marker unexpectedly succeeds"
fi
[[ ! -s $docker_log ]] || fail "malformed transaction marker reaches Docker"
rm -f "$repo_dir/.omarchy-db-transaction"
pass "transaction marker schema fails closed before Docker"

for verifier in "$ROOT/bin/update-repo" "$ROOT/helpers/repository-signature-helpers.sh"; do
  for rejected_status in \
    BADSIG ERRSIG EXPSIG EXPKEYSIG REVKEYSIG NO_PUBKEY KEYEXPIRED SIGEXPIRED; do
    grep -Fq "$rejected_status" "$verifier" ||
      fail "${verifier##*/} does not explicitly reject $rejected_status"
  done
  grep -Fq '~ /^[erd]$/' "$verifier" ||
    fail "${verifier##*/} does not reject invalid key records"
  grep -Fq '~ /D/' "$verifier" ||
    fail "${verifier##*/} does not reject disabled key records"
done
grep -Fq 'repository-signature-helpers.sh' "$ROOT/bin/sync-repo" ||
  fail "sync-repo does not use the shared repository signature verifier"
pass "signature status and key-record validity are explicitly fail-closed"

# The container-side selector is exercised on Bash 4+ hosts with deterministic
# bsdtar/vercmp/repo-add boundaries. macOS Bash 3.2 reports an explicit skip.
bash_major=${BASH_VERSINFO[0]}
if (( bash_major < 4 )); then
  printf 'SKIP: container repository builder tests require Bash 4+\n'
else
  builder_root="$work/builder-fixture"
  mkdir -p "$builder_root/repository" "$builder_root/staging" "$work/builder-stubs"
  for package in foo-1.0-1-any.pkg.tar.zst foo-2.0-1-any.pkg.tar.zst bar-1.0-1-any.pkg.tar.zst; do
    printf '%s\n' "$package" > "$builder_root/repository/$package"
    printf 'sig\n' > "$builder_root/repository/$package.sig"
  done
  cat > "$work/builder-stubs/bsdtar" <<'STUB'
#!/bin/bash
file=$2
base=${file##*/}
name=${base%%-*}
version=${base#*-}
version=${version%-any.pkg.tar.zst}
printf 'pkgname = %s\npkgver = %s\n' "$name" "$version"
STUB
  cat > "$work/builder-stubs/vercmp" <<'STUB'
#!/bin/bash
[[ $1 == "$2" ]] && { echo 0; exit; }
[[ $1 == 2.0-1 ]] && echo 1 || echo -1
STUB
  cat > "$work/builder-stubs/repo-add" <<'STUB'
#!/bin/bash
database=$1
shift
printf '%s\n' "$@" > "$TEST_REPO_ADD_LOG"
printf 'database\n' > "$database"
printf 'files\n' > "${database/.db.tar.zst/.files.tar.zst}"
STUB
  chmod +x "$work/builder-stubs"/*
  TEST_REPO_ADD_LOG="$work/repo-add.log" PATH="$work/builder-stubs:$PATH" \
    REPOSITORY_DIR="$builder_root/repository" STAGING_DIR="$builder_root/staging" \
    bash "$ROOT/build/update-repo.sh" >/dev/null
  grep -Fq 'foo-2.0-1-any.pkg.tar.zst' "$work/repo-add.log" || fail "latest package is selected"
  ! grep -Fq 'foo-1.0-1-any.pkg.tar.zst' "$work/repo-add.log" || fail "stale package enters database"
  [[ -s $builder_root/staging/omarchy.db.tar.zst && -s $builder_root/staging/omarchy.files.tar.zst ]] ||
    fail "container builder does not produce both indexes"
  pass "container builder stages only the latest signed package versions"
fi
