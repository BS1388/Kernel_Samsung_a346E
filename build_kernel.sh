#!/bin/bash
# ============================================================
#   بیلد کرنل Samsung Galaxy A34 5G — A346E (A346EXXU9DYF4)
#
#   سورس اوپن‌سورس سامسونگ موقع export، سیم‌لینک‌ها/ساب‌ماژول‌ها رو
#   به‌صورت فایل خالی (۰ بایت) می‌شکنه. این اسکریپت قبل از بیلد
#   همه‌شون رو درست می‌کنه، بعد بیلد واقعی رو اجرا می‌کنه.
# ============================================================
set -e

ROOT_DIR="$(pwd)"

mkdir -p bin
export PATH="${ROOT_DIR}/bin:$PATH"

sudo apt-get update -y
sudo apt-get install -y curl wget unzip python3

# ---------------------------------------------------------------
# ۱) دریافت prebuilts (کامپایلر clang، ndk، jdk...) که سامسونگ
#    توی این سورس نداده. با repo sync از منیفست خود AOSP می‌گیریمش.
# ---------------------------------------------------------------
curl -s https://storage.googleapis.com/git-repo-downloads/repo > bin/repo
chmod a+x bin/repo

mkdir -p aosp-kernel && cd aosp-kernel
repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1
repo sync -c -j"$(nproc --all)"
cd "${ROOT_DIR}"

ln -sfn "${ROOT_DIR}/aosp-kernel/prebuilts" "${ROOT_DIR}/kernel/prebuilts"

# فال‌بک خودکار: اگه external/zopfli یا external/pigz رو به ریپوی خودت
# اضافه نکرده باشی (این دوتا تو زیپ دیپندنسی‌های بیزل نبودن)، از aosp-kernel قرض می‌گیریم
[ -d "${ROOT_DIR}/kernel/external/zopfli" ] || ln -sfn "${ROOT_DIR}/aosp-kernel/external/zopfli" "${ROOT_DIR}/kernel/external/zopfli"
[ -d "${ROOT_DIR}/kernel/external/pigz" ]   || ln -sfn "${ROOT_DIR}/aosp-kernel/external/pigz"   "${ROOT_DIR}/kernel/external/pigz"

cd "${ROOT_DIR}/kernel"

# ---------------------------------------------------------------
# ۲) تعمیر سیم‌لینک‌های شکسته‌ی خود سامسونگ (نکته‌ی اصلی که باعث
#    فیل شدن بیلد قبلیت شده بود: tools/bazel اصلاً وجود نداشت!)
# ---------------------------------------------------------------
ln -sfn ../kernel-6.6 kernel-6.6
ln -sfn build/kernel/kleaf/bazel.WORKSPACE WORKSPACE
ln -sfn ../build/kernel/kleaf/bazel.sh tools/bazel
chmod +x build/kernel/kleaf/bazel.sh

# چک سلامت سیم‌لینک‌ها - اگه یکی خراب باشه همینجا با پیغام واضح متوقف می‌شیم
for link in kernel-6.6 WORKSPACE tools/bazel; do
  if [ ! -e "$link" ]; then
    echo "خطا: سیم‌لینک $link خرابه یا به مسیر اشتباه اشاره می‌کنه." >&2
    ls -la "$link" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------
# ۳) خنثی کردن چک نسخه‌ی گیت (سورس export‌شده گیت واقعی نداره،
#    وگرنه kleaf سعی می‌کنه git status بگیره و ارور می‌ده)
# ---------------------------------------------------------------
sed -i "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo ''\"/g" build/kernel/kleaf/impl/stamp.bzl
sed -i "s/-maybe-dirty//g" build/kernel/kleaf/impl/stamp.bzl

# ---------------------------------------------------------------
# ۴) ساخت build.config — دقیقاً طبق build_kernel.sh رسمی خودِ
#    سامسونگ برای A346E (بدون sec_ogki_fragment.config چون اون
#    فایل فقط مال A346B هست و اصلاً تو سورس تو وجود نداره)
# ---------------------------------------------------------------
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

chmod +x ./kernel_device_modules-6.6/build.sh
./kernel_device_modules-6.6/build.sh

cd "${ROOT_DIR}"

# ---------------------------------------------------------------
# ۵) خروجی نهایی: فقط فایل Image کرنل
# ---------------------------------------------------------------
cp "out/target/product/a34x/obj/KLEAF_OBJ/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/Image" "${ROOT_DIR}/Image"

echo "تمام! فایل Image تو ${ROOT_DIR}/Image آماده‌ست."
