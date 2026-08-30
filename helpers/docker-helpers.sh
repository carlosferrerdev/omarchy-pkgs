# Docker helper functions for Omarchy package build system

check_docker() {
  if ! command -v docker &>/dev/null; then
    print_error "Docker is not installed"
    exit 1
  fi

  if ! docker info &>/dev/null; then
    print_error "Docker daemon is not running"
    print_warning "Start Docker with: sudo systemctl start docker"
    exit 1
  fi
}

build_docker_image() {
  local build_dir="$1"
  local arch="${2:-x86_64}"
  local mirror="${3:-edge}"
  local platform=""
  local image_tag="omarchy-pkg-builder:latest-$arch-$mirror"
  local builder_uid

  builder_uid=$(id -u)
  [[ $builder_uid -ne 0 ]] || builder_uid=1000

  
  case "$arch" in
    x86_64)  platform="linux/amd64" ;;
    aarch64) platform="linux/arm64" ;;
    *)
      print_error "Unsupported architecture: $arch"
      exit 1
      ;;
  esac
  
  print_info "Building Docker image for $arch ($platform) using $mirror mirror..."
  
  docker buildx build \
    --platform "$platform" \
    --build-arg BUILDER_UID="$builder_uid" \
    --build-arg MIRROR="$mirror" \
    --load \
    -t "$image_tag" \
    -f "$build_dir/Dockerfile" \
    "$build_dir"
}

get_platform_arg() {
  local arch="$1"
  case "$arch" in
    x86_64)  echo "--platform linux/amd64" ;;
    aarch64) echo "--platform linux/arm64" ;;
    *)       echo "" ;;
  esac
}

make_dir_writable() {
  local dir="$1"
  local builder_uid

  [[ -d $dir && ! -L $dir ]] || {
    print_error "Writable Docker path is missing or unsafe: $dir"
    return 1
  }
  builder_uid=$(id -u)
  [[ $builder_uid -ne 0 ]] || builder_uid=1000

  if [[ $(id -u) -eq 0 ]]; then
    chown -R "$builder_uid:$builder_uid" "$dir"
  fi
  chmod -R u+rwX,go-w "$dir"
}
