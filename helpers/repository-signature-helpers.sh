# Verification helpers for signed Gomarchy package repository artifacts.

repository_signature_normalize_fingerprint() { # <label> <fingerprint>
  local label="$1" fingerprint="$2" normalized

  if [[ ! $fingerprint =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "$label must be a full 40-character hexadecimal fingerprint" >&2
    return 1
  fi
  normalized=$(printf '%s' "$fingerprint" | tr '[:lower:]' '[:upper:]') || return 1
  if [[ $normalized == 40DFB630FF42BCFFB047046CF0134EE680CAC571 ]]; then
    echo "$label must not use the historical upstream Omarchy key" >&2
    return 1
  fi
  printf '%s\n' "$normalized"
}

repository_signature_prepare_keyring() { # <gnupg-home> <public-key-file> <trust-fpr> <signer-fpr>
  local gnupg_home="$1" public_key_file="$2" trust_fingerprint="$3" signing_fingerprint="$4"
  local key_listing key_identities primary_fingerprints matching_signers secret_listing
  local primary_count signer_count

  [[ $gnupg_home == /* && -d $gnupg_home && ! -L $gnupg_home ]] || {
    echo "Repository verification GnuPG home is missing or unsafe" >&2
    return 1
  }
  [[ $public_key_file == /* && -f $public_key_file && ! -L $public_key_file && -r $public_key_file ]] || {
    echo "OMARCHY_PKGS_SIGNING_PUBLIC_KEY_FILE must name an absolute readable regular non-symlink file" >&2
    return 1
  }
  command -v gpg >/dev/null 2>&1 || {
    echo "gpg is required to verify the package repository" >&2
    return 1
  }

  trust_fingerprint=$(repository_signature_normalize_fingerprint \
    OMARCHY_PKGS_TRUST_KEY_FINGERPRINT "$trust_fingerprint") || return 1
  signing_fingerprint=$(repository_signature_normalize_fingerprint \
    OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT "$signing_fingerprint") || return 1

  chmod 0700 "$gnupg_home"
  if ! gpg --batch --no-options --homedir "$gnupg_home" --import "$public_key_file" >/dev/null 2>&1; then
    echo "Could not import OMARCHY_PKGS_SIGNING_PUBLIC_KEY_FILE" >&2
    return 1
  fi
  key_listing=$(gpg --batch --no-options --homedir "$gnupg_home" --with-colons \
    --fingerprint --fingerprint --list-keys 2>/dev/null) || {
    echo "Could not inspect OMARCHY_PKGS_SIGNING_PUBLIC_KEY_FILE" >&2
    return 1
  }
  key_identities=$(printf '%s\n' "$key_listing" | awk -F: '
    $1 == "pub" || $1 == "sub" {
      key_type = $1
      validity = $2
      capabilities = $12
      next
    }
    key_type != "" && $1 == "fpr" {
      print key_type ":" toupper($10) ":" validity ":" capabilities
      key_type = ""
    }
  ')
  primary_fingerprints=$(printf '%s\n' "$key_identities" | awk -F: '
    $1 == "pub" {
      if ($3 ~ /^[erd]$/ || $4 ~ /D/) print "INVALID"
      else print $2
    }
  ')
  matching_signers=$(printf '%s\n' "$key_identities" | awk -F: -v wanted="$signing_fingerprint" '
    $2 == wanted && $3 !~ /^[erd]$/ && $4 ~ /[sS]/ && $4 !~ /D/ { print $2 }
  ')
  primary_count=$(printf '%s\n' "$primary_fingerprints" | grep -c . || true)
  signer_count=$(printf '%s\n' "$matching_signers" | grep -c . || true)
  if [[ $primary_count -ne 1 || $primary_fingerprints != "$trust_fingerprint" ]]; then
    echo "Public key must contain exactly the configured usable primary trust key" >&2
    return 1
  fi
  if [[ $signer_count -ne 1 || $matching_signers != "$signing_fingerprint" ]]; then
    echo "Public key must contain exactly the configured usable signing key" >&2
    return 1
  fi
  secret_listing=$(gpg --batch --no-options --homedir "$gnupg_home" --with-colons \
    --list-secret-keys 2>/dev/null || true)
  if printf '%s\n' "$secret_listing" | grep -q '^sec:'; then
    echo "OMARCHY_PKGS_SIGNING_PUBLIC_KEY_FILE must not contain secret key material" >&2
    return 1
  fi
}

repository_signature_verify_exact() { # <gnupg-home> <signer-fpr> <artifact> <signature>
  local gnupg_home="$1" signing_fingerprint="$2" artifact="$3" signature="$4" status

  signing_fingerprint=$(repository_signature_normalize_fingerprint \
    OMARCHY_PKGS_SIGNING_KEY_FINGERPRINT "$signing_fingerprint") || return 1
  [[ -f $artifact && ! -L $artifact && -s $artifact ]] || return 1
  [[ -f $signature && ! -L $signature && -s $signature ]] || return 1
  status=$(gpg --batch --no-options --no-auto-key-retrieve --homedir "$gnupg_home" \
    --status-fd 1 --verify "$signature" "$artifact" 2>/dev/null) || return 1
  awk -v wanted="$signing_fingerprint" '
    $1 == "[GNUPG:]" && $2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY|KEYEXPIRED|SIGEXPIRED)$/ {
      rejected++
    }
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      valid++
      if (toupper($3) == wanted) exact++
    }
    END { exit !(rejected == 0 && valid == 1 && exact == 1) }
  ' <<<"$status"
}
