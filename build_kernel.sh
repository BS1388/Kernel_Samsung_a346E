#!/bin/bash
# ==============================================================================
# Build script for Samsung A346E kernel (MediaTek mt6877, kernel-6.6)
# Refactored & hardened - handles bazel sandbox, casing, and FDO
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Globals & Setup
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
export PATH="${ROOT_DIR}/bin:${PATH}"
export TMPDIR=/tmp

# Colors for log
RED='\033[1;31m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; GREEN='\033[1;32m'; NC='\033[0m'

log()  { echo -e "\n${BLUE}[$(date +%H:%M:%S)] $*${NC}"; }
ok()   { echo -e "${GREEN}[OK] $*${NC}"; }
warn() { echo -e "\n${YELLOW}[WARN] $*${NC}" >&2; }
die()  { echo -e "\n${RED}[ERROR] $*${NC}" >&2; exit 1; }

ensure_dir() { mkdir -p "$1"; }

# Detect real kernel dir (case-insensitive)
detect_kernel_dir() {
  if [ -d "${ROOT_DIR}/Kernel-6.6" ] && [ -f "${ROOT_DIR}/Kernel-6.6/Makefile" ]; then
    echo "${ROOT_DIR}/Kernel-6.6"
  elif [ -d "${ROOT_DIR}/kernel-6.6" ] && [ -f "${ROOT_DIR}/kernel-6.6/Makefile" ]; then
    echo "${ROOT_DIR}/kernel-6.6"
  else
    die "Could not find kernel-6.6 or Kernel-6.6 with Makefile in ${ROOT_DIR}"
  fi
}

# ------------------------------------------------------------------------------
# 1. System setup
# ------------------------------------------------------------------------------
setup_system() {
  log "ROOT_DIR=${ROOT_DIR}"
  log "SCRIPT_DIR=${SCRIPT_DIR}"
  ensure_dir "${ROOT_DIR}/bin"
  ulimit -n 4096 2>/dev/null || warn "ulimit -n 4096 failed"

  # Only install deps if not in GitHub Actions (where workflow already did)
  if [ -z "${GITHUB_ACTIONS:-}" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      log "Installing host dependencies (local build)"
      sudo apt-get update -y || warn "apt-get update failed"
      sudo apt-get install -y curl wget unzip python3 python3-pip git rsync \
        bc bison flex build-essential libssl-dev libelf-dev libncurses-dev \
        dwarves lz4 zstd cpio libxml2-utils xsltproc || warn "apt install partial fail"
    fi
  else
    log "Running in GitHub Actions - skipping apt install (handled by workflow)"
  fi

  git config --global user.email "builder@example.com" || true
  git config --global user.name "Builder" || true
  git config --global --add safe.directory "*" || true

  df -h || true
  nproc || true
  free -h || true
}

# ------------------------------------------------------------------------------
# 2. repo tool
# ------------------------------------------------------------------------------
download_repo_tool() {
  local dest="${ROOT_DIR}/bin/repo"
  if [ -f "$dest" ] && [ -s "$dest" ] && head -n 5 "$dest" | grep -q "repo"; then
    log "repo tool already present at $dest"
    chmod a+x "$dest"
    return 0
  fi

  log "Downloading repo tool to $dest"
  local urls=(
    "https://storage.googleapis.com/git-repo-downloads/repo"
    "https://raw.githubusercontent.com/GerritCodeReview/git-repo/main/repo"
  )
  for url in "${urls[@]}"; do
    log "Trying $url"
    if command -v curl >/dev/null 2>&1; then
      curl -L --retry 3 --retry-delay 5 -fsSL -o "$dest" "$url" && [ -s "$dest" ] && chmod a+x "$dest" && return 0 || rm -f "$dest"
    fi
    if command -v wget >/dev/null 2>&1; then
      wget -q -O "$dest" "$url" && [ -s "$dest" ] && chmod a+x "$dest" && return 0 || rm -f "$dest"
    fi
  done

  warn "Failed to download repo from mirrors, trying apt"
  sudo apt-get install -y repo || true
  if command -v repo >/dev/null 2>&1; then
    cp "$(command -v repo)" "$dest" || true
    chmod a+x "$dest" || true
  fi

  [ -f "$dest" ] && [ -s "$dest" ] || die "repo tool not available at $dest"
  ls -lh "$dest"
  "$dest" --version || true
}

# ------------------------------------------------------------------------------
# 3. AOSP kernel sync
# ------------------------------------------------------------------------------
sync_aosp_kernel() {
  log "Syncing aosp-kernel (common-android15-6.6)"
  local aosp_dir="${ROOT_DIR}/aosp-kernel"
  ensure_dir "$aosp_dir"
  pushd "$aosp_dir" >/dev/null

  if [ ! -d .repo ]; then
    log "repo init"
    if ! repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle --repo-url=https://gerrit.googlesource.com/git-repo; then
      log "First repo init failed, retrying without repo-url"
      repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle || warn "repo init failed"
    fi
  fi

  log "repo sync (up to 3 attempts, -j2)"
  local attempt
  for attempt in 1 2 3; do
    df -h || true
    if repo sync -c -j2 --force-sync --no-clone-bundle --no-tags; then
      ok "repo sync succeeded on attempt $attempt"
      df -h
      du -sh . || true
      break
    fi
    warn "repo sync failed attempt $attempt"
    sleep 10
    [ "$attempt" -eq 3 ] && die "repo sync failed after 3 attempts"
  done

  popd >/dev/null
}

# ------------------------------------------------------------------------------
# 4. Link prebuilts & externals
# ------------------------------------------------------------------------------
link_prebuilts() {
  log "Linking prebuilts"
  local aosp_prebuilts="${ROOT_DIR}/aosp-kernel/prebuilts"
  local kernel_prebuilts="${ROOT_DIR}/kernel/prebuilts"

  if [ ! -d "$aosp_prebuilts" ]; then
    ls -la "${ROOT_DIR}/aosp-kernel/" >&2 || true
    die "aosp-kernel/prebuilts not found at $aosp_prebuilts"
  fi

  # Ensure kernel/prebuilts is a symlink to aosp-kernel/prebuilts
  rm -rf "$kernel_prebuilts" || true
  ln -sfn "$aosp_prebuilts" "$kernel_prebuilts"
  ok "Linked $kernel_prebuilts -> $aosp_prebuilts"

  # Optional external tools
  for ext in zopfli pigz; do
    local src="${ROOT_DIR}/aosp-kernel/external/${ext}"
    local dst="${ROOT_DIR}/kernel/external/${ext}"
    if [ -d "$src" ] && [ ! -e "$dst" ]; then
      ln -sfn "$src" "$dst" || warn "Failed to link $ext"
      ok "Linked $dst -> $src"
    fi
  done
}

# ------------------------------------------------------------------------------
# 5. Prepare kernel/ workspace (fix bazel sandbox symlink issues)
# ------------------------------------------------------------------------------
prepare_workspace() {
  log "Preparing kernel/ workspace (fix bazel sandbox)"

  local real_kernel_dir
  real_kernel_dir="$(detect_kernel_dir)"
  log "Real kernel dir detected: $real_kernel_dir"
  local real_kernel_basename
  real_kernel_basename="$(basename "$real_kernel_dir")"

  pushd "${ROOT_DIR}/kernel" >/dev/null

  # --- kernel-6.6: must be real dir, not symlink outside workspace ---
  # Newer bazel rejects symlinks pointing outside workspace
  if [ -L "kernel-6.6" ] || [ ! -d "kernel-6.6" ]; then
    log "Recreating kernel/kernel-6.6 as real directory from $real_kernel_dir"
    rm -rf "kernel-6.6" || true
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links "${real_kernel_dir}/" "kernel-6.6/" || cp -r "${real_kernel_dir}" "kernel-6.6"
    else
      cp -r "${real_kernel_dir}" "kernel-6.6"
    fi
  else
    log "Syncing $real_kernel_dir -> kernel/kernel-6.6"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links --delete "${real_kernel_dir}/" "kernel-6.6/" || cp -r "${real_kernel_dir}/." "kernel-6.6/"
    else
      cp -r "${real_kernel_dir}/." "kernel-6.6/" || true
    fi
  fi

  # If original was Kernel-6.6 (capital), also ensure lowercase exists for bazel
  if [ "$real_kernel_basename" = "Kernel-6.6" ]; then
    log "Original is Kernel-6.6 (capital), ensuring kernel-6.6 exists"
    if [ ! -d "${ROOT_DIR}/kernel-6.6" ]; then
      log "Creating ${ROOT_DIR}/kernel-6.6 as copy of ${real_kernel_dir}"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --copy-links "${real_kernel_dir}/" "${ROOT_DIR}/kernel-6.6/" || true
      else
        cp -r "${real_kernel_dir}" "${ROOT_DIR}/kernel-6.6" || true
      fi
    fi
  fi

  # --- build/bazel_common_rules: same issue ---
  if [ -L "build/bazel_common_rules" ] || [ ! -d "build/bazel_common_rules" ]; then
    log "Recreating build/bazel_common_rules as real directory"
    rm -rf "build/bazel_common_rules" || true
    if [ -d "${ROOT_DIR}/build/bazel_common_rules" ]; then
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --copy-links "${ROOT_DIR}/build/bazel_common_rules/" "build/bazel_common_rules/" || cp -r "${ROOT_DIR}/build/bazel_common_rules" "build/bazel_common_rules"
      else
        cp -r "${ROOT_DIR}/build/bazel_common_rules" "build/bazel_common_rules"
      fi
    else
      warn "Source ${ROOT_DIR}/build/bazel_common_rules not found"
    fi
  else
    log "Syncing build/bazel_common_rules"
    if [ -d "${ROOT_DIR}/build/bazel_common_rules" ]; then
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --copy-links --delete "${ROOT_DIR}/build/bazel_common_rules/" "build/bazel_common_rules/" || true
      else
        cp -r "${ROOT_DIR}/build/bazel_common_rules/." "build/bazel_common_rules/" || true
      fi
    fi
  fi

  # --- Google-FDO: external FDO profile must be inside kernel/ workspace for bazel ---
  # The label //Google-FDO:kernel.afdo is resolved from workspace root (kernel/), so we need kernel/Google-FDO
  if [ -d "${ROOT_DIR}/Google-FDO" ]; then
    log "Syncing Google-FDO to kernel/Google-FDO for bazel"
    rm -rf "Google-FDO" || true
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links "${ROOT_DIR}/Google-FDO/" "Google-FDO/" || cp -r "${ROOT_DIR}/Google-FDO" "Google-FDO"
    else
      cp -r "${ROOT_DIR}/Google-FDO" "Google-FDO"
    fi
    ls -lh "Google-FDO/" || true
  else
    warn "Google-FDO not found at ${ROOT_DIR}/Google-FDO"
  fi

  # Standard symlinks required by kleaf
  log "Setting up WORKSPACE and bazel wrapper"
  ln -sfn "build/bazel_mgk_rules/kleaf/bazel.WORKSPACE" "WORKSPACE"
  ln -sfn "../build/kernel/kleaf/bazel.sh" "tools/bazel"
  chmod +x "build/kernel/kleaf/bazel.sh" "tools/bazel" || true

  # Verify critical paths
  for p in "kernel-6.6" "WORKSPACE" "tools/bazel" "build/bazel_common_rules"; do
    if [ ! -e "$p" ]; then
      die "Required path $p missing after prepare_workspace"
    fi
    ok "Verified $p -> $(ls -ld "$p" | awk '{print $NF}')"
  done

  # --- mkbootimg fix ---
  if [ ! -e "tools/mkbootimg" ] || [ -L "tools/mkbootimg" ] && [ ! -e "$(readlink -f "tools/mkbootimg" 2>/dev/null || echo "")" ]; then
    warn "tools/mkbootimg missing/broken, attempting fix"
    ls -la "tools/" || true
    # Try to link from aosp-kernel
    if [ -f "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg/mkbootimg.py" ]; then
      ensure_dir "${ROOT_DIR}/system/tools"
      ln -sfn "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" "${ROOT_DIR}/system/tools/mkbootimg" || true
      ok "Linked system/tools/mkbootimg"
    fi
    # Try prebuilt mkbootimg binary
    if [ -f "${ROOT_DIR}/aosp-kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" ]; then
      ln -sfn "${ROOT_DIR}/aosp-kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" "tools/mkbootimg" || true
      ok "Linked tools/mkbootimg from aosp prebuilts"
    elif [ -f "prebuilts/build-tools/path/linux-x86/mkbootimg" ]; then
      ln -sfn "../../prebuilts/build-tools/path/linux-x86/mkbootimg" "tools/mkbootimg" || true
      ok "Linked tools/mkbootimg from kernel prebuilts"
    fi
  fi

  # Ensure system/tools/mkbootimg exists for bazel
  if [ ! -e "${ROOT_DIR}/system/tools/mkbootimg" ] && [ -d "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" ]; then
    ensure_dir "${ROOT_DIR}/system/tools"
    ln -sfn "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" "${ROOT_DIR}/system/tools/mkbootimg" || true
    ok "Ensured ${ROOT_DIR}/system/tools/mkbootimg"
  fi

  # --- MTK signing key fix ---
  # The build needs certs/mtk_signing_key.pem in both kernel-6.6/certs/ and kernel_device_modules-6.6/certs/
  # In repo, key only exists in kernel_device_modules-6.6/certs/, not in kernel-6.6/certs/
  # After rsync, kernel/kernel-6.6/certs/ still lacks the key, causing sign-file to fail with "No such file"
  # Fix: copy key to all expected locations
  log "Ensuring mtk_signing_key.pem exists in all certs locations"
  local mtk_key_src=""
  if [ -f "${ROOT_DIR}/kernel/kernel_device_modules-6.6/certs/mtk_signing_key.pem" ]; then
    mtk_key_src="${ROOT_DIR}/kernel/kernel_device_modules-6.6/certs/mtk_signing_key.pem"
  elif [ -f "kernel_device_modules-6.6/certs/mtk_signing_key.pem" ]; then
    mtk_key_src="$(pwd)/kernel_device_modules-6.6/certs/mtk_signing_key.pem"
  elif [ -f "${ROOT_DIR}/kernel-6.6/certs/mtk_signing_key.pem" ]; then
    mtk_key_src="${ROOT_DIR}/kernel-6.6/certs/mtk_signing_key.pem"
  fi

  if [ -n "$mtk_key_src" ] && [ -f "$mtk_key_src" ]; then
    log "Found MTK signing key at $mtk_key_src ($(du -h "$mtk_key_src" | awk '{print $1}'))"
    # Ensure in ROOT_DIR/kernel-6.6/certs/
    ensure_dir "${ROOT_DIR}/kernel-6.6/certs"
    if [ ! -f "${ROOT_DIR}/kernel-6.6/certs/mtk_signing_key.pem" ]; then
      cp -v "$mtk_key_src" "${ROOT_DIR}/kernel-6.6/certs/mtk_signing_key.pem" || warn "Failed to copy to ROOT_DIR/kernel-6.6/certs/"
    fi
    # Ensure in kernel/kernel-6.6/certs/ (workspace)
    ensure_dir "kernel-6.6/certs"
    if [ ! -f "kernel-6.6/certs/mtk_signing_key.pem" ]; then
      cp -v "$mtk_key_src" "kernel-6.6/certs/mtk_signing_key.pem" || warn "Failed to copy to kernel/kernel-6.6/certs/"
    fi
    # Ensure in kernel_device_modules-6.6/certs/ at root if exists (for completeness)
    if [ -d "${ROOT_DIR}/kernel-6.6/../kernel_device_modules-6.6/certs" ] 2>/dev/null; then
      ensure_dir "${ROOT_DIR}/kernel_device_modules-6.6/certs" 2>/dev/null || true
      cp -v "$mtk_key_src" "${ROOT_DIR}/kernel_device_modules-6.6/certs/mtk_signing_key.pem" 2>/dev/null || true
    fi
    # Ensure in workspace kernel_device_modules-6.6/certs/ (should already exist, but ensure)
    ensure_dir "kernel_device_modules-6.6/certs"
    if [ ! -f "kernel_device_modules-6.6/certs/mtk_signing_key.pem" ]; then
      cp -v "$mtk_key_src" "kernel_device_modules-6.6/certs/mtk_signing_key.pem" || warn "Failed to copy to kernel_device_modules-6.6/certs/"
    fi
    ls -lh "kernel-6.6/certs/mtk_signing_key.pem" "${ROOT_DIR}/kernel-6.6/certs/mtk_signing_key.pem" "kernel_device_modules-6.6/certs/mtk_signing_key.pem" 2>&1 || true
    ok "MTK signing key ensured"
  else
    warn "MTK signing key not found in any known location, will try to continue (may fail at modules_install)"
    find "${ROOT_DIR}" -name "mtk_signing_key.pem" 2>/dev/null | head -n 10 || true
    find "$(pwd)" -name "mtk_signing_key.pem" 2>/dev/null | head -n 10 || true
  fi

  # List critical files for debug
  ls -lh "kernel-6.6/build.config.common" 2>/dev/null || warn "kernel-6.6/build.config.common not found"
  ls -lh "prebuilts" 2>/dev/null || true
  ls -lh "kernel-6.6/certs/mtk_signing_key.pem" 2>/dev/null || warn "kernel-6.6/certs/mtk_signing_key.pem still missing after fix!"
  ls -lh "kernel_device_modules-6.6/certs/mtk_signing_key.pem" 2>/dev/null || warn "kernel_device_modules-6.6/certs/mtk_signing_key.pem missing!"

  popd >/dev/null
  ok "Workspace prepared"
}

# ------------------------------------------------------------------------------
# 6. Patch stamp.bzl and fix build.sh shebang (Samsung bug: SPDX before #!/bin/bash)
# ------------------------------------------------------------------------------
patch_stamp() {
  log "Patching stamp.bzl to avoid git dirty version"

  local stamp_files=(
    "${ROOT_DIR}/kernel/build/kernel/kleaf/impl/stamp.bzl"
    "${ROOT_DIR}/aosp-kernel/build/kernel/kleaf/impl/stamp.bzl"
  )

  for stamp in "${stamp_files[@]}"; do
    if [ -f "$stamp" ]; then
      log "Patching $stamp"
      cp "$stamp" "${stamp}.bak" 2>/dev/null || true
      # Replace stable_scmversion_cmd with echo ''
      sed -i "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo ''\"/g" "$stamp" || warn "sed failed for $stamp"
      sed -i 's/-maybe-dirty//g' "$stamp" || true
      head -n 20 "$stamp" | tail -n 10 || true
    else
      warn "$stamp not found, skipping"
    fi
  done

  # Fix Samsung's broken shebang: SPDX line before #!/bin/bash causes /bin/sh to be used -> source: not found
  log "Fixing kernel_device_modules-6.6/build.sh shebang"
  local build_scripts=(
    "${ROOT_DIR}/kernel/kernel_device_modules-6.6/build.sh"
    "${ROOT_DIR}/kernel/kernel_device_modules-6.6/build_abi.sh"
    "${ROOT_DIR}/kernel-6.6/kernel_device_modules-6.6/build.sh"
    "${ROOT_DIR}/Kernel-6.6/kernel_device_modules-6.6/build.sh"
    "${ROOT_DIR}/kernel-6.6/build/kernel/kleaf/bazel.sh"
    "${ROOT_DIR}/Kernel-6.6/build/kernel/kleaf/bazel.sh"
  )
  for bs in "${build_scripts[@]}"; do
    if [ -f "$bs" ]; then
      log "Checking $bs (first line: $(head -n1 "$bs"))"
      if head -n1 "$bs" | grep -q "SPDX"; then
        log "Fixing shebang order in $bs (SPDX before shebang)"
        local tmp
        tmp=$(mktemp)
        {
          echo "#!/bin/bash"
          # Keep original content without any shebang lines
          grep -v "^#!/bin/bash" "$bs" || true
        } > "$tmp"
        mv "$tmp" "$bs"
        chmod +x "$bs"
        ok "Fixed $bs"
        head -n 3 "$bs"
      else
        ok "$bs shebang OK (first line is shebang)"
      fi
    fi
  done
}

# ------------------------------------------------------------------------------
# 7. Generate build.config
# ------------------------------------------------------------------------------
generate_build_config() {
  log "Generating build.config"

  # gen_build_config.py calculates kernel_dir based on cwd, so must run from kernel/ dir
  # to get correct relative path (kernel_device_modules-6.6 not kernel/kernel_device_modules-6.6)
  pushd "${ROOT_DIR}/kernel" >/dev/null

  local out_base="${ROOT_DIR}/out/target/product/a34x/obj"
  ensure_dir "${out_base}/KERNEL_OBJ"
  ensure_dir "${out_base}/KLEAF_OBJ"

  local gen_script="kernel_device_modules-6.6/scripts/gen_build_config.py"
  if [ ! -f "$gen_script" ]; then
    die "gen_build_config.py not found at $gen_script (pwd=$(pwd))"
  fi

  log "Running $gen_script from $(pwd)"
  python3 "$gen_script" \
    --kernel-defconfig mediatek-bazel_defconfig \
    --kernel-defconfig-overlays "mt6877_overlay.config mt6877_teegris_5_overlay.config" \
    --kernel-build-config-overlays "" \
    -m user \
    -o "../out/target/product/a34x/obj/KERNEL_OBJ/build.config"

  ok "Generated ${out_base}/KERNEL_OBJ/build.config"
  cat "${out_base}/KERNEL_OBJ/build.config"

  popd >/dev/null
}

# ------------------------------------------------------------------------------
# 8. Run bazel build
# ------------------------------------------------------------------------------
run_kernel_build() {
  log "Setting up build environment"

  # Must run from kernel/ directory for bazel wrapper
  pushd "${ROOT_DIR}/kernel" >/dev/null

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

  log "ENV:"
  echo "  DEVICE_MODULES_DIR=$DEVICE_MODULES_DIR"
  echo "  BUILD_CONFIG=$BUILD_CONFIG (exists: $([ -f "$BUILD_CONFIG" ] && echo yes || echo no))"
  echo "  OUT_DIR=$OUT_DIR"
  echo "  DIST_DIR=$DIST_DIR"
  echo "  PROJECT=$PROJECT MODE=$MODE KERNEL_VERSION=$KERNEL_VERSION"
  echo "  SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

  local build_sh="./kernel_device_modules-6.6/build.sh"
  if [ ! -x "$build_sh" ]; then
    chmod +x "$build_sh" || true
  fi
  [ -f "$build_sh" ] || die "build.sh not found at $build_sh"

  log "Checking bazel wrapper"
  ls -lh "tools/bazel" "build/kernel/kleaf/bazel.sh" || die "bazel wrapper missing"
  df -h
  free -h || true

  log "Starting kernel build (this takes ~50min)"
  # Use bash explicitly - Samsung's build.sh has broken shebang (SPDX before #!/bin/bash) causing /bin/sh to be used -> source: not found
  # Always call with bash
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL bash "$build_sh"
  else
    bash "$build_sh"
  fi

  popd >/dev/null
  ok "Kernel build finished"
}

# ------------------------------------------------------------------------------
# 9. Collect Image
# ------------------------------------------------------------------------------
collect_image() {
  log "Collecting Image"
  pushd "${ROOT_DIR}" >/dev/null

  log "Searching for Image in out/"
  find out -name "Image" -type f 2>/dev/null | head -n 20 || true
  ls -lh "out/target/product/a34x/obj/KLEAF_OBJ/dist/" 2>/dev/null || true

  local primary_src="out/target/product/a34x/obj/KLEAF_OBJ/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/Image"
  local dest="${ROOT_DIR}/Image"

  if [ -f "$primary_src" ]; then
    cp -v "$primary_src" "$dest"
    ok "Copied primary $primary_src -> $dest"
  else
    warn "Primary Image not found at $primary_src, searching fallback"
    local found
    found=$(find out -name "Image" -type f -type f 2>/dev/null | grep -v ".*\.d$" | head -n 1 || true)
    if [ -n "$found" ] && [ -f "$found" ]; then
      cp -v "$found" "$dest"
      ok "Copied fallback $found -> $dest"
    else
      die "Image not found! Checked $primary_src and searched out/. Build failed."
    fi
  fi

  ls -lh "$dest"
  sha256sum "$dest" || true
  ok "تمام! فایل Image در $dest آماده است."

  popd >/dev/null
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  log "=== A346E Kernel Build Started ==="
  log "Date: $(date)"
  log "User: $(whoami) Host: $(hostname) PWD: $(pwd)"

  setup_system
  download_repo_tool
  sync_aosp_kernel
  link_prebuilts
  prepare_workspace
  patch_stamp
  generate_build_config
  run_kernel_build
  collect_image

  log "=== Build Completed Successfully ==="
}

# Trap errors
trap 'die "Build failed at line $LINENO (exit code $?)"' ERR

main "$@"
