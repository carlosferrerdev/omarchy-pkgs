#!/bin/bash
# Sign packages in build-output using an isolated temporary GPG home.

set -euo pipefail

ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/build-output/$MIRROR/$ARCH}"
GPG_PRIVATE_KEY_FILE=${GPG_PRIVATE_KEY_FILE:-/run/secrets/gomarchy-signing-private-key}
GPG_PASSPHRASE_FILE=${GPG_PASSPHRASE_FILE:-/run/secrets/gomarchy-signing-passphrase}

SIGNING_GNUPGHOME=""

cleanup() {
  if [[ -n "$SIGNING_GNUPGHOME" && -d "$SIGNING_GNUPGHOME" ]]; then
    gpgconf --homedir "$SIGNING_GNUPGHOME" --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf -- "$SIGNING_GNUPGHOME"
  fi
}

verify_exact_signature() {
  local package_file="$1"
  local signature_file="$2"
  local status

  status=$(gpg --batch --no-auto-key-retrieve --homedir "$SIGNING_GNUPGHOME" --status-fd 1 \
    --verify "$signature_file" "$package_file" 2>/dev/null) || return 1

  awk -v wanted="$SIGNING_FINGERPRINT" '
    $1 == "[GNUPG:]" && $2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY|KEYEXPIRED|SIGEXPIRED)$/ {
      unsafe++
    }
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      valid++
      if (toupper($3) == wanted) exact++
    }
    END { exit !(valid == 1 && exact == 1 && unsafe == 0) }
  ' <<<"$status"
}

echo "==> Package Signing"
echo "==> Target architecture: $ARCH"
echo "==> Mirror: $MIRROR"
echo "==> Build output: $BUILD_OUTPUT_DIR"

# Require secret files rather than placing either secret in process environment
# values.
if [[ ! -f $GPG_PRIVATE_KEY_FILE || -L $GPG_PRIVATE_KEY_FILE || ! -r $GPG_PRIVATE_KEY_FILE ]]; then
  echo "ERROR: signing private key was not mounted as a readable regular file"
  exit 1
fi

if [[ ! -f $GPG_PASSPHRASE_FILE || -L $GPG_PASSPHRASE_FILE || ! -r $GPG_PASSPHRASE_FILE ]]; then
  echo "ERROR: signing passphrase was not mounted as a readable regular file"
  exit 1
fi

if [[ ! "${OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT:-}" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "ERROR: OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT must be a full 40-character hexadecimal fingerprint"
  exit 1
fi

SIGNING_FINGERPRINT=$(printf '%s' "$OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT" | tr '[:lower:]' '[:upper:]')
SIGNING_GNUPGHOME=$(mktemp -d)
chmod 700 "$SIGNING_GNUPGHOME"
trap cleanup EXIT

# Import the supplied private material into a process-local keyring.
echo "==> Importing configured GPG signing key into isolated keyring..."
gpg --batch --homedir "$SIGNING_GNUPGHOME" --import "$GPG_PRIVATE_KEY_FILE" >/dev/null 2>&1 || {
  echo "ERROR: Failed to import signing key"
  exit 1
}

# Match the complete primary-key or subkey fingerprint and require an exact
# signing-capable secret-key record. Extra imported keys never affect selection.
if ! KEY_RECORD=$(
  gpg --batch --homedir "$SIGNING_GNUPGHOME" --with-colons --fingerprint --fingerprint \
    --list-secret-keys 2>/dev/null |
    awk -F: -v wanted="$SIGNING_FINGERPRINT" '
      $1 == "sec" || $1 == "ssb" { type=$1; validity=$2; capabilities=$12; next }
      $1 == "fpr" && toupper($10) == wanted {
        matches++
        matched_type=type
        matched_validity=validity
        matched_capabilities=capabilities
      }
      END {
        if (matches != 1 || matched_validity ~ /^[erd]$/ ||
            matched_capabilities !~ /[sS]/ || matched_capabilities ~ /D/) exit 1
        print matched_type ":" matched_capabilities
      }
    '
); then
  echo "ERROR: Configured fingerprint does not identify exactly one signing-capable secret key or subkey"
  exit 1
fi

echo "  ✓ Exact GPG ${KEY_RECORD%%:*} fingerprint loaded: $SIGNING_FINGERPRINT"

# Check if build output exists and has packages
if [[ ! -d "$BUILD_OUTPUT_DIR" ]]; then
  echo "ERROR: Build output directory not found: $BUILD_OUTPUT_DIR"
  exit 1
fi

cd "$BUILD_OUTPUT_DIR"

# Find all package files without lossy whitespace splitting.
shopt -s nullglob
PACKAGE_FILES=("$BUILD_OUTPUT_DIR"/*.pkg.tar.zst)
shopt -u nullglob

if [[ ${#PACKAGE_FILES[@]} -eq 0 ]]; then
  echo "==> No packages found to sign"
  exit 0
fi

PACKAGE_COUNT=${#PACKAGE_FILES[@]}
echo "==> Found $PACKAGE_COUNT package(s) to sign"
echo ""

# Sign all packages
SIGNED_COUNT=0
FAILED_COUNT=0

for pkg_file in "${PACKAGE_FILES[@]}"; do
  pkg_name=${pkg_file##*/}
  signature_file="$pkg_file.sig"
  signature_tmp=$(mktemp "$BUILD_OUTPUT_DIR/.${pkg_name}.sig.XXXXXX")

  echo -n "  -> $pkg_name ... "

  # Force exact-key selection, then verify before atomically replacing any
  # previous valid signature. A failed retry must not destroy recovery state.
  if gpg --batch --yes --homedir "$SIGNING_GNUPGHOME" --pinentry-mode loopback \
    --passphrase-file "$GPG_PASSPHRASE_FILE" --detach-sign --no-armor \
    --local-user "$SIGNING_FINGERPRINT!" --output "$signature_tmp" "$pkg_file" \
    2>/dev/null &&
    verify_exact_signature "$pkg_file" "$signature_tmp"; then
    chmod 0644 "$signature_tmp"
    mv -f -- "$signature_tmp" "$signature_file"
    echo "✓"
    SIGNED_COUNT=$((SIGNED_COUNT + 1))
  else
    rm -f -- "$signature_tmp"
    echo "✗"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done

echo ""

# Summary
if [[ $FAILED_COUNT -eq 0 ]]; then
  echo "==> Successfully signed all $SIGNED_COUNT package(s)"
  exit 0
else
  echo "==> Signed $SIGNED_COUNT package(s), failed $FAILED_COUNT"
  exit 1
fi
