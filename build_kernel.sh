#!/bin/bash
# Build script for Samsung A346E kernel (MediaTek mt6877, kernel-6.6)
# Organized and fixed version - handles bazel sandbox symlink issues
set -euo pipefail

# -------------------------------------------------------------------
# Globals
# -------------------------------------------------------------------
ROOT_DIR="$(pwd)"
export PATH="${ROOT_DIR}/bin:$PATH"
export TMPDIR=/tmp

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
log()  { echo -e "\n\033[1;34m[$(date +%H:%M:%S)] $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[WARN] $*\033[0m" >&2; }
die()  { echo -e "\n\033[1;31m[ERROR] $*\033[0m" >&2; exit 1; }

ensure_dir() { mkdir -p "$1"; }

# -------------------------------------------------------------------
# 1. System setup
# -------------------------------------------------------------------
setup_system() {
  log "ROOT_DIR=$ROOT_DIR"
  ensure_dir bin
  ulimit -n 4096 || true
  df -h || true

  if command -v apt-get >/dev/null 2>&1; then
    log "Installing host dependencies (if needed)"
    sudo apt-get update -y || true
    sudo apt-get install -y curl wget unzip python3 python3-pip git rsync \
      bc bison flex build-essential libssl-dev libelf-dev libncurses-dev \
      dwarves lz4 zstd cpio || true
  fi

  git config --global user.email "builder@example.com" || true
  git config --global user.name "Builder" || true
  git config --global --add safe.directory "*" || true
}

# -------------------------------------------------------------------
# 2. repo tool
# -------------------------------------------------------------------
download_repo_tool() {
  local dest="bin/repo"
  if [ -f "$dest" ] && [ -s "$dest" ] && head -n 5 "$dest" | grep -q "repo"; then
    log "repo tool already present"
    chmod a+x "$dest"
    return 0
  fi

  log "Downloading repo tool"
  local urls=(
    "https://storage.googleapis.com/git-repo-downloads/repo"
    "https://raw.githubusercontent.com/GerritCodeReview/git-repo/main/repo"
  )
  for url in "${urls[@]}"; do
    echo "Trying $url"
    if command -v curl >/dev/null 2>&1; then
      curl -L --retry 3 --retry-delay 5 -s -o "$dest" "$url" && [ -s "$dest" ] && chmod a+x "$dest" && head -n 5 "$dest" | grep -q "repo" && return 0 || true
    fi
    if command -v wget >/dev/null 2>&1; then
      wget -q -O "$dest" "$url" && [ -s "$dest" ] && chmod a+x "$dest" && head -n 5 "$dest" | grep -q "repo" && return 0 || true
    fi
    rm -f "$dest"
  done

  warn "Failed to download repo from mirrors, trying apt"
  sudo apt-get install -y repo || true
  if command -v repo >/dev/null 2>&1; then
    cp "$(command -v repo)" "$dest" || true
    chmod a+x "$dest" || true
  fi

  [ -f "$dest" ] && [ -s "$dest" ] || die "repo tool not available"
  ls -lh "$dest"
  "$dest" --version || true
}

# -------------------------------------------------------------------
# 3. AOSP kernel sync
# -------------------------------------------------------------------
sync_aosp_kernel() {
  log "Syncing aosp-kernel (common-android15-6.6)"
  ensure_dir aosp-kernel
  cd aosp-kernel

  if [ ! -d .repo ]; then
    log "repo init"
    if ! repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle --repo-url=https://gerrit.googlesource.com/git-repo; then
      repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle || true
    fi
  fi

  log "repo sync (up to 3 attempts, -j2)"
  for i in 1 2 3; do
    df -h || true
    if repo sync -c -j2 --force-sync --no-clone-bundle --no-tags; then
      log "repo sync succeeded"
      df -h
      du -sh . || true
      break
    fi
    warn "repo sync failed attempt $i"
    sleep 10
    [ $i -eq 3 ] && die "repo sync failed after 3 attempts"
  done

  cd "${ROOT_DIR}"
}

# -------------------------------------------------------------------
# 4. Link prebuilts & externals
# -------------------------------------------------------------------
link_prebuilts() {
  log "Linking prebuilts"
  if [ ! -d "aosp-kernel/prebuilts" ]; then
    ls -la aosp-kernel/ >&2
    die "aosp-kernel/prebuilts not found"
  fi

  ln -sfn "${ROOT_DIR}/aosp-kernel/prebuilts" "${ROOT_DIR}/kernel/prebuilts"
  ls -la "${ROOT_DIR}/kernel/prebuilts" || true

  # Optional external tools from aosp-kernel
  for ext in zopfli pigz; do
    if [ -d "${ROOT_DIR}/aosp-kernel/external/${ext}" ] && [ ! -e "${ROOT_DIR}/kernel/external/${ext}" ]; then
      ln -sfn "${ROOT_DIR}/aosp-kernel/external/${ext}" "${ROOT_DIR}/kernel/external/${ext}" || true
    fi
  done
}

