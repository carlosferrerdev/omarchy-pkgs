# Gomarchy package trust validation and ephemeral keyring input generation.

validate_pkgs_db_base() { # validate_pkgs_db_base <base-url>
  local base_url="$1" authority host normalized_host

  if [[ ! "$base_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    echo "OMARCHY_PKGS_DB_BASE must be an explicit Gomarchy-owned HTTPS base URL" >&2
    return 1
  fi
  if [[ "$base_url" == */ ]]; then
    echo "OMARCHY_PKGS_DB_BASE must not end with a slash" >&2
    return 1
  fi

  authority=${base_url#https://}
  authority=${authority%%/*}
  host=${authority%%:*}
  normalized_host=$(tr '[:upper:]' '[:lower:]' <<<"$host") || return 1
  normalized_host=${normalized_host%.}
  if [[ ! "$normalized_host" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "OMARCHY_PKGS_DB_BASE must contain a valid fully qualified host name" >&2
    return 1
  fi
  case "$normalized_host" in
  omarchy.org | *.omarchy.org)
    echo "Refusing an upstream Omarchy package database: $base_url" >&2
    return 1
    ;;
  esac
}

normalize_trust_fingerprint() { # normalize_trust_fingerprint <fingerprint>
  local fingerprint="$1" normalized

  if [[ ! "$fingerprint" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    echo "OMARCHY_PKGS_TRUST_KEY_FINGERPRINT must be a full 40-hex primary fingerprint" >&2
    return 1
  fi
  normalized=$(tr '[:lower:]' '[:upper:]' <<<"$fingerprint") || return 1
  if [[ "$normalized" == "40DFB630FF42BCFFB047046CF0134EE680CAC571" ]]; then
    echo "Refusing the upstream Omarchy package trust root" >&2
    return 1
  fi
  printf '%s\n' "$normalized"
}

inspect_trust_public_key() { # inspect_trust_public_key <absolute-file> <primary-fingerprint>
  local public_key_file="$1" expected_fingerprint="$2" inspection secret_count inspection_home
  local primary_fingerprints primary_count primary_unsafe_count key_identities

  if [[ "$public_key_file" != /* || ! -f "$public_key_file" || -L "$public_key_file" ]]; then
    echo "OMARCHY_PKGS_SIGNING_PUBLIC_KEY_FILE must be an absolute regular non-symlink file" >&2
    return 1
  fi
  command -v gpg >/dev/null 2>&1 || {
    echo "gpg is required to validate the Gomarchy package trust root" >&2
    return 1
  }

  inspection_home=$(mktemp -d) || return 1
  chmod 0700 "$inspection_home"
  inspection=$(gpg --batch --no-options --homedir "$inspection_home" --show-keys \
    --with-colons --fingerprint --fingerprint "$public_key_file" 2>/dev/null) || {
    rm -rf -- "$inspection_home"
    echo "The configured signing public-key file is not valid OpenPGP public material" >&2
    return 1
  }
  rm -rf -- "$inspection_home"
  secret_count=$(awk -F: '$1 == "sec" { count++ } END { print count + 0 }' <<<"$inspection")
  if ((secret_count > 0)); then
    echo "The signing public-key file must not contain secret key material" >&2
    return 1
  fi

  key_identities=$(awk -F: '
    $1 == "pub" || $1 == "sub" { type=$1; validity=$2; capabilities=$12; next }
    type != "" && $1 == "fpr" {
      print type ":" toupper($10) ":" validity ":" capabilities
      type=""
    }
  ' <<<"$inspection")
  primary_fingerprints=$(awk -F: '$1 == "pub" { print $2 }' <<<"$key_identities")
  primary_unsafe_count=$(awk -F: '$1 == "pub" && ($3 ~ /^[erd]$/ || $4 ~ /D/) { count++ } END { print count + 0 }' <<<"$key_identities")
  primary_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$primary_fingerprints")
  if ((primary_count != 1)); then
    echo "The signing public-key file must contain exactly one public primary key" >&2
    return 1
  fi
  if [[ "$primary_fingerprints" != "$expected_fingerprint" ]]; then
    echo "Signing public-key primary fingerprint does not match OMARCHY_PKGS_TRUST_KEY_FINGERPRINT" >&2
    return 1
  fi
  if ((primary_unsafe_count != 0)); then
    echo "Signing public-key primary trust root is revoked, expired, or disabled" >&2
    return 1
  fi
}

prepare_keyring_inputs() { # prepare_keyring_inputs <package-dir> <base-url> <fingerprint> <public-key-file>
  local package_dir="$1" base_url="$2" fingerprint="$3" public_key_file="$4"
  local gpg_home="$package_dir/.gnupg"

  mkdir -m 700 "$gpg_home"
  gpg --batch --no-options --homedir "$gpg_home" --import "$public_key_file" >/dev/null 2>&1
  if ! gpg --batch --no-options --homedir "$gpg_home" --export "$fingerprint" >"$package_dir/omarchy.gpg"; then
    echo "Failed to export the validated Gomarchy package trust root" >&2
    return 1
  fi
  [[ -s "$package_dir/omarchy.gpg" ]] || {
    echo "The generated Gomarchy package keyring is empty" >&2
    return 1
  }

  printf '%s:4:\n' "$fingerprint" >"$package_dir/omarchy-trusted"
  printf 'schema=1\nbase_url=%s\ntrust_fingerprint=%s\n' \
    "$base_url" "$fingerprint" >"$package_dir/repository.conf"
  chmod 0644 "$package_dir/omarchy.gpg" "$package_dir/omarchy-trusted" "$package_dir/repository.conf"
  rm -rf -- "$gpg_home"
}
