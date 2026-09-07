# فیکس وای‌فای/بلوتوث/هات‌اسپات بعد از تعویض کرنل — تماماً از ترموکس (بدون PC)

## چرا خراب شد؟

رام استوکه. وای‌فای/بلوتوث/هات‌اسپات روی a34x داخل خود کرنل نیستن؛ **ماژول‌های جداشدنی (`.ko`)** هستن که توی پارتیشن `vendor_dlkm` رام زندگی می‌کنن و برای **کرنل استوک سامسونگ** بیلد شدن. کرنل جدید تو vermagic و CRC سیمبل‌هاش فرق داره، پس رام دیگه نمی‌تونه اون ماژول‌های قدیمی رو لود کنه → وای‌فای/بلوتوث/هات‌اسپات مرده. دوربین/GPS چون به این ماژول‌ها وابستگی ندارن سالم موندن.

راه‌حل: ماژول‌های **هم‌ستِ کرنل جدید** رو با روت KSU نصب کن و با اسکریپت بوت KSU هر بار موقع بوت لودشون کن.

---

## مرحله ۱ — بیلد جدید و برداشتن آرتیفکت‌ها

بیلد جدید بزن (Actions ← Build A346E Kernel ← Run workflow ← گزینه `KSUN`).
از این بیلد **دو آرتیفکت** دانلود کن (الان بیلد هر دو رو میده):

- `kernel-image-…` → Image (اگه هنوز فلش نکردی، فلشش کن)
- `kernel-modules-…` → داخلش `kernel-modules.tar.xz` هست ← **این مهمه**

> فایل‌های zip آرتیفکت رو مستقیم دانلود کن تو گوشی (از مرورگر گوشی هم میشه دانلود کرد).

## مرحله ۲ — فایل‌ها برن تو گوشی

چون PC نداری: آرتیفکت `kernel-modules-….zip` رو با مرورگر گوشی دانلود کن. معمولاً می‌ره تو `Download/`.
بعد تو ترموکس (دسترسی روت داری پس Extract راحت تره):

```bash
su
cd /sdcard/Download
# اسم فایل رو با tab کامل کن؛ اکسترکت:
unzip -o "kernel-modules-*.zip" -d /data/local/tmp/ksuart
cd /data/local/tmp/ksuart
# اینجا باید kernel-modules.tar.xz باشه؛ اگه tar دستگاهت xz رو پشتیبانی کرد:
tar -xf kernel-modules.tar.xz -C /data/local/tmp/ksuart
ls /data/local/tmp/ksuart/kernel-modules
```

> اگه `tar: xz: Cannot exec` دیدی، بگو تا پچ unxz جدا بدم؛ ولی روی اکثر ترموکس‌ها با روت کار می‌کنه.

اسکریپت نصب رو هم بگیر (دو راه: دانلود خام از گیت‌هاب یا کپی-پیست):

```bash
# راه ساده — دانلود مستقیم از مخزن:
curl -L -o /data/local/tmp/install-modules-ksu.sh \
  https://raw.githubusercontent.com/BS1388/Kernel_Samsung_a346E/arena/01a07c7b-kernel-samsung-a346e/tools/install-modules-ksu.sh
```

## مرحله ۳ — نصب ماژول‌ها با روت

```bash
su
sh /data/local/tmp/install-modules-ksu.sh /data/local/tmp/ksuart/kernel-modules
```

اسکریپت این کارها رو می‌کنه:

- ماژول‌ها رو می‌ریزه تو `/data/adb/ksu_modules/lib/modules/<نسخه‌کرنل-تو>/`
- یه اسکریپت بوت KSU می‌سازه: `/data/adb/ksu/post-fs-data.d/99-load-ksu-modules.sh` که **هر بوت** ماژول‌ها رو با چند passe و به ترتیب dependency لود می‌کنه
- همون لحظه هم برای تست لودشون می‌کنه و لاگ نشون میده

خروجی موفق باید شامل خط‌هایی مثل این باشه:

```
OK  cfg80211
OK  mac80211
OK  conninfra
OK  wmt
OK  wlan_gen4m_6877
...
```

## مرحله ۴ — ریبوت و تست

```bash
su -c reboot
```

بعد از بوت، تو ترموکس:

```bash
su -c "cat /data/adb/ksu_modules/load.log" | tail -30
su -c "ls /sys/class/net"     # باید wlan0 باشه
```

وای‌فای و بلوتوث رو تست کن.

---

## اگه کار نکرد — لاگ بگیر (بدون PC، از ترموکس)

هر چیزی که از این دستورها درمیاد رو کپی کن بفرست (مرتب شماره‌گذاری شده‌ان):

```bash
su -c "cat /data/adb/ksu_modules/load.log"                     # ۱) نتیجه لود ماژول‌ها
su -c "dmesg | grep -iE 'wmt|wlan|conn|bluetooth|stp|disagrees|unknown symbol|no symbol version|invalid module format'" # ۲) ارورهای درایور
su -c "cat /proc/modules"                                      # ۳) ماژول‌های لودشده الان
su -c "cat /proc/version"                                      # ۴) نسخه کرنل در حال اجرا
su -c "ls /dev/stp* /dev/wmt* 2>/dev/null"                     # ۵) دیوایس‌نودهای چیپ کامبو
su -c "ls /vendor_dlkm/lib/modules /vendor/lib/modules 2>/dev/null | head -50"  # ۶) ماژول‌های رام
# نسخه ماژول‌های نصب‌شده برای مقایسه vermagic:
su -c "for f in /data/adb/ksu_modules/lib/modules/*/wlan*.ko /data/adb/ksu_modules/lib/modules/*/wmt*.ko; do echo == \$f; strings \$f | grep -m1 vermagic; done"
```

> کل خروجی diag یک‌جا هم موجود است:
> ```bash
> su -c "sh /data/local/tmp/diag-connectivity.sh" ; su -c "cat /data/local/tmp/diag-connectivity.txt"
> ```

این لاگ‌ها رو بفرست (متن کپی شده کافیه) تا دقیق بگم مشکل کجاست — از این جنس‌ها معمولاً یکی‌ست:

1. `disagrees about version of symbol …` → ماژول‌ها قدیمی هنوز (نصب مرحله ۳ درست انجام نشده)
2. `invalid module format` → vermagic فرق داره (ماژول از بیلد دیگه‌ایه)
3. ماژول OK ولی وای‌فای نداری → مشکل فریمور/سرویس HAL است (لاگ میگه کدوم)

---

## نکته‌های مهم

- **هر بار کرنل رو عوض کردی، ماژول‌هاش رو هم دوباره نصب کن** (مرحله ۳) — چون نسخه کرنل (و CRCها) تغییر می‌کنه.
- ماژول‌ها هیچی به Image اضافه نمی‌کنن؛ حجم Image ثابته. فقط `/data/adb/ksu_modules` فضای کمی می‌گیره.
- برای برگشتن به کرنل استوک (در صورت نیاز): فقط Image استوک رو فلش کن؛ اسکریپت بوت KSU به‌خاطر عدم تطابق vermagic ماژول‌ها رو لود نمی‌کنه و خطایی هم نمی‌ده (فقط `ERR` توی لاگ می‌نویسه).
