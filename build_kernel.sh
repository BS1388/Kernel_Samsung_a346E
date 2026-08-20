#!/bin/bash
set -e

ROOT_DIR="$(pwd)"

mkdir -p bin
export PATH="${ROOT_DIR}/bin:$PATH"

sudo apt-get update -y
sudo apt-get install -y curl wget unzip python3


curl -s https://storage.googleapis.com/git-repo-downloads/repo > bin/repo
chmod a+x bin/repo

mkdir -p aosp-kernel && cd aosp-kernel
repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1
repo sync -c -j"$(nproc --all)"

cd prebuilts/clang/host/linux-x86
wget -O clang-r536225.tar.gz https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main-kernel-2025/clang-r536225.tar.gz
mkdir -p clang-r536225
cd clang-r536225
tar xvzf ../clang-r536225.tar.gz
rm ../clang-r536225.tar.gz
cd ../kleaf
sed -i '/# keep sorted/a\    "r536225",' versions.bzl
cd "${ROOT_DIR}/aosp-kernel"

cd "${ROOT_DIR}"

ln -sfn "${ROOT_DIR}/aosp-kernel/prebuilts" "${ROOT_DIR}/kernel/prebuilts"


[ -d "${ROOT_DIR}/kernel/external/zopfli" ] || ln -sfn "${ROOT_DIR}/aosp-kernel/external/zopfli" "${ROOT_DIR}/kernel/external/zopfli"
[ -d "${ROOT_DIR}/kernel/external/pigz" ]   || ln -sfn "${ROOT_DIR}/aosp-kernel/external/pigz"   "${ROOT_DIR}/kernel/external/pigz"

cd "${ROOT_DIR}/kernel"


ln -sfn ../kernel-6.6 kernel-6.6
ln -sfn build/bazel_mgk_rules/kleaf/bazel.WORKSPACE WORKSPACE
ln -sfn ../build/kernel/kleaf/bazel.sh tools/bazel
chmod +x build/kernel/kleaf/bazel.sh


for link in kernel-6.6 WORKSPACE tools/bazel; do
  if [ ! -e "$link" ]; then
    echo "خطا: سیم‌لینک $link خرابه یا به مسیر اشتباه اشاره می‌کنه." >&2
    ls -la "$link" >&2
    exit 1
  fi
done


sed -i "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo ''\"/g" build/kernel/kleaf/impl/stamp.bzl
sed -i "s/-maybe-dirty//g" build/kernel/kleaf/impl/stamp.bzl


python3 kernel_device_modules-6.6/scripts/gen_build_config.py \
  --kernel-defconfig mediatek-bazel_defconfig \
  --kernel-defconfig-overlays "mt6877_overlay.config mt6877_teegris_5_overlay.config" \
  --kernel-build-config-overlays "" \
  -m user \
  -o ../out/target/product/a34x/obj/KERNEL_OBJ/build.config

export DEVICE_MODULES_DIR="kernel_device_modules-6.6"
export BUILD_CONFIG="../out/target/product/a34x/obj/KERNEL_OBJ/build.config"
export OUT_DIR="../out/target/product/a34x/obj/KLEAF_OBJ"
export DIST_DIR="../out/target/product/a34x/obj/KLEAF_OBJ/dist"
export DEFCONFIG_OVERLAYS="mt6877_overlay.config mt6877_teegris_5_overlay.config"
export PROJECT="mgk_64_k66"
export MODE="user"

export KERNEL_VERSION="kernel-6.6"
export SOURCE_DATE_EPOCH="$(date +%s)"
# TODO: این مقدار برای A346B بود، برای گوشی خودتون از Settings > About phone > Software info بگیرید و جایگزین کنید
export SEC_BUILDNUMBER="ogkiA346EPLACEHOLDER"

chmod +x ./kernel_device_modules-6.6/build.sh
./kernel_device_modules-6.6/build.sh

cd "${ROOT_DIR}"


cp "out/target/product/a34x/obj/KLEAF_OBJ/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/Image" "${ROOT_DIR}/Image"

echo "تمام! فایل Image تو ${ROOT_DIR}/Image آماده‌ست."

# ---- فقط اگر روت انتخاب شده باشه، boot.img رو دانلود و ری‌پک می‌کنیم ----
# KSU_VAR از env سطح workflow میاد (NO-ROOT به‌صورت پیش‌فرض)
# هشدار: این boot.img پایه از ریلیز a34x عمومیه (Fede2782)، نه لزوماً فریمور a346E.
# قبل از فلش با Odin حتماً چک کنید نسخه‌ش با فریمور فعلی گوشیتون همخونی داره.
if [ "${KSU_VAR:-NO-ROOT}" != "NO-ROOT" ]; then
  echo ">>> KSU_VAR=$KSU_VAR -> در حال ساخت boot.img روت‌شده"

  wget -O boot.img https://github.com/Fede2782/proprietary_vendor_samsung_a34x/releases/latest/download/boot.img

  mkdir -p bootimg && cd bootimg
  "$MBOOT" unpack ../boot.img
  cp "${ROOT_DIR}/Image" kernel
  PATCHVBMETAFLAG=true "$MBOOT" repack ../boot.img out-boot.img
  mv out-boot.img ../boot.img
  cd "${ROOT_DIR}"
else
  echo ">>> NO-ROOT انتخاب شده — فقط Image ساخته میشه، boot.img ری‌پک نمیشه."
fi
