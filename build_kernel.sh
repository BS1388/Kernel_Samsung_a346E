#!/bin/bash
set -eux
set -o pipefail

ROOT_DIR="$(pwd)"
echo "ROOT_DIR=$ROOT_DIR"
mkdir -p bin
export PATH="${ROOT_DIR}/bin:$PATH"

# Install deps if apt available (for local testing and GH runner)
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y || true
  sudo apt-get install -y curl wget unzip python3 python3-pip git rsync bc bison flex build-essential libssl-dev libelf-dev libncurses-dev dwarves lz4 zstd cpio || true
fi

# git config for repo tool
git config --global user.email "builder@example.com" || true
git config --global user.name "Builder" || true
git config --global --add safe.directory "*" || true

# download repo tool if missing
if [ ! -f bin/repo ] || [ ! -s bin/repo ]; then
  echo "Downloading repo tool"
  curl -s https://storage.googleapis.com/git-repo-downloads/repo > bin/repo
  chmod a+x bin/repo
fi
repo --version || true

# aosp-kernel sync
mkdir -p aosp-kernel
cd aosp-kernel

if [ ! -d .repo ]; then
  echo "Initializing repo manifest common-android15-6.6"
  repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle
fi

# retry sync up to 3 times
for i in 1 2 3; do
  echo "repo sync attempt $i"
  if repo sync -c -j"$(nproc --all)" --force-sync --no-clone-bundle --no-tags; then
    echo "repo sync succeeded"
    break
  fi
  echo "repo sync failed attempt $i, retrying..."
  sleep 10
  if [ $i -eq 3 ]; then
    echo "repo sync failed after 3 attempts"
    exit 1
  fi
done

cd "${ROOT_DIR}"

# Link prebuilts
echo "Linking prebuilts"
ls -la aosp-kernel/prebuilts || true
if [ -d "aosp-kernel/prebuilts" ]; then
  ln -sfn "${ROOT_DIR}/aosp-kernel/prebuilts" "${ROOT_DIR}/kernel/prebuilts"
else
  echo "ERROR: aosp-kernel/prebuilts not found after sync" >&2
  ls -la aosp-kernel/ >&2
  exit 1
fi
ls -la "${ROOT_DIR}/kernel/prebuilts" || true
ls -la "${ROOT_DIR}/kernel/prebuilts/build-tools/path/linux-x86/" || true

# Link external zopfli pigz if needed
if [ -d "${ROOT_DIR}/aosp-kernel/external/zopfli" ]; then
  [ -d "${ROOT_DIR}/kernel/external/zopfli" ] || ln -sfn "${ROOT_DIR}/aosp-kernel/external/zopfli" "${ROOT_DIR}/kernel/external/zopfli"
fi
if [ -d "${ROOT_DIR}/aosp-kernel/external/pigz" ]; then
  [ -d "${ROOT_DIR}/kernel/external/pigz" ] || ln -sfn "${ROOT_DIR}/aosp-kernel/external/pigz" "${ROOT_DIR}/kernel/external/pigz"
fi

cd "${ROOT_DIR}/kernel"

# Symlinks for kernel build
echo "Creating symlinks in kernel/"
ln -sfn ../kernel-6.6 kernel-6.6
ln -sfn build/bazel_mgk_rules/kleaf/bazel.WORKSPACE WORKSPACE
# tools/bazel symlink: target is relative to tools/ dir, so ../build/... resolves to kernel/build/...
ln -sfn ../build/kernel/kleaf/bazel.sh tools/bazel
chmod +x build/kernel/kleaf/bazel.sh || true
chmod +x tools/bazel || true

# Fix mkbootimg symlink if broken - try to find mkbootimg in aosp-kernel
if [ ! -e "tools/mkbootimg" ]; then
  echo "tools/mkbootimg is broken, trying to fix"
  ls -la tools/ || true
  if [ -f "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg/mkbootimg.py" ]; then
    echo "Found mkbootimg.py in aosp-kernel, linking system"
    mkdir -p "${ROOT_DIR}/system/tools"
    ln -sfn "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" "${ROOT_DIR}/system/tools/mkbootimg" 2>&1 || true
    # also try to ensure tools/mkbootimg points correctly
    ls -la "${ROOT_DIR}/system/tools/mkbootimg" || true
  fi
  # Check if prebuilt mkbootimg exists
  if [ -f "${ROOT_DIR}/kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" ]; then
    echo "Found prebuilt mkbootimg, using it"
    ln -sfn ../../prebuilts/build-tools/path/linux-x86/mkbootimg tools/mkbootimg || true
  elif [ -f "${ROOT_DIR}/aosp-kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" ]; then
    ln -sfn "${ROOT_DIR}/aosp-kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" "${ROOT_DIR}/kernel/tools/mkbootimg" || true
  else
    echo "mkbootimg not found, creating dummy wrapper that will not fail Image build"
    # Keep existing symlink if it's at least a symlink, bazel may not need it for Image target
    ls -la tools/mkbootimg || true
  fi
fi

