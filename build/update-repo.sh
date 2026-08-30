#!/bin/bash
# Build an unsigned repository database generation inside the build container.
# The host signs and activates it only after this script succeeds.

set -euo pipefail

ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}
REPOSITORY_DIR=${REPOSITORY_DIR:-/repository}
STAGING_DIR=${STAGING_DIR:-/staging}
REPO_NAME=omarchy

case "$ARCH" in
  x86_64|aarch64) ;;
  *) echo "ERROR: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
case "$MIRROR" in
  edge|rc|stable) ;;
  *) echo "ERROR: unsupported mirror: $MIRROR" >&2; exit 1 ;;
esac
[[ -d $REPOSITORY_DIR && ! -L $REPOSITORY_DIR ]] || {
  echo "ERROR: repository directory is missing or unsafe: $REPOSITORY_DIR" >&2
  exit 1
}
[[ -d $STAGING_DIR && ! -L $STAGING_DIR ]] || {
  echo "ERROR: staging directory is missing or unsafe: $STAGING_DIR" >&2
  exit 1
}
if [[ -n $(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  echo "ERROR: staging directory is not empty: $STAGING_DIR" >&2
  exit 1
fi

get_pkg_info() {
  local package_file="$1"

  bsdtar -xOqf "$package_file" .PKGINFO 2>/dev/null | awk '
    /^pkgname = / { name = substr($0, 11) }
    /^pkgver = / { version = substr($0, 10) }
    END {
      if (name == "" || version == "") exit 1
      print name " " version
    }
  '
}

shopt -s nullglob
package_candidates=("$REPOSITORY_DIR"/*.pkg.tar.*)
shopt -u nullglob

declare -A latest_packages=()
declare -A latest_versions=()
package_count=0

for package_file in "${package_candidates[@]}"; do
  [[ $package_file == *.sig ]] && continue
  [[ -f $package_file && ! -L $package_file ]] || {
    echo "ERROR: package is not a regular non-symlink file: $package_file" >&2
    exit 1
  }
  [[ -f $package_file.sig && ! -L $package_file.sig ]] || {
    echo "ERROR: package has no regular non-symlink signature: $package_file" >&2
    exit 1
  }
  if ! read -r package_name package_version < <(get_pkg_info "$package_file"); then
    echo "ERROR: package metadata is unreadable: $package_file" >&2
    exit 1
  fi
  [[ -n $package_name && -n $package_version ]] || {
    echo "ERROR: package metadata is incomplete: $package_file" >&2
    exit 1
  }
  package_count=$((package_count + 1))

  if [[ -z ${latest_packages[$package_name]+x} ]] ||
    [[ $(vercmp "$package_version" "${latest_versions[$package_name]}") -gt 0 ]]; then
    latest_packages[$package_name]=$package_file
    latest_versions[$package_name]=$package_version
  fi
done

if (( package_count == 0 || ${#latest_packages[@]} == 0 )); then
  echo "ERROR: no signed packages found in $REPOSITORY_DIR" >&2
  exit 1
fi

mapfile -t selected_packages < <(printf '%s\n' "${latest_packages[@]}" | sort)
printf '==> Building staged repository database from %d package(s)\n' "${#selected_packages[@]}"
printf '  Adding: %s\n' "${selected_packages[@]}"

repo-add "$STAGING_DIR/$REPO_NAME.db.tar.zst" "${selected_packages[@]}" || {
  echo "ERROR: repo-add failed while building the staged repository database" >&2
  exit 1
}

for artifact in "$REPO_NAME.db.tar.zst" "$REPO_NAME.files.tar.zst"; do
  [[ -s $STAGING_DIR/$artifact && ! -L $STAGING_DIR/$artifact ]] || {
    echo "ERROR: repo-add did not produce a regular non-empty $artifact" >&2
    exit 1
  }
done

rm -f -- "$STAGING_DIR/$REPO_NAME.db" "$STAGING_DIR/$REPO_NAME.files"
ln -s "$REPO_NAME.db.tar.zst" "$STAGING_DIR/$REPO_NAME.db"
ln -s "$REPO_NAME.files.tar.zst" "$STAGING_DIR/$REPO_NAME.files"

echo "==> Staged repository database created successfully"
