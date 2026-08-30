# Host-side signing-secret validation.

validate_signing_secret_file() { # validate_signing_secret_file <path> <label>
  local path="$1" label="$2" owner mode mode_value

  if [[ $path != /* || ! -f $path || -L $path || ! -r $path || ! -s $path ]]; then
    print_error "$label must name an absolute, readable, non-empty regular non-symlink file"
    return 1
  fi

  owner=$(stat -c '%u' -- "$path" 2>/dev/null || stat -f '%u' "$path" 2>/dev/null) || {
    print_error "Could not inspect ownership for $label"
    return 1
  }
  if [[ $owner != "$(id -u)" ]]; then
    print_error "$label must be owned by the invoking user"
    return 1
  fi

  mode=$(stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null) || {
    print_error "Could not inspect permissions for $label"
    return 1
  }
  [[ $mode =~ ^[0-7]{3,4}$ ]] || {
    print_error "Could not parse permissions for $label"
    return 1
  }
  mode_value=$((8#$mode))
  if ((mode_value & 077)); then
    print_error "$label must not be readable, writable, or executable by group/other (mode: $mode)"
    return 1
  fi
}

validate_signing_secret_pair() {
  local private_key_file="${OMARCHY_PKGS_SIGNING_PRIVATE_KEY_FILE:-}"
  local passphrase_file="${OMARCHY_PKGS_SIGNING_PASSPHRASE_FILE:-}"
  local private_real passphrase_real

  validate_signing_secret_file "$private_key_file" OMARCHY_PKGS_SIGNING_PRIVATE_KEY_FILE || return 1
  validate_signing_secret_file "$passphrase_file" OMARCHY_PKGS_SIGNING_PASSPHRASE_FILE || return 1
  private_real=$(realpath "$private_key_file") || return 1
  passphrase_real=$(realpath "$passphrase_file") || return 1
  if [[ $private_real == "$passphrase_real" ]]; then
    print_error "Signing private key and passphrase must use distinct files"
    return 1
  fi
}