# -------------------------------------------------------------------
# 5. Prepare kernel/ workspace (fix sandbox symlink issues)
# -------------------------------------------------------------------
prepare_workspace() {
  log "Preparing kernel/ workspace"
  cd "${ROOT_DIR}/kernel"

  # --- kernel-6.6: must be real dir, not symlink outside workspace ---
  # Original symlink ../kernel-6.6 points outside kernel/ and is rejected by newer bazel
  if [ -L kernel-6.6 ] || [ ! -d kernel-6.6 ]; then
    log "Recreating kernel-6.6 as real directory"
    rm -rf kernel-6.6 || true
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links "${ROOT_DIR}/kernel-6.6/" kernel-6.6/ || cp -r "${ROOT_DIR}/kernel-6.6" kernel-6.6
    else
      cp -r "${ROOT_DIR}/kernel-6.6" kernel-6.6
    fi
  else
    log "Syncing kernel-6.6 content to real dir"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links --delete "${ROOT_DIR}/kernel-6.6/" kernel-6.6/ || cp -r "${ROOT_DIR}/kernel-6.6/." kernel-6.6/
    else
      cp -r "${ROOT_DIR}/kernel-6.6/." kernel-6.6/ || true
    fi
  fi

  # --- build/bazel_common_rules: same issue, symlink points to ../../build/... outside ---
  if [ -L build/bazel_common_rules ] || [ ! -d build/bazel_common_rules ]; then
    log "Recreating build/bazel_common_rules as real directory"
    rm -rf build/bazel_common_rules || true
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links "${ROOT_DIR}/build/bazel_common_rules/" build/bazel_common_rules/ || cp -r "${ROOT_DIR}/build/bazel_common_rules" build/bazel_common_rules
    else
      cp -r "${ROOT_DIR}/build/bazel_common_rules" build/bazel_common_rules
    fi
  else
    log "Syncing build/bazel_common_rules"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links --delete "${ROOT_DIR}/build/bazel_common_rules/" build/bazel_common_rules/ || cp -r "${ROOT_DIR}/build/bazel_common_rules/." build/bazel_common_rules/
    else
      cp -r "${ROOT_DIR}/build/bazel_common_rules/." build/bazel_common_rules/ || true
    fi
  fi

  # Standard symlinks
  ln -sfn build/bazel_mgk_rules/kleaf/bazel.WORKSPACE WORKSPACE
  ln -sfn ../build/kernel/kleaf/bazel.sh tools/bazel
  chmod +x build/kernel/kleaf/bazel.sh tools/bazel || true

  ls -la prebuilts || true
  ls -la kernel-6.6/build.config.common || true

  # --- mkbootimg fix ---
  if [ ! -e "tools/mkbootimg" ]; then
    warn "tools/mkbootimg broken, trying to fix"
    ls -la tools/ || true
    if [ -f "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg/mkbootimg.py" ]; then
      ensure_dir "${ROOT_DIR}/system/tools"
      ln -sfn "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" "${ROOT_DIR}/system/tools/mkbootimg" || true
    fi
    if [ -f "${ROOT_DIR}/kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" ]; then
      ln -sfn ../../prebuilts/build-tools/path/linux-x86/mkbootimg tools/mkbootimg || true
    elif [ -f "${ROOT_DIR}/aosp-kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" ]; then
      ln -sfn "${ROOT_DIR}/aosp-kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" "${ROOT_DIR}/kernel/tools/mkbootimg" || true
    fi
  fi

  # Verify critical paths (allow real dir, not only symlink)
  for p in kernel-6.6 WORKSPACE tools/bazel; do
    echo "Checking $p"
    ls -la "$p" || true
    [ -e "$p" ] || die "Path $p missing or broken"
  done

  # system/tools/mkbootimg for bazel if available
  if [ ! -e "${ROOT_DIR}/system/tools/mkbootimg" ] && [ -d "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" ]; then
    ensure_dir "${ROOT_DIR}/system/tools"
    ln -sfn "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" "${ROOT_DIR}/system/tools/mkbootimg" || true
  fi
}

