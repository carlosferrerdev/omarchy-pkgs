#!/bin/bash
# Adversarial publication tests for the signed repository database set.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}
# Keep the path below gpg-agent's Unix-domain socket limit on macOS.
work=$(mktemp -d "$TMP_BASE/gsp.XXXXXX")
passphrase=gomarchy-sync-test

cleanup() {
  rm -rf -- "$work"
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

generate_key() { # generate_key <homedir> <identity> [usage]
  local home="$1" identity="$2" usage="${3:-sign}"
  mkdir -m 0700 "$home"
  GNUPGHOME="$home" gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
    --quick-generate-key "$identity" rsa2048 "$usage" 0 >/dev/null 2>&1
  GNUPGHOME="$home" gpg --batch --with-colons --fingerprint --list-secret-keys |
    awk -F: '$1 == "sec" { want = 1; next } want && $1 == "fpr" { print toupper($10); exit }'
}

sign_file() { # sign_file <homedir> <fingerprint> <artifact> <signature>
  GNUPGHOME="$1" gpg --batch --yes --pinentry-mode loopback --passphrase "$passphrase" \
    --local-user "$2!" --output "$4" --detach-sign "$3"
}

create_package() { # create_package <destination> <name> <version>
  local destination="$1" name="$2" version="$3"
  local package_root="$work/package-tree-$name"

  mkdir -p "$package_root"
  printf 'pkgname = %s\npkgver = %s\n' "$name" "$version" >"$package_root/.PKGINFO"
  bsdtar -cf "$destination" -C "$package_root" .PKGINFO
}

create_database() { # create_database <destination> <name> <version> <filename>
  local destination="$1" name="$2" version="$3" filename="$4"
  local database_root="$work/database-tree-${destination##*/}"

  rm -rf -- "$database_root"
  mkdir -p "$database_root/$name-$version"
  printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n' \
    "$filename" "$name" "$version" >"$database_root/$name-$version/desc"
  bsdtar -cf "$destination" -C "$database_root" .
}

signer_home="$work/signer"
foreign_home="$work/foreign"
trust_fingerprint=$(generate_key "$signer_home" 'Gomarchy Sync Test <sync-test@gomarchy.invalid>' cert)
GNUPGHOME="$signer_home" gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
  --quick-add-key "$trust_fingerprint" rsa2048 sign 0 >/dev/null 2>&1
GNUPGHOME="$signer_home" gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
  --quick-add-key "$trust_fingerprint" rsa2048 sign 0 >/dev/null 2>&1
fingerprint=$(GNUPGHOME="$signer_home" gpg --batch --with-colons --fingerprint \
  --list-secret-keys | awk -F: '$1 == "ssb" { want = 1; next } want && $1 == "fpr" { print toupper($10); exit }')
foreign_fingerprint=$(generate_key "$foreign_home" 'Foreign Sync Test <foreign-test@gomarchy.invalid>')
[[ $trust_fingerprint =~ ^[[:xdigit:]]{40}$ ]] || fail "generated trust fingerprint is invalid"
[[ $fingerprint =~ ^[[:xdigit:]]{40}$ ]] || fail "generated signing fingerprint is invalid"
[[ $foreign_fingerprint =~ ^[[:xdigit:]]{40}$ ]] || fail "generated foreign fingerprint is invalid"
GNUPGHOME="$signer_home" gpg --batch --armor --export "$trust_fingerprint" > "$work/public.asc"

repo_root="$work/repository"
repo_dir="$repo_root/edge/x86_64"
generation_name=generation-test
generation_dir="$repo_dir/.omarchy-db-generations/$generation_name"
mkdir -p "$generation_dir" "$work/stubs"
create_package "$repo_dir/example-1.0-1-any.pkg.tar.zst" example 1.0-1
sign_file "$signer_home" "$fingerprint" "$repo_dir/example-1.0-1-any.pkg.tar.zst" \
  "$repo_dir/example-1.0-1-any.pkg.tar.zst.sig"
create_database "$generation_dir/omarchy.db.tar.zst" example 1.0-1 \
  example-1.0-1-any.pkg.tar.zst
create_database "$generation_dir/omarchy.files.tar.zst" example 1.0-1 \
  example-1.0-1-any.pkg.tar.zst
sign_file "$signer_home" "$fingerprint" "$generation_dir/omarchy.db.tar.zst" \
  "$generation_dir/omarchy.db.tar.zst.sig"
sign_file "$signer_home" "$fingerprint" "$generation_dir/omarchy.files.tar.zst" \
  "$generation_dir/omarchy.files.tar.zst.sig"
ln -s omarchy.db.tar.zst "$generation_dir/omarchy.db"
ln -s omarchy.db.tar.zst.sig "$generation_dir/omarchy.db.sig"
ln -s omarchy.files.tar.zst "$generation_dir/omarchy.files"
ln -s omarchy.files.tar.zst.sig "$generation_dir/omarchy.files.sig"

canonical_names=(
  omarchy.db omarchy.db.tar.zst omarchy.files omarchy.files.tar.zst
  omarchy.db.sig omarchy.db.tar.zst.sig omarchy.files.sig omarchy.files.tar.zst.sig
)
for name in "${canonical_names[@]}"; do
  ln -s ".omarchy-db-generations/$generation_name/$name" "$repo_dir/$name"
done

rclone_log="$work/rclone.log"
: > "$rclone_log"
cat > "$work/stubs/rclone" <<'STUB'
#!/bin/bash
command=${1:-}
printf '%s' "$command" >> "$TEST_RCLONE_LOG"
shift || true
for argument in "$@"; do
  printf '\t%s' "$argument" >> "$TEST_RCLONE_LOG"
  [[ $argument != --copy-links ]] || exit 72
done
printf '\n' >> "$TEST_RCLONE_LOG"
if [[ $command == lsf ]]; then
  # A missing channel is the safe first-publication case accepted by sync-repo.
  if [[ -z ${TEST_REMOTE_DB_DIR:-} ]]; then
    exit 3
  fi
  printf 'omarchy.db\nomarchy.db.sig\n'
  exit 0
fi
if [[ $command == cat && -n ${TEST_REMOTE_DB_DIR:-} ]]; then
  source_path=${1##*/}
  cat "$TEST_REMOTE_DB_DIR/$source_path"
  exit 0
fi
if [[ $command == copy || $command == sync ]]; then
  has_checksum=false
  for argument in "$@"; do
    [[ $argument != --ignore-existing ]] || exit 73
    [[ $argument != --checksum ]] || has_checksum=true
  done
  [[ $has_checksum == true ]] || exit 74
  [[ -z ${TEST_REMOTE_PACKAGE_STATE_FILE:-} ]] ||
    printf 'repaired\n' > "$TEST_REMOTE_PACKAGE_STATE_FILE"
fi
if [[ $command == copyto && -n ${TEST_RCLONE_FAIL_BASENAME:-} &&
  ${2##*/} == "$TEST_RCLONE_FAIL_BASENAME" ]]; then
  exit 70
fi
exit 0
STUB
cat > "$work/stubs/flock" <<'STUB'
#!/bin/bash
if [[ ${TEST_MUTATE_ON_LOCK:-0} == 1 ]]; then
  printf 'changed while waiting for lock\n' >> "$TEST_MUTATE_FILE"
fi
exit 0
STUB
chmod +x "$work/stubs/rclone" "$work/stubs/flock"

run_sync() {
  local extra_arg=""
  [[ ${TEST_PRUNE:-0} != 1 ]] || extra_arg=--prune
  PATH="$work/stubs:$PATH" \
    TEST_RCLONE_LOG="$rclone_log" \
    OMARCHY_REPO_ROOT="$repo_root" \
    OMARCHY_PKGS_RCLONE_DEST='GomarchyTest:packages' \
    OMARCHY_PKGS_SIGNING_PUBLIC_KEY_FILE="$work/public.asc" \
    OMARCHY_PKGS_TRUST_KEY_FINGERPRINT="$trust_fingerprint" \
    OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT="$fingerprint" \
    TEST_RCLONE_FAIL_BASENAME="${TEST_RCLONE_FAIL_BASENAME:-}" \
    TEST_MUTATE_ON_LOCK="${TEST_MUTATE_ON_LOCK:-0}" \
    TEST_MUTATE_FILE="$generation_dir/omarchy.files.tar.zst" \
    TEST_REMOTE_PACKAGE_STATE_FILE="$work/remote-package.state" \
    TEST_REMOTE_DB_DIR="${TEST_REMOTE_DB_DIR:-}" \
    "$ROOT/bin/sync-repo" --mirror edge --arch x86_64 --skip-prod-check \
      ${extra_arg:+"$extra_arg"} \
      > "$work/sync.out" 2> "$work/sync.err"
}

rm "$repo_dir/omarchy.files.sig"
: > "$rclone_log"
if run_sync; then
  fail "partial canonical database set unexpectedly publishes"
fi
[[ ! -s $rclone_log ]] || fail "partial canonical set reaches rclone"
ln -s ".omarchy-db-generations/$generation_name/omarchy.files.sig" \
  "$repo_dir/omarchy.files.sig"
pass "partial canonical set fails before the first remote operation"

rm "$generation_dir/omarchy.files.tar.zst.sig"
sign_file "$foreign_home" "$foreign_fingerprint" "$generation_dir/omarchy.files.tar.zst" \
  "$generation_dir/omarchy.files.tar.zst.sig"
: > "$rclone_log"
if run_sync; then
  fail "database signature from a foreign signer unexpectedly publishes"
fi
[[ ! -s $rclone_log ]] || fail "foreign database signature reaches rclone"
rm "$generation_dir/omarchy.files.tar.zst.sig"
sign_file "$signer_home" "$fingerprint" "$generation_dir/omarchy.files.tar.zst" \
  "$generation_dir/omarchy.files.tar.zst.sig"
pass "foreign database signer fails before the first remote operation"

: > "$rclone_log"
if TEST_MUTATE_ON_LOCK=1 run_sync; then
  fail "generation changed while waiting for the release lock unexpectedly publishes"
fi
[[ ! -s $rclone_log ]] || fail "generation changed at lock acquisition reaches rclone"
create_database "$generation_dir/omarchy.files.tar.zst" example 1.0-1 \
  example-1.0-1-any.pkg.tar.zst
rm "$generation_dir/omarchy.files.tar.zst.sig"
sign_file "$signer_home" "$fingerprint" "$generation_dir/omarchy.files.tar.zst" \
  "$generation_dir/omarchy.files.tar.zst.sig"
pass "database generation is revalidated under the release lock"

package_file="$repo_dir/example-1.0-1-any.pkg.tar.zst"
mv "$package_file" "$work/package-target"
ln -s "$work/package-target" "$package_file"
: > "$rclone_log"
if run_sync; then
  fail "symlink package unexpectedly publishes"
fi
[[ ! -s $rclone_log ]] || fail "symlink package reaches rclone"
rm "$package_file"
mv "$work/package-target" "$package_file"
pass "package symlinks fail before the first remote operation"

create_package "$repo_dir/unindexed-1.0-1-any.pkg.tar.zst" unindexed 1.0-1
sign_file "$signer_home" "$fingerprint" "$repo_dir/unindexed-1.0-1-any.pkg.tar.zst" \
  "$repo_dir/unindexed-1.0-1-any.pkg.tar.zst.sig"
: > "$rclone_log"
if run_sync; then
  fail "signed local package omitted from the database unexpectedly publishes"
fi
[[ ! -s $rclone_log ]] || fail "incomplete local database inventory reaches rclone"
rm "$repo_dir/unindexed-1.0-1-any.pkg.tar.zst" \
  "$repo_dir/unindexed-1.0-1-any.pkg.tar.zst.sig"
pass "database inventory must cover every signed local package name"

remote_db_dir="$work/remote-db"
remote_db_tree="$work/remote-db-tree"
mkdir -p "$remote_db_dir" "$remote_db_tree/example-1.0-1"
printf '%%NAME%%\nexample\n' > "$remote_db_tree/example-1.0-1/desc"
tar -czf "$remote_db_dir/omarchy.db" -C "$remote_db_tree" .
sign_file "$foreign_home" "$foreign_fingerprint" "$remote_db_dir/omarchy.db" \
  "$remote_db_dir/omarchy.db.sig"
: > "$rclone_log"
if TEST_REMOTE_DB_DIR="$remote_db_dir" run_sync; then
  fail "foreign-signed remote database unexpectedly influences publication"
fi
! grep -Eq '^(copy|sync|copyto)' "$rclone_log" ||
  fail "foreign-signed remote database reaches a mutating rclone command"
pass "remote shrink guard accepts only the configured exact database signer"

: > "$rclone_log"
printf 'corrupt\n' > "$work/remote-package.state"
run_sync || {
  sed 's/^/  /' "$work/sync.err" >&2
  fail "valid signed database set publishes"
}
[[ $(<"$work/remote-package.state") == repaired ]] ||
  fail "additive sync preserves a corrupted remote package"
actual_order=$(awk -F '\t' '$1 == "copyto" { destination = $3; sub(".*/", "", destination); print destination }' \
  "$rclone_log")
expected_order=$(printf '%s\n' \
  omarchy.files.tar.zst.sig omarchy.files.sig \
  omarchy.files.tar.zst omarchy.files \
  omarchy.db.tar.zst.sig omarchy.db.sig \
  omarchy.db.tar.zst omarchy.db)
[[ $actual_order == "$expected_order" ]] || {
  printf 'expected publication order:\n%s\nactual publication order:\n%s\n' \
    "$expected_order" "$actual_order" >&2
  fail "database publication order is unsafe"
}
[[ $(tail -1 "$rclone_log" | cut -f1,3) == $'copyto\tGomarchyTest:packages/edge/x86_64/omarchy.db' ]] ||
  fail "omarchy.db is not the final remote mutation"
pass "all signatures precede their artifacts and omarchy.db publishes last"

: > "$rclone_log"
printf 'corrupt\n' > "$work/remote-package.state"
TEST_PRUNE=1 run_sync || fail "checksum repair in prune mode succeeds"
[[ $(<"$work/remote-package.state") == repaired ]] ||
  fail "prune sync preserves a corrupted remote package"
grep -q '^sync' "$rclone_log" || fail "prune mode does not use remote sync"
pass "checksum repair is enforced in additive and prune modes"

: > "$rclone_log"
if TEST_RCLONE_FAIL_BASENAME=omarchy.db.sig run_sync; then
  fail "failed database signature upload unexpectedly reports success"
fi
! grep -Fq $'\tGomarchyTest:packages/edge/x86_64/omarchy.db.tar.zst\t' "$rclone_log" ||
  fail "publication continues after a database signature upload failure"
! grep -Fq $'\tGomarchyTest:packages/edge/x86_64/omarchy.db\t' "$rclone_log" ||
  fail "entry-point database publishes after a signature upload failure"
pass "remote failure blocks later database artifacts and the entry point"
