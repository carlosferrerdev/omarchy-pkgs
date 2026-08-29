# Shared fail-closed publication destination handling.

package_publish_destination() { # package_publish_destination [explicit-destination]
  local destination="${1:-${OMARCHY_PKGS_RCLONE_DEST:-}}" normalized
  if [[ -z "$destination" ]]; then
    print_error "OMARCHY_PKGS_RCLONE_DEST is required before publishing packages" >&2
    print_error "Refusing to inherit the Omarchy production bucket" >&2
    return 1
  fi
  if [[ ! "$destination" =~ ^[A-Za-z0-9._-]+:[A-Za-z0-9._~/-]+$ ]]; then
    print_error "Invalid package rclone destination: $destination" >&2
    print_error "Expected an explicit remote path such as Gomarchy:packages" >&2
    return 1
  fi
  normalized=$(tr '[:upper:]' '[:lower:]' <<<"$destination") || return 1
  if [[ "$normalized" == pkgs.omarchy.org:* ]]; then
    print_error "Refusing the upstream Omarchy package destination: $destination" >&2
    return 1
  fi
  printf '%s\n' "$destination"
}

confirm_package_publication() { # confirm_package_publication <destination> [scope]
  local destination="$1" scope="${2:-packages}" reply
  print_warning "You are about to publish $scope to $destination"
  if ! read -r -p "Publish to this destination? (y/N) " reply; then
    return 3
  fi
  [[ "$reply" =~ ^[Yy]$ ]] || return 3
}

iso_publish_destination() { # iso_publish_destination <destination>
  local destination="$1" normalized
  if [[ ! "$destination" =~ ^[A-Za-z0-9._-]+:[A-Za-z0-9._~/-]+$ ]]; then
    print_error "Invalid Gomarchy ISO rclone destination: $destination" >&2
    return 1
  fi
  normalized=$(tr '[:upper:]' '[:lower:]' <<<"$destination") || return 1
  case "$normalized" in
  omarchy:omarchy | omarchy:omarchy/* | omarchy:iso.omarchy.org | omarchy:iso.omarchy.org/*)
    print_error "Refusing the upstream Omarchy ISO destination: $destination" >&2
    return 1
    ;;
  esac
  printf '%s\n' "$destination"
}

preflight_package_destination() { # preflight_package_destination <destination>
  local destination="$1" listing status=0
  command -v rclone >/dev/null 2>&1 || {
    print_error "rclone is required before publishing packages" >&2
    return 1
  }
  listing=$(rclone lsf "$destination" --files-only --max-depth 1 2>&1) || status=$?
  case "$status" in
  0) return 0 ;;
  3)
    # rclone uses 3 for a missing directory. A new channel prefix may not exist
    # yet; reaching the configured remote is enough for a first publication.
    return 0
    ;;
  *)
    print_error "Cannot read the configured package destination: $destination" >&2
    [[ -n "$listing" ]] && printf '%s\n' "$listing" >&2
    return "$status"
    ;;
  esac
}

credentials_file_exports() { # credentials_file_exports <file> <variable...>
  local credentials_file="$1"
  shift
  env -i PATH="$PATH" HOME="${HOME:-/root}" /bin/bash -c '
    set -e
    credentials_file=$1
    shift
    source "$credentials_file"
    exported=$(compgen -e)
    for name in "$@"; do
      [[ -n ${!name:-} ]]
      grep -Fxq "$name" <<<"$exported"
    done
  ' _ "$credentials_file" "$@"
}