# -------------------------------------------------------------------
# 6. Patch stamp.bzl
# -------------------------------------------------------------------
patch_stamp() {
  log "Patching stamp.bzl to avoid git dirty"
  local stamp="build/kernel/kleaf/impl/stamp.bzl"
  if [ -f "$stamp" ]; then
    cp "$stamp" "${stamp}.bak" || true
    sed -i 's/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = "echo '\'''\''"/g' "$stamp" || true
    sed -i 's/-maybe-dirty//g' "$stamp" || true
    head -n 80 "$stamp" || true
  else
    warn "$stamp not found"
  fi

  local aosp_stamp="${ROOT_DIR}/aosp-kernel/build/kernel/kleaf/impl/stamp.bzl"
  if [ -f "$aosp_stamp" ]; then
    sed -i 's/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = "echo '\'''\''"/g' "$aosp_stamp" || true
    sed -i 's/-maybe-dirty//g' "$aosp_stamp" || true
  fi
}

# -------------------------------------------------------------------
# 7. Build config
# -------------------------------------------------------------------
generate_build_config() {
  log "Generating build.config"
  ensure_dir ../out/target/product/a34x/obj/KERNEL_OBJ
  ensure_dir ../out/target/product/a34x/obj/KLEAF_OBJ

  python3 kernel_device_modules-6.6/scripts/gen_build_config.py \
    --kernel-defconfig mediatek-bazel_defconfig \
    --kernel-defconfig-overlays "mt6877_overlay.config mt6877_teegris_5_overlay.config" \
    --kernel-build-config-overlays "" \
    -m user \
    -o ../out/target/product/a34x/obj/KERNEL_OBJ/build.config

  cat ../out/target/product/a34x/obj/KERNEL_OBJ/build.config
}

# -------------------------------------------------------------------
# 8. Run bazel build
# -------------------------------------------------------------------
run_kernel_build() {
  log "Setting up build environment"

  export DEVICE_MODULES_DIR="kernel_device_modules-6.6"
  export BUILD_CONFIG="../out/target/product/a34x/obj/KERNEL_OBJ/build.config"
  export OUT_DIR="../out/target/product/a34x/obj/KLEAF_OBJ"
  export DIST_DIR="../out/target/product/a34x/obj/KLEAF_OBJ/dist"
  export DEFCONFIG_OVERLAYS="mt6877_overlay.config mt6877_teegris_5_overlay.config"
  export PROJECT="mgk_64_k66"
  export MODE="user"
  export KERNEL_VERSION="kernel-6.6"
  export SOURCE_DATE_EPOCH="$(date +%s)"
  export KBUILD_BUILD_USER="builder"
  export KBUILD_BUILD_HOST="github"
  export BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1
  export SANDBOX=0
  export BUILD_CONFIG_FRAGMENTS=""

  echo "ENV:"
  echo "  DEVICE_MODULES_DIR=$DEVICE_MODULES_DIR"
  echo "  BUILD_CONFIG=$BUILD_CONFIG"
  echo "  OUT_DIR=$OUT_DIR"
  echo "  DIST_DIR=$DIST_DIR"
  echo "  PROJECT=$PROJECT MODE=$MODE KERNEL_VERSION=$KERNEL_VERSION"

  chmod +x ./kernel_device_modules-6.6/build.sh

  log "Checking bazel wrapper"
  ls -la tools/bazel
  ls -la build/kernel/kleaf/bazel.sh
  df -h
  free -h || true

  log "Starting kernel build (this takes ~50min)"
  ./kernel_device_modules-6.6/build.sh
}

# -------------------------------------------------------------------
# 9. Collect Image
# -------------------------------------------------------------------
collect_image() {
  cd "${ROOT_DIR}"
  log "Build finished, searching for Image"
  find out -name Image -type f | head -n 20 || true
  ls -lh out/target/product/a34x/obj/KLEAF_OBJ/dist/ || true

  local src="out/target/product/a34x/obj/KLEAF_OBJ/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/Image"
  if [ -f "$src" ]; then
    cp "$src" "${ROOT_DIR}/Image"
    log "Copied $src to ${ROOT_DIR}/Image"
  else
    local found
    found=$(find out -name Image -type f | head -n 1 || true)
    if [ -n "$found" ]; then
      cp "$found" "${ROOT_DIR}/Image"
      log "Copied $found to ${ROOT_DIR}/Image"
    else
      die "Image not found! Check logs"
    fi
  fi

  ls -lh "${ROOT_DIR}/Image"
  log "تمام! فایل Image در ${ROOT_DIR}/Image آماده است."
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
  setup_system
  download_repo_tool
  sync_aosp_kernel
  link_prebuilts
  prepare_workspace
  patch_stamp
  generate_build_config
  run_kernel_build
  collect_image
}

main "$@"
