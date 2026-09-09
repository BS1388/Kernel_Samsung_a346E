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

**نتیجهٔ فعلی: ۶۶ PASS / ۰ FAIL، exit 0.**

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

## ۳) API گیت

```c
bool thermal_perf_gate_enabled(void);
bool thermal_perf_gate_blocked(const char *cdev_type);
int  thermal_perf_gate_register_notifier(struct notifier_block *nb);
int  thermal_perf_gate_unregister_notifier(struct notifier_block *nb);
```

همه با `EXPORT_SYMBOL_GPL` صادر شده‌اند (`CONFIG_TRIM_UNUSED_KSYMS` خاموش است).
`thermal_perf_gate_init()` با **`postcore_initcall`** اجرا می‌شود تا قبل از
thermal subsys آماده باشد.

### allowlist — چیزهایی که عمداً فعال می‌مانند

با `strstr()` روی رشتهٔ `type` مطابقت داده می‌شوند، پس پسوند عددی مهم نیست:

```
"bcct"  "charger"  "batt"  "shutdown"  "kshutdown"  "sysrst"
```

### گره‌های sysfs

| مسیر | حالت |
|---|---|
| `/sys/kernel/thermal_perf/enabled` | `0644` |
| `/sys/kernel/thermal_perf/allow_list` | `0444` |
| `/sys/kernel/thermal_perf/allow_extra` | `0200` (فقط‌نوشتنی) |
| `/sys/kernel/thermal_perf/stats` | `0444` |

```sh
echo 1 > /sys/kernel/thermal_perf/enabled    # روشن
cat /sys/kernel/thermal_perf/stats
echo 0 > /sys/kernel/thermal_perf/enabled    # برگشت به رفتار استوک
```

**پیش‌فرض = خاموش.** بوت دستگاه کاملاً استوک است.

---

## ۴) آن چه هنوز ثابت نشده

| مورد | وضعیت |
|---|---|
| بیلد | ✅ CI run `34298797542` روی `fa954a243` — ۷/۷ سبز، بیلد ۵۹ دقیقه و ۲۸ ثانیه |
| وجود تک‌تک تغییرات در سورس | ✅ `verify-patches.sh` → ۶۶ PASS / ۰ FAIL |
| **رفتار روی سخت‌افزار واقعی** | ❌ **تست نشده.** بیلد سبز ≠ رفتار درست. باید با `collect-thermal-log.sh` روی A34 تأیید شود |
| DVFS سمت SSPM | ❌ `CONFIG_MTK_TINYSYS_SSPM_SUPPORT=m` — firmware است، از کرنل قابل پچ نیست. تشخیصش بخش ۱۰ لاگ است |
| کف خاموشی سخت‌افزاری LVTS | 🔒 **۱۱۷ °C** (`noBankv2.c:157`) عمداً دست‌نخورده — این عدد خودش vendor-critical است |
