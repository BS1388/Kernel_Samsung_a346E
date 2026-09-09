# پروفایل عملکرد — ابزار راستی‌آزمایی و لاگ‌گیری

پچ حرارتی/کارایی برای **Samsung Galaxy A34 5G (a34x)** — MediaTek Dimensity 1080 / MT6877.

**برنچ:** `arena/01a08353-kernel-samsung-a346e` · **PR:** [#36](https://github.com/BS1388/Kernel_Samsung_a346E/pull/36)

---

## این دو اسکریپت چه کار می‌کنند

| فایل | کجا اجرا می‌شود | چه می‌دهد |
|---|---|---|
| `verify-patches.sh` | روی کامپیوتر / در repo | بررسی تک‌تکِ تغییرات، PASS/FAIL، کد خروج ۰ یا ۱ |
| `collect-thermal-log.sh` | **روی گوشی** با root | لاگ کامل برای فرستادن و بررسی رفتار واقعی |

---

## ۱) `verify-patches.sh`

```sh
bash perf-profile/verify-patches.sh            # از ریشهٔ repo
bash perf-profile/verify-patches.sh /path/to/repo
```

**نتیجهٔ فعلی: ۱۳۲ PASS / ۰ FAIL، exit 0.**

۹ بخش:

1. ساختار — پچ ۰۰۰۴ وجود دارد و `apply.sh --check` تمیز اعمال می‌شود
2. لایهٔ GKI داخل پچ — `Makefile`، اعلان‌های `thermal.h`، fallback
3. گاورنرها — `step_wise` → `instance->lower`، `power_allocator` → `allow_maximum_power()`
4. `thermal_helpers.c` — clamp کردن `target` (نه حذف فراخوانی)
5. `thermal_perf_gate.c` — ۴ تا `EXPORT_SYMBOL_GPL`، allowlist، گره‌های sysfs
6. `cpufreq_limit.c` — hard-lock سی‌پی‌یو
7. `gpuppm_legacy.c` — قفل GPU
8. `ap_thermal_limit.c` — دقیقاً ۲ نقطهٔ گیت
9. «چیزی اشتباهی دست‌نخورده» — کف ۱۱۷ °C، pristine بودن `kernel-6.6/`

### چرا GKI را از داخل *پچ* می‌سنجد؟

`kernel-6.6/` عمداً **pristine** می‌ماند — قرارداد این repo این است که GKI
فقط از راه `kernel/patches-kernel-6.6/` پچ شود. ماژول‌های فروشنده زیر
`kernel/kernel_device_modules-6.6/` هیچ patch indirection ندارند، پس مستقیم ویرایش شده‌اند.
به همین دلیل verifier برای GKI **محتوای پچ** را می‌سنجد و برای فروشنده **فایل زنده** را —
و بخش ۹ تأیید می‌کند که درخت GKI واقعاً دست‌نخورده است.

### تست منفی (اثبات اینکه بررسی‌ها توخالی نیستند)

روی کامیت پایهٔ بدون پچ (`ab5fb69c3`) اجرا شد:

```
نتیجه:  15 PASS   /   51 FAIL      exit code: 1
```

آن ۱۵ PASS همان بررسی‌های «pristine بودن» هستند که *باید* روی کد دست‌نخورده پاس شوند.

---

## ۲) `collect-thermal-log.sh`

لاگ را **خودش** در این مسیر ذخیره می‌کند و در پایان مسیر و اندازه را چاپ می‌کند:

```
/storage/emulated/0/Download/thermal-log-<YYYYmmdd-HHMMSS>.txt
```

```sh
adb push perf-profile/collect-thermal-log.sh /data/local/tmp/

# حالت معمولی — بدون هیچ redirect، فایل خودش ذخیره می‌شود
adb shell "su -c 'sh /data/local/tmp/collect-thermal-log.sh'"

# زیر بار — هم‌زمان یک بازی/benchmark سنگین اجرا کن
adb shell "su -c 'sh /data/local/tmp/collect-thermal-log.sh --watch 30'"

# برداشتن فایل
adb pull /storage/emulated/0/Download/thermal-log-<تاریخ>.txt
```

| گزینه | کار |
|---|---|
| `--watch [N]` | بخش ۱۴: نمونهٔ زمانی N ثانیه‌ای (پیش‌فرض ۲۰) |
| `--dir PATH` | مسیر ذخیرهٔ دیگر |
| `--stdout` | هم‌زمان روی صفحه هم چاپ شود (نیاز به `tee`) |

### اگر نوشتن در `Download` شکست بخورد

روی اندروید نوشتنِ روت به `/storage/emulated/0/` گاهی به SELinux می‌خورد.
اسکریپت خودش زنجیرهٔ fallback دارد:

```
/storage/emulated/0/Download → /sdcard/Download → /storage/emulated/0 → /data/local/tmp
```

و در آخر اگر مسیر اصلی بعداً قابل نوشتن شد، فایل را آنجا کپی می‌کند.
اگر هیچ‌کدام نشد، با exit 1 و راهنمای مشخص شکست می‌خورد — **ساکت شکست نمی‌خورد**.
تأیید نوشتن با `[ -s "$OUT" ]` انجام می‌شود و اندازه/تعداد خط چاپ می‌گردد.

### تست‌شده

| سناریو | نتیجه |
|---|---|
| `sh -n` + `dash -n` | pass |
| مسیر پیش‌فرض `/storage/emulated/0/Download` | فایل ۱۱٬۹۲۲ بایت / ۲۰۴ خط، exit 0 |
| `--watch 3` | ۲۱۲ خط، بخش ۱۴ با ۳ ردیف CSV |
| `--dir` غیرقابل‌نوشت | درست fallback کرد به `/data/local/tmp` |
| `--stdout` | ۲۱۱ خط روی صفحه + همهٔ ۱۵ بخش در فایل |
| هیچ مسیر قابل نوشتن نبود | exit 1 با راهنما، بدون فایل خالی |

### ۱۵ بخش — این‌ها از همه مهم‌ترند

| بخش | چه چیزی ثابت می‌کند |
|---|---|
| ۱ | `/sys/kernel/thermal_perf/enabled` → گیت اصلاً در Image هست؟ |
| ۳ | همهٔ `cooling_device*/cur_state` باید ۰ باشند جز allowlist |
| ۴ | فرکانس CPU روی سقف مانده یا افت می‌کند |
| ۶ | `/proc/gpufreqv2/limit_table` → سقف/کف `LIMIT_THERMAL_AP/_EB/PBM` باید ۰ باشد |
| ۷ | `/proc/clatm` → بودجهٔ توان ATM محدود شده یا نه |
| ۱۰ | `/proc/sspm_thermal_throttle` → تنها مسیری که از کرنل قابل کنترل نیست |

### منشأ مسیرها

**هیچ مسیری حدس زده نشده** — همه از `proc_create()` / `proc_mkdir()` /
`kobject_create_and_add()` خودِ سورس استخراج شده‌اند. چند مورد که با
جست‌وجو در سورس اصلاح شدند:

- دایرکتوری GPU **`/proc/gpufreqv2`** است (`gpufreq_debug_legacy.h:12`)، نه `/proc/gpufreq`
- `/proc/sspm_thermal_throttle` را `mtk_ts_cpu_noBankv2.c` هم می‌سازد، و آن فایل
  برای mt6877 build می‌شود → روی A34 **موجود است**
- `/proc/pmic_current_limit`، `/proc/set_sspm_big_limit_threshold` و `/proc/cldebug`
  برای mt6877 **build نمی‌شوند** — دیدن `[موجود نیست]` برای اینها طبیعی است
- `cpufreq_limit` زیر `bus_get_dev_root(&cpu_subsys)` است → `/sys/devices/system/cpu/cpufreq_limit/`

---

## ۳) دو سیاست مستقل

این مهم‌ترین نکتهٔ معماری است — **این دو از هم جدا هستند:**

| | سیاست | وابسته به governor؟ |
|---|---|---|
| **۱. سرکوب حرارتی** | **دائمی و بی‌قید.** کرنل هرگز به‌خاطر دما throttle یا downclock نمی‌کند | ❌ نه — همیشه خاموش |
| **۲. قفل فرکانس** | CPU (big + LITTLE) و GPU روی سقف سخت‌افزاری | ✅ بله — فقط در حالت عملکرد |

یعنی خروج از حالت عملکرد، DVFS معمولی را برمی‌گرداند ولی **throttle حرارتی را برنمی‌گرداند.**

```c
bool thermal_perf_gate_thermal_off(void);   /* همیشه true — سیاست ۱ */
bool thermal_perf_gate_enabled(void);       /* حالت عملکرد — سیاست ۲ */
bool thermal_perf_gate_blocked(const char *cdev_type);  /* بی‌قید، جز allowlist */
int  thermal_perf_gate_register_notifier(struct notifier_block *nb);
int  thermal_perf_gate_unregister_notifier(struct notifier_block *nb);
void thermal_perf_gate_set_auto_perf(bool any_perf);   /* از cpufreq.c */
```

### هر دو مسیر actuation در فریمورک حرارتی بسته است

در کل `drivers/thermal/` گیت فقط **دو** فراخوانی مستقیم `cdev->ops->set_cur_state()`
وجود دارد و هر دو گیت شده‌اند — پس هیچ governor‌ای نمی‌تواند از کنارش رد شود:

| مسیر | مکان | وضعیت |
|---|---|---|
| همهٔ governorها (`step_wise`, `bang_bang`, `fair_share`, `power_allocator`) | `thermal_helpers.c:170` داخل `thermal_cdev_set_cur_state()` | ✅ `target = 0` |
| نوشتن دستی از userspace (HAL حرارتی فروشنده / `init.rc` / `adb shell`) | `thermal_sysfs.c` داخل `cur_state_store()` | ✅ `state = 0` |

`gov_user_space` هیچ actuator‌ای ندارد (فقط `kobject_uevent_env`)، و بای‌پس
بودجهٔ توان IPA در `gov_power_allocator.c` هم با `thermal_perf_gate_thermal_off()`
**بی‌قید** است — نه مشروط به حالت عملکرد.

### استثناهای ایمنی — عمداً و غیرقابل‌خاموش‌کردن

`thermal_perf_gate_blocked()` بی‌قید است **جز** برای allowlist ایمنی. این‌ها هیچ‌وقت
سرکوب نمی‌شوند و کلید خاموش هم ندارند:

```
bcct · charger · batt · shutdown · kshutdown · sysrst
```

یعنی محدودسازی جریان شارژ باتری، خاموشی حرارتی و ریست سیستم سر جایشان‌اند،
و کف خاموشی سخت‌افزاری LVTS ‏(۱۱۷ °C) دست‌نخورده است. «خاموش‌کردن همهٔ throttle»
به downclock شدن فرکانس اشاره دارد، نه به محافظت باتری یا خاموشی اضطراری.

### سه حالت

| حالت | رفتار |
|---|---|
| **`auto`** (پیش‌فرض) | governor ‏`performance` کلید است. تا وقتی حداقل یک policy روی آن است گیت فعال است؛ به محض رفتن آخرین policy به `schedutil` / `sugov_ext` / هر چیز دیگر، گیت غیرفعال می‌شود |
| `on` | صرف‌نظر از governor، فعالِ پین‌شده |
| `off` | صرف‌نظر از governor، غیرفعالِ پین‌شده |

```sh
echo auto > /sys/kernel/thermal_perf/mode    # governor براند (پیش‌فرض)
echo on   > /sys/kernel/thermal_perf/mode    # دستی روشن
echo off  > /sys/kernel/thermal_perf/mode    # دستی خاموش

echo 1 > /sys/kernel/thermal_perf/enabled    # معادل mode=on
echo 0 > /sys/kernel/thermal_perf/enabled    # معادل mode=off
cat    /sys/kernel/thermal_perf/stats        # وضعیت مؤثر + شمارنده‌ها
```

مکانیزم: `cpufreq_init_governor()` و `cpufreq_exit_governor()` هر دو
`cpufreq_perf_gate_sync()` را صدا می‌زنند که **همهٔ CPUهای online را اسکن می‌کند
و نتیجه را گزارش می‌دهد** (نه دلتای هر policy). این یعنی idempotent است —
فراخوانی تکراری یا `governor->init()` ناموفق نمی‌تواند گیت را در وضعیت غلط
قفل کند.

### برگشت‌پذیری کامل

خروج از حالت عملکرد **revert کامل** است، نه ریست به کارخانه:

| مصرف‌کننده | هنگام خروج چه می‌کند |
|---|---|
| `cpufreq_limit.c` | snapshot ‏`min_req`/`max_req`/`freq_input` را که در لبهٔ صعودی گرفته بود **دقیقاً** برمی‌گرداند. کلاینت‌های دیگر (Input Booster، userspace maxlock) هرچه قبل از ورود داشتند حفظ می‌شود |
| `gpuppm_legacy.c` | سه limiter حرارتی به `GPUPPM_DEFAULT_IDX` برمی‌گردند (همان مقدار اولیه‌شان)، سپس `__gpuppm_sort_limit()` + `__gpuppm_limit_effective()` |
| `thermal_helpers.c` / گاورنرها | فقط clamp متوقف می‌شود؛ هیچ حالتی ریست نمی‌شود |

هیچ‌کدام نیاز به reboot ندارند.

### allowlist — چیزهایی که عمداً فعال می‌مانند

با `strstr()` روی رشتهٔ `type` مطابقت داده می‌شوند، پس پسوند عددی مهم نیست:

```
"bcct"  "charger"  "batt"  "shutdown"  "kshutdown"  "sysrst"
```

### گره‌های sysfs

| مسیر | حالت |
|---|---|
| `/sys/kernel/thermal_perf/mode` | `0644` — `auto` / `on` / `off` |
| `/sys/kernel/thermal_perf/enabled` | `0644` — وضعیت مؤثر؛ نوشتن = پین کردن |
| `/sys/kernel/thermal_perf/allow_list` | `0444` |
| `/sys/kernel/thermal_perf/allow_extra` | `0200` (فقط‌نوشتنی) |
| `/sys/kernel/thermal_perf/stats` | `0444` — `enabled` + `mode` + `perf_governor` + شمارنده‌ها |

```sh
echo schedutil > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/kernel/thermal_perf/stats   # باید enabled=0 شود
```

---

## ۴) آن چه هنوز ثابت نشده

| مورد | وضعیت |
|---|---|
| بیلد | ⏳ آخرین بیلد سبز `34311661678` روی `33cbe8d6d` — ۷/۷. بیلد `3ff197743` دستی کنسل شد؛ بیلدِ این commit در راه است |
| وجود تک‌تک تغییرات در سورس | ✅ `verify-patches.sh` → **۱۳۲ PASS / ۰ FAIL** (بخش‌های ۱–۹ + ۳b/۸b/۸c/۸d/۸e/۸f) |
| جامعیت مسیرهای actuation | ✅ بخش ۳b: در کل فریمورک حرارتی GKI فقط ۲ فراخوانی `ops->set_cur_state()` هست، هر دو گیت شده |
| مسیرهای کامپایل‌نشدنی | ✅ بخش ۸f: Mali kbase devfreq/IPA (بلوک mt6877 در Makefile مالِ Mali وجود ندارد)، GED (`CONFIG_MTK_LEGACY_THERMAL=m`)، `gpufreq_mt6877.c` (متغیر مرده + ورودی جدول توان) |
| **رفتار روی سخت‌افزار واقعی** | ❌ **تست نشده.** بیلد سبز ≠ رفتار درست. باید با `collect-thermal-log.sh` روی A34 تأیید شود |
| DVFS سمت SSPM | ❌ `CONFIG_MTK_TINYSYS_SSPM_SUPPORT=m` — firmware است، از کرنل قابل پچ نیست. تشخیصش بخش ۱۰ لاگ است |
| کف خاموشی سخت‌افزاری LVTS | 🔒 **۱۱۷ °C** (`noBankv2.c:157`) عمداً دست‌نخورده — این عدد خودش vendor-critical است |