for link in kernel-6.6 WORKSPACE tools/bazel; do
  echo "Checking $link"
  ls -la "$link" || true
  if [ ! -e "$link" ]; then
    echo "خطا: سیم‌لینک $link خرابه یا به مسیر اشتباه اشاره می‌کنه." >&2
    ls -la "$link" >&2
    echo "Contents of $(dirname $link):" >&2
    ls -la "$(dirname $link)" >&2
    exit 1
  fi
done

# Ensure system/tools/mkbootimg directory exists for bazel if possible
if [ ! -e "${ROOT_DIR}/system/tools/mkbootimg" ] && [ -d "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" ]; then
  mkdir -p "${ROOT_DIR}/system/tools"
  ln -sfn "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" "${ROOT_DIR}/system/tools/mkbootimg" || true
fi

# Patch stamp.bzl to avoid git metadata and -maybe-dirty
STAMP_FILE="build/kernel/kleaf/impl/stamp.bzl"
if [ -f "$STAMP_FILE" ]; then
  echo "Patching $STAMP_FILE"
  cp "$STAMP_FILE" "${STAMP_FILE}.bak" || true
  # Replace stable_scmversion_cmd with echo ''
  sed -i "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo ''\"/g" "$STAMP_FILE" || true
  sed -i "s/-maybe-dirty//g" "$STAMP_FILE" || true
  echo "Patched file head:"
  head -n 80 "$STAMP_FILE" || true
else
  echo "WARNING: $STAMP_FILE not found"
fi

# Also patch aosp-kernel version if exists to be safe
AOSP_STAMP="${ROOT_DIR}/aosp-kernel/build/kernel/kleaf/impl/stamp.bzl"
if [ -f "$AOSP_STAMP" ]; then
  echo "Patching aosp-kernel stamp.bzl as well"
  sed -i "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo ''\"/g" "$AOSP_STAMP" || true
  sed -i "s/-maybe-dirty//g" "$AOSP_STAMP" || true
fi

# Ensure out dirs
mkdir -p ../out/target/product/a34x/obj/KERNEL_OBJ
mkdir -p ../out/target/product/a34x/obj/KLEAF_OBJ

# Generate build.config
echo "Generating build.config"
python3 kernel_device_modules-6.6/scripts/gen_build_config.py \
  --kernel-defconfig mediatek-bazel_defconfig \
  --kernel-defconfig-overlays "mt6877_overlay.config mt6877_teegris_5_overlay.config" \
  --kernel-build-config-overlays "" \
  -m user \
  -o ../out/target/product/a34x/obj/KERNEL_OBJ/build.config

echo "Generated build.config:"
cat ../out/target/product/a34x/obj/KERNEL_OBJ/build.config

# Exports for bazel build
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

echo "ENV:"
echo "DEVICE_MODULES_DIR=$DEVICE_MODULES_DIR"
echo "BUILD_CONFIG=$BUILD_CONFIG"
echo "OUT_DIR=$OUT_DIR"
echo "DIST_DIR=$DIST_DIR"
echo "DEFCONFIG_OVERLAYS=$DEFCONFIG_OVERLAYS"
echo "PROJECT=$PROJECT"
echo "MODE=$MODE"
echo "KERNEL_VERSION=$KERNEL_VERSION"
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

chmod +x ./kernel_device_modules-6.6/build.sh

# Debug info
echo "Checking bazel wrapper"
ls -la tools/bazel
cat tools/bazel || true
ls -la build/kernel/kleaf/bazel.sh
ls -la ../build/ 2>&1 | head -n 20 || true
ls -la prebuilts/build-tools/path/linux-x86/ | head -n 20 || true
ls -la prebuilts/kernel-build-tools/bazel/linux-x86_64/ | head -n 20 || true
df -h
free -h || true

# Run build
echo "Starting kernel build"
./kernel_device_modules-6.6/build.sh

cd "${ROOT_DIR}"

# Find and copy Image
echo "Build finished, searching for Image"
find out -name Image -type f | head -n 20
ls -lh out/target/product/a34x/obj/KLEAF_OBJ/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/ || true
ls -lh out/target/product/a34x/obj/KLEAF_OBJ/dist/ || true

SRC_IMAGE="out/target/product/a34x/obj/KLEAF_OBJ/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/Image"
if [ -f "$SRC_IMAGE" ]; then
  cp "$SRC_IMAGE" "${ROOT_DIR}/Image"
  echo "Copied Image to ${ROOT_DIR}/Image"
else
  # fallback search
  FOUND=$(find out -name Image -type f | head -n 1 || true)
  if [ -n "$FOUND" ]; then
    cp "$FOUND" "${ROOT_DIR}/Image"
    echo "Copied $FOUND to ${ROOT_DIR}/Image"
  else
    echo "ERROR: Image not found!" >&2
    find out -type f | head -n 100 >&2
    exit 1
  fi
fi

ls -lh "${ROOT_DIR}/Image"
echo "تمام! فایل Image تو ${ROOT_DIR}/Image آماده‌ست."
