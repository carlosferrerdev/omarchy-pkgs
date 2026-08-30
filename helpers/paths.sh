# Common path variables for Omarchy package build system
# This file should be sourced after setting BUILD_ROOT

# Default architecture and mirror
ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}

# Valid package channels, in pipeline order: packages move edge -> rc -> stable
VALID_MIRRORS="edge rc stable"
VALID_ARCHITECTURES="x86_64 aarch64"

validate_arch() {
  case "$1" in
  x86_64 | aarch64) return 0 ;;
  *) return 1 ;;
  esac
}

require_valid_arch() {
  if ! validate_arch "$1"; then
    echo "Invalid architecture: $1 (must be one of: $VALID_ARCHITECTURES)" >&2
    exit 1
  fi
}

validate_mirror() {
  case "$1" in
  edge | rc | stable) return 0 ;;
  *) return 1 ;;
  esac
}

require_valid_mirror() {
  if ! validate_mirror "$1"; then
    echo "Invalid mirror: $1 (must be one of: $VALID_MIRRORS)" >&2
    exit 1
  fi
}

# Core directories (architecture-independent)
BUILD_DIR="$BUILD_ROOT/build"
SRC_DIR="$BUILD_ROOT/src"
LOG_DIR="$BUILD_ROOT/logs"
PKGBUILDS_DIR="$BUILD_ROOT/pkgbuilds"

# The published repository tree. Secondary checkouts (like the rc branch
# worktree on the build host) set OMARCHY_REPO_ROOT so every channel lives in
# one shared tree regardless of which checkout ran the command.
REPO_ROOT="${OMARCHY_REPO_ROOT:-$BUILD_ROOT/pkgs.omarchy.org}"

# Function to update architecture and mirror-specific paths
# Call this after changing ARCH or MIRROR variables
update_arch_paths() {
  # These values form host and remote paths throughout the release pipeline.
  # Validate on every recalculation so CLI input and inherited environment
  # variables cannot escape the intended channel/architecture tree.
  require_valid_arch "$ARCH"
  require_valid_mirror "$MIRROR"
  BUILD_OUTPUT_DIR="$BUILD_ROOT/build-output/$MIRROR/$ARCH" # Unsigned packages
  REPO_DIR="$REPO_ROOT/$MIRROR/$ARCH"                       # Repository (signed packages)
}

# Initialize architecture-specific directories with default ARCH and MIRROR
update_arch_paths
