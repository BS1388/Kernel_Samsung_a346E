#!/usr/bin/env bash
# =============================================================================
# verify-patches.sh
#
# راستی‌آزمایی تک‌تکِ تغییرات پروفایل عملکرد، جدا از هم.
# هر بررسی یک خط PASS/FAIL می‌دهد تا بتوانی خودت ببینی کدام落地 شده.
#
#   bash verify-patches.sh              # از ریشهٔ repo اجرا شود
#   bash verify-patches.sh /path/to/repo
#
# کد خروج: 0 اگر همه PASS باشند، 1 اگر حتی یکی FAIL باشد.
#
# نکتهٔ معماری: فایل‌های GKI (kernel-6.6/) عمداً pristine می‌مانند و
# تغییراتشان داخل kernel/patches-kernel-6.6/0004-thermal-perf-gate.patch است.
# پس برای GKI محتوای *پچ* سنجیده می‌شود، و برای ماژول‌های فروشنده
# (که patch indirection ندارند) فایل *زنده*.
# =============================================================================

set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# -----------------------------------------------------------------------------
# نگهبان: این اسکریپت فقط داخل checkout گیتِ کرنل معنی دارد، نه روی گوشی.
# اگر بیرون از repo اجرا شود، به‌جای چاپ ده‌ها FAIL گمراه‌کننده، صریح می‌ایستد.
# -----------------------------------------------------------------------------
if [ ! -f "$ROOT/kernel/patches-kernel-6.6/0004-thermal-perf-gate.patch" ] \
   && [ ! -d "$ROOT/kernel/kernel_device_modules-6.6" ]; then
  cat <<'EOF'

========================================================================
 این اسکریپت اینجا کار نمی‌کند.
========================================================================

 verify-patches.sh سورسِ کرنل را می‌سنجد، پس باید داخل checkout گیتِ
 repo اجرا شود — نه روی گوشی و نه در Termux.

 اینجا پیدا نشد:
   kernel/patches-kernel-6.6/0004-thermal-perf-gate.patch
   kernel/kernel_device_modules-6.6/

 ------------------------------------------------------------------------
 روی گوشی / در Termux فقط این یکی را اجرا کن:

   sh collect-thermal-log.sh

 لاگ را خودش در /storage/emulated/0/Download/ ذخیره می‌کند.
 ------------------------------------------------------------------------
EOF
  echo " مسیر فعلی: $ROOT"
  echo
  exit 2
fi

cd "$ROOT" || { echo "repo root پیدا نشد: $ROOT"; exit 2; }

PATCH="kernel/patches-kernel-6.6/0004-thermal-perf-gate.patch"
GKI="kernel-6.6"
VEND="kernel/kernel_device_modules-6.6"
CPUF="$VEND/drivers/cpufreq/cpufreq_limit.c"
GPUP="$VEND/drivers/gpu/mediatek/gpufreq/v2_legacy/gpuppm_legacy.c"
ATM="$VEND/drivers/misc/mediatek/thermal/common/ap_thermal_limit.c"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
sec()  { printf '\n=== %s ===\n' "$1"; }

# chk <توضیح> <فایل> <الگوی grep -E>
chk() {
  if grep -qE "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1   [$2 :: $3]"; fi
}
# chkp <توضیح> <الگو>  → داخل پچ ۰۰۰۴
chkp() {
  if grep -qE "$2" "$PATCH" 2>/dev/null; then ok "$1"; else bad "$1   [patch :: $2]"; fi
}
# absc <توضیح> <فایل> <الگو>  → باید *نباشد*
absc() {
  if grep -qE "$3" "$2" 2>/dev/null; then bad "$1   (پیدا شد، نباید می‌بود)"; else ok "$1"; fi
}

echo "repo root : $ROOT"
echo "HEAD      : $(git rev-parse --short HEAD 2>/dev/null || echo 'n/a')"

# -----------------------------------------------------------------------------
sec "1) ساختار: پچ ۰۰۰۴ وجود دارد و تمیز اعمال می‌شود"
[ -f "$PATCH" ] && ok "پچ ۰۰۰۴ وجود دارد ($(wc -l < "$PATCH") خط)" \
                || bad "پچ ۰۰۰۴ وجود ندارد"
chkp "فایل جدید thermal_perf_gate.c در پچ ساخته می‌شود" '^\+\+\+ b/drivers/thermal/thermal_perf_gate\.c'
chkp "فایل جدید با --- /dev/null اعلام شده" '^--- /dev/null'
chkp "new file mode در پچ هست" '^new file mode 100644'
if [ -f "kernel/patches-kernel-6.6/apply.sh" ]; then
  if bash kernel/patches-kernel-6.6/apply.sh --check >/tmp/_apply.out 2>&1; then
    ok "apply.sh --check  (همهٔ پچ‌ها روی pristine اعمال می‌شوند)"
  else
    bad "apply.sh --check شکست خورد"; sed 's/^/        /' /tmp/_apply.out | tail -5
  fi
else
  bad "apply.sh پیدا نشد"
fi

# -----------------------------------------------------------------------------
sec "2) لایهٔ GKI — داخل پچ ۰۰۰۴ (فایل‌های زنده عمداً pristine‌اند)"
chkp "Makefile: thermal_perf_gate.o به thermal_sys-y اضافه شده" '^\+thermal_sys-y.*thermal_perf_gate\.o'
chkp "thermal.h: اعلان thermal_perf_gate_enabled" '^\+bool thermal_perf_gate_enabled\(void\);'
chkp "thermal.h: اعلان thermal_perf_gate_blocked" '^\+bool thermal_perf_gate_blocked\(const char \*cdev_type\);'
chkp "thermal.h: اعلان register_notifier" '^\+int thermal_perf_gate_register_notifier'
chkp "thermal.h: اعلان unregister_notifier" '^\+int thermal_perf_gate_unregister_notifier'
chkp "thermal.h: fallback برای حالت غیرفعال (inline return false)" '^\+static inline bool thermal_perf_gate_enabled\(void\) \{ return false; \}'

# -----------------------------------------------------------------------------
sec "3) گاورنرهای حرارتی — داخل پچ ۰۰۰۴"
chkp "step_wise: وقتی گیت فعال است instance->lower برمی‌گردد" '^\+[[:space:]][[:space:]]return instance->lower;'
chkp "step_wise: شرط thermal_perf_gate_blocked" 'thermal_perf_gate_blocked\(cdev->type\)'
chkp "power_allocator: صدا زدن allow_maximum_power()" '^\+[[:space:]][[:space:]]allow_maximum_power\(tz, update\);'
chkp "power_allocator: صدا زدن reset_pid_controller()" '^\+[[:space:]][[:space:]]reset_pid_controller\(params\);'
chkp "power_allocator: بای‌پس IPA «بی‌قید» است (thermal_off، نه enabled)" \
     '^\+[[:space:]]if \(thermal_perf_gate_thermal_off\(\)\) \{'
# هانک IPA باید *هیچ* شرط مشروط‌به‌حالت‑پرفورمنس نداشته باشد
IPA_HUNK=$(awk '/^\+\+\+ b\/drivers\/thermal\/gov_power_allocator\.c/{f=1;next} /^\+\+\+ b\//{f=0} f' "$PATCH")
if printf '%s\n' "$IPA_HUNK" | grep -qE '^\+.*thermal_perf_gate_enabled\(\)'; then
  bad "power_allocator: هنوز شرط مشروط thermal_perf_gate_enabled() دارد"
else
  ok "power_allocator: هیچ شرط مشروط thermal_perf_gate_enabled() باقی نمانده"
fi

# -----------------------------------------------------------------------------
sec "3b) جامعیت: همهٔ مسیرهای actuation در فریمورک حرارتی GKI بسته‌اند"
THERM="$GKI/drivers/thermal"
N_CALLS=$(grep -rn 'ops->set_cur_state(' "$THERM"/*.c 2>/dev/null | wc -l)
if [ "$N_CALLS" -eq 2 ]; then
  ok "فقط ۲ فراخوانی ops->set_cur_state() در کل فریمورک حرارتی GKI وجود دارد"
else
  bad "تعداد فراخوانی‌های ops->set_cur_state() = $N_CALLS (انتظار ۲)"
fi
chkp "مورد ۱: thermal_helpers.c بعد از clamp گیت است" \
     '^\+[[:space:]]if \(target && thermal_perf_gate_blocked\(cdev->type\)\)'
chkp "مورد ۲: thermal_sysfs.c cur_state_store هم گیت شده" \
     '^\+[[:space:]]if \(state && thermal_perf_gate_blocked\(cdev->type\)\)'
for g in gov_step_wise gov_bang_bang gov_fair_share gov_power_allocator; do
  if grep -qE '__thermal_cdev_update|thermal_cdev_update' "$THERM/$g.c" 2>/dev/null; then
    ok "$g تنها از راه thermal_cdev_update() به cooling device می‌رسد (→ گیت)"
  else
    bad "$g مسیر مستقیم دیگری دارد"
  fi
done
absc "gov_user_space هیچ actuator‌ای ندارد (فقط uevent)" "$THERM/gov_user_space.c" 'set_cur_state'

# -----------------------------------------------------------------------------
sec "4) thermal_helpers.c — نقطهٔ گلوگاه همهٔ cooling deviceها"
chkp "clamp کردن target (نه حذف فراخوانی) تا حسابداری cdev سالم بماند" '^\+[[:space:]][[:space:]]target = 0;'
chkp "شرط: فقط وقتی target غیرصفر است" '^\+[[:space:]]if \(target && thermal_perf_gate_blocked\(cdev->type\)\)'

# -----------------------------------------------------------------------------
sec "5) thermal_perf_gate.c — هستهٔ گیت"
chkp "kobject زیر kernel_kobj با نام thermal_perf" 'kobject_create_and_add\("thermal_perf", kernel_kobj\)'
chkp "init با postcore_initcall (قبل از thermal subsys)" '^\+postcore_initcall\(thermal_perf_gate_init\);'
chkp "EXPORT_SYMBOL_GPL(thermal_perf_gate_enabled)" '^\+EXPORT_SYMBOL_GPL\(thermal_perf_gate_enabled\);'
chkp "EXPORT_SYMBOL_GPL(thermal_perf_gate_blocked)" '^\+EXPORT_SYMBOL_GPL\(thermal_perf_gate_blocked\);'
chkp "EXPORT_SYMBOL_GPL(register_notifier)" '^\+EXPORT_SYMBOL_GPL\(thermal_perf_gate_register_notifier\);'
chkp "EXPORT_SYMBOL_GPL(unregister_notifier)" '^\+EXPORT_SYMBOL_GPL\(thermal_perf_gate_unregister_notifier\);'
chkp "تابع tpg_type_allowed()" '^\+static bool tpg_type_allowed\(const char \*type\)'
chkp "شمارندهٔ tpg_suppressed" 'tpg_suppressed\+\+'
chkp "شمارندهٔ tpg_allowed" 'tpg_allowed\+\+'
echo "  --- allowlist (چیزهایی که عمداً فعال می‌مانند) ---"
for a in '"bcct"' '"charger"' '"batt"' '"shutdown"' '"kshutdown"' '"sysrst"'; do
  chkp "  allowlist شامل $a" "^\+[[:space:]]$a,"
done
echo "  --- گره‌های sysfs ---"
chkp "sysfs: enabled   (0644 خواندنی/نوشتنی)" '__ATTR\(enabled, 0644, enabled_show, enabled_store\)'
chkp "sysfs: allow_list (0444 فقط‌خواندنی)" '__ATTR\(allow_list, 0444, allow_list_show, NULL\)'
chkp "sysfs: allow_extra (0200 فقط‌نوشتنی)" '__ATTR\(allow_extra, 0200, NULL, allow_extra_store\)'
chkp "sysfs: stats      (0444 فقط‌خواندنی)" '__ATTR\(stats, 0444, stats_show, NULL\)'
chkp "پیام ENGAGED موقع فعال‌سازی (با ذکر mode و governor)" 'ENGAGED - software thermal mitigation suppressed'
chkp "پیام DISENGAGED موقع غیرفعال‌سازی" 'DISENGAGED - previous behaviour restored'

# -----------------------------------------------------------------------------
sec "6) cpufreq_limit.c — hard-lock سی‌پی‌یو (فایل زنده)"
[ -f "$CPUF" ] && ok "فایل موجود است" || bad "فایل موجود نیست: $CPUF"
chk "استفاده از thermal_perf_gate_enabled()" "$CPUF" 'thermal_perf_gate_enabled\(\)'
chk "ثبت notifier در init" "$CPUF" 'thermal_perf_gate_register_notifier\(&cpufreq_limit_perf_gate_nb\)'
chk "unregister در exit" "$CPUF" 'thermal_perf_gate_unregister_notifier\(&cpufreq_limit_perf_gate_nb\)'
chk "بررسی وضعیت گیت موقع بارگذاری ماژول" "$CPUF" '^[[:space:]]if \(thermal_perf_gate_enabled\(\)\) \{'
chk "پیام hard-locked ... (gate engaged)" "$CPUF" 'hard-locked little=%u big=%u \(gate engaged\)'
chk "توضیح hard-lock to peak در کامنت" "$CPUF" 'hard-lock to peak'
echo "  --- چیزهایی که باید دست‌نخورده مانده باشند ---"
chk "ltl_cpu_start هنوز 0 است" "$CPUF" '\.ltl_cpu_start[[:space:]]*=[[:space:]]*0'
chk "big_cpu_start هنوز 6 است" "$CPUF" '\.big_cpu_start[[:space:]]*=[[:space:]]*6'

# -----------------------------------------------------------------------------
sec "7) gpuppm_legacy.c — قفل GPU روی بالاترین OPP (فایل زنده)"
[ -f "$GPUP" ] && ok "فایل موجود است" || bad "فایل موجود نیست: $GPUP"
chk "تابع gpuppm_gate_release() تعریف شده" "$GPUP" '^static void gpuppm_gate_release\('
chk "زنجیرهٔ notifier ثبت می‌شود" "$GPUP" 'thermal_perf_gate_register_notifier\(&gpuppm_gate_nb\)'
chk "پیام [GATE] performance mode: GPU pinned to peak OPP" "$GPUP" '\[GATE\] performance mode: GPU pinned to peak OPP'
chk "پیام [GATE] خروج از perf mode و آزاد شدن DVFS" "$GPUP" '\[GATE\] performance mode off: GPU DVFS released'
chk "gate روی stack limit table هم اعمال می‌شود (dual-buck)" "$GPUP" 'gpuppm_gate_release\(g_stack_limit_table\)'
chk "gate روی limit table اصلی اعمال می‌شود" "$GPUP" 'gpuppm_gate_release\(g_gpu_limit_table\)'
absc "تابع ساختگی gpuppm_reset_limit() صدا زده نمی‌شود" "$GPUP" 'gpuppm_reset_limit'

# -----------------------------------------------------------------------------
sec "8) ap_thermal_limit.c — مسیر ATM/DTM → بودجهٔ توان PPM (فایل زنده)"
[ -f "$ATM" ] && ok "فایل موجود است" || bad "فایل موجود نیست: $ATM"
chk "خنثی‌سازی بودجهٔ توان CPU (دائمی)" "$ATM" '^[[:space:]]if \(thermal_perf_gate_thermal_off\(\)\)'
chk "final_limit = 0x7FFFFFFF (سنتینل «بدون محدودیت» خودِ فایل)" "$ATM" 'final_limit = 0x7FFFFFFF;'
N=$(grep -cE '^[[:space:]]if \(thermal_perf_gate_thermal_off\(\)\)' "$ATM")
[ "$N" -eq 2 ] && ok "دقیقاً ۲ نقطهٔ خنثی‌سازی (CPU و GPU)" \
               || bad "تعداد نقاط خنثی‌سازی = $N، انتظار ۲"

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
sec "8b) رانندگی خودکار با governor (cpufreq.c — داخل پچ ۰۰۰۴)"
CPUFSRC="$PATCH"
chkp "cpufreq.c هم جزو پچ است" '^\+\+\+ b/drivers/cpufreq/cpufreq\.c'
chkp "include <linux/thermal.h> به cpufreq.c اضافه شده" '^\+#include <linux/thermal\.h>'
chkp "تابع cpufreq_perf_gate_sync() تعریف شده" '^\+static void cpufreq_perf_gate_sync\(void\)'
chkp "پیمایش با cpufreq_cpu_get_raw (بدون قفل سراسری)" '^\+[[:space:]]+policy = cpufreq_cpu_get_raw\(cpu\);'
chkp "مقایسهٔ نام governor با \"performance\"" 'strcmp\(policy->governor->name, "performance"\)'
chkp "گزارش نتیجهٔ کل سیستم، نه دلتای هر policy" '^\+[[:space:]]+thermal_perf_gate_set_auto_perf\(any_perf\);'
chkp "hook در cpufreq_init_governor (ورود به governor)" '^\+[[:space:]]+cpufreq_perf_gate_sync\(\);'
N=$(grep -cE '^\+[[:space:]]+cpufreq_perf_gate_sync\(\);' "$PATCH")
[ "$N" -eq 2 ] && ok "دقیقاً ۲ فراخوانی sync (init و exit) — جفت‌شده" \
               || bad "تعداد فراخوانی sync = $N، انتظار ۲"

sec "8c) حالت سه‌گانهٔ گیت (auto / on / off)"
chkp "enum tpg_mode با AUTO/ON/OFF" '^\+enum tpg_mode \{'
chkp "پیش‌فرض TPG_MODE_AUTO" '^\+static enum tpg_mode tpg_mode = TPG_MODE_AUTO;'
chkp "tpg_apply_locked() وضعیت مؤثر را حساب می‌کند" '^\+static bool tpg_apply_locked\(bool \*new_val\)'
chkp "حالت auto از tpg_gov_perf می‌آید" '^\+[[:space:]]+want = tpg_gov_perf;'
chkp "EXPORT_SYMBOL_GPL(thermal_perf_gate_set_auto_perf)" '^\+EXPORT_SYMBOL_GPL\(thermal_perf_gate_set_auto_perf\);'
chkp "sysfs: mode (0644 خواندنی/نوشتنی)" '__ATTR\(mode, 0644, mode_show, mode_store\)'
chkp "mode_store مقدار auto را می‌پذیرد" 'sysfs_streq\(buf, "auto"\)'
chkp "mode_store مقدار off را می‌پذیرد" 'sysfs_streq\(buf, "off"\)'
chkp "نوشتن enabled حالت را به ON/OFF پین می‌کند" 'tpg_mode = want \? TPG_MODE_ON : TPG_MODE_OFF;'
chkp "stats حالت و وضعیت governor را نشان می‌دهد" 'mode=%s perf_governor=%d'
chkp "thermal.h اعلان set_auto_perf را دارد" '^\+void thermal_perf_gate_set_auto_perf\(bool any_perf\);'
chkp "thermal.h fallback برای !CONFIG_THERMAL" '^\+static inline void thermal_perf_gate_set_auto_perf\(bool any_perf\) \{ \}'

sec "8d) برگشت‌پذیری کامل cpufreq_limit (save/restore نه پاک‌سازی)"
chk "آرایهٔ snapshot برای min ذخیره می‌شود" "$CPUF" '^static s32 tpg_saved_min\[DVFS_MAX_ID\]\[2\];'
chk "آرایهٔ snapshot برای max ذخیره می‌شود" "$CPUF" '^static s32 tpg_saved_max\[DVFS_MAX_ID\]\[2\];'
chk "پرچم tpg_saved_valid وجود دارد" "$CPUF" '^static bool tpg_saved_valid;'
chk "مقدار قبلی از pnode.prio خوانده می‌شود" "$CPUF" 'min_req\[id\]\[param\.ltl_cpu_start\]\.pnode\.prio'
chk "snapshot فقط در لبهٔ صعودی گرفته می‌شود" "$CPUF" 'if \(!tpg_saved_valid\) \{'
chk "release مقادیر ذخیره‌شده را برمی‌گرداند" "$CPUF" 'tpg_saved_min\[id\]\[0\]\);'
chk "freq_input هم از snapshot برمی‌گردد" "$CPUF" 'freq_input\[id\]\.min = tpg_saved_fmin\[id\];'
chk "release پرچم را پاک می‌کند" "$CPUF" 'tpg_saved_valid = false;'
chk "release بدون snapshot کاری نمی‌کند (idempotent)" "$CPUF" 'if \(!tpg_saved_valid\)'
# for_each_possible_cpu در کد استوک همین فایل هم هست (خطوط ~392/471/963/1174)،
# پس باید فقط داخل بدنهٔ تابع release بررسی شود نه کل فایل.
REL=$(awk '/^static void cpufreq_limit_perf_release_locked\(void\)/,/^}/' "$CPUF")
if [ -z "$REL" ]; then
  bad "بدنهٔ cpufreq_limit_perf_release_locked() پیدا نشد"
elif echo "$REL" | grep -q 'for_each_possible_cpu'; then
  bad "release هنوز همهٔ CPUها را پاک‌سازی می‌کند (نباید)"
elif echo "$REL" | grep -q 'FREQ_QOS_MIN_DEFAULT_VALUE'; then
  bad "release هنوز به DEFAULT ریست می‌کند نه به snapshot"
else
  ok "release فقط همان دو CPU را از snapshot برمی‌گرداند"
fi

# -----------------------------------------------------------------------------
sec "8e) تفکیک: حرارت دائمی بی‌قید / قفل فرکانس مشروط"
echo "  --- سرکوب حرارتی باید دائمی باشد ---"
chkp "thermal_perf_gate_thermal_off() تعریف شده" '^\+bool thermal_perf_gate_thermal_off\(void\)'
chkp "همیشه true برمی‌گرداند" '^\+[[:space:]]+return true;'
chkp "EXPORT_SYMBOL_GPL(thermal_perf_gate_thermal_off)" '^\+EXPORT_SYMBOL_GPL\(thermal_perf_gate_thermal_off\);'
chkp "thermal.h اعلان thermal_off را دارد" '^\+bool thermal_perf_gate_thermal_off\(void\);'
chkp "stats وضعیت دائمی را نشان می‌دهد" 'thermal=off\(permanent\)'
# مهم: blocked() دیگر نباید به tpg_enabled نگاه کند
if sed -n '/^\+\+\+ b\/drivers\/thermal\/thermal_perf_gate.c/,/^diff --git/p' "$PATCH" \
   | awk '/^\+bool thermal_perf_gate_blocked/,/^\+}/' \
   | grep -q 'tpg_enabled'; then
  bad "thermal_perf_gate_blocked() هنوز به tpg_enabled وابسته است (باید دائمی باشد)"
else
  ok "thermal_perf_gate_blocked() بی‌قید است (وابسته به tpg_enabled نیست)"
fi

echo "  --- ap_thermal_limit باید بی‌قید باشد ---"
N=$(grep -cE 'if \(thermal_perf_gate_thermal_off\(\)\)' "$ATM")
[ "$N" -eq 2 ] && ok "هر ۲ نقطه از thermal_off استفاده می‌کنند" \
               || bad "تعداد thermal_off در ap_thermal_limit = $N، انتظار ۲"
absc "ap_thermal_limit دیگر از thermal_perf_gate_enabled استفاده نمی‌کند" "$ATM" 'thermal_perf_gate_enabled'

echo "  --- gpuppm: خنثی‌سازی دائمی، پین مشروط ---"
if grep -A3 '^static bool gpuppm_gate_neutralized' "$GPUP" | grep -q 'thermal_perf_gate_enabled'; then
  bad "gpuppm_gate_neutralized() هنوز مشروط به perf mode است"
else
  ok "gpuppm_gate_neutralized() بی‌قید شد"
fi
chk "شرط دائمی: thermal_off && neutralized" "$GPUP" 'if \(thermal_perf_gate_thermal_off\(\) && gpuppm_gate_neutralized\(limiter\)\)'
chk "در حالت دائمی ورودی به GPUPPM_DEFAULT_IDX می‌رود" "$GPUP" 'limit_table\[limiter\]\.ceiling = GPUPPM_DEFAULT_IDX;'
chk "پین روی سقف هنوز مشروط به perf mode است" "$GPUP" '^[[:space:]]+if \(thermal_perf_gate_enabled\(\)\)'

echo "  --- قفل CPU باید مشروط بماند ---"
chk "cpufreq_limit همچنان مشروط به thermal_perf_gate_enabled است" "$CPUF" 'if \(thermal_perf_gate_enabled\(\)\) \{'

sec "8f) مسیرهایی که اصلاً برای mt6877 کامپایل نمی‌شوند (شاهد منفی)"
MALIMK="$VEND/drivers/gpu/mediatek/gpu_mali/mali_avalon/mali-r49p1/drivers/gpu/arm/midgard/Makefile"
GEDC="$VEND/drivers/gpu/mediatek/ged/src/ged_dvfs.c"
GPUF="$VEND/drivers/gpu/mediatek/gpufreq/v2_legacy/gpufreq_mt6877.c"
OVL="$VEND/kernel/configs/mt6877_overlay.config"

echo "  --- کدام گاورنرهای حرارتی واقعاً در Image ما کامپایل می‌شوند ---"
GKID="$GKI/arch/arm64/configs/gki_defconfig"
for g in BANG_BANG USER_SPACE POWER_ALLOCATOR; do
  chk "CONFIG_THERMAL_GOV_$g=y در gki_defconfig (پس کامپایل می‌شود)" "$GKID" "^CONFIG_THERMAL_GOV_$g=y"
done
# step_wise عمداً در gki_defconfig نیست؛ هانکش در پچ می‌ماند ولی در این Image inert است
if grep -qE '^CONFIG_THERMAL_GOV_STEP_WISE=y' "$GKID"; then
  ok "CONFIG_THERMAL_GOV_STEP_WISE=y — گاورنر step_wise کامپایل می‌شود"
else
  ok "CONFIG_THERMAL_GOV_STEP_WISE در gki_defconfig نیست — step_wise در این Image کامپایل نمی‌شود (هانک پچ inert ولی بی‌ضرر)"
fi
absc "a34x_defconfig جایی در build ارجاع نشده (فقط gki_defconfig + overlay ها)" "build_kernel.sh" 'a34x_defconfig'

echo "  --- Mali kbase devfreq / IPA ---"
absc "Makefile مالِ Mali هیچ بلوکی برای mt6877 ندارد" "$MALIMK" 'mt6877'
N=$(grep -cE 'CONFIG_MALI_DEVFREQ := y' "$MALIMK")
[ "$N" -eq 4 ] && ok "CONFIG_MALI_DEVFREQ := y فقط ۴ بار (mt6768/mt6897/mt6989/mt6991)" \
               || bad "تعداد CONFIG_MALI_DEVFREQ := y = $N، انتظار ۴"
chk "ipa/Kbuild فقط وقتی DEVFREQ=y *و* DEVFREQ_THERMAL=y include می‌شود" "$MALIMK" \
    '^[[:space:]]+ifeq \(\$\(CONFIG_DEVFREQ_THERMAL\),y\)'
chk "mali_kbase_devfreq.o فقط زیر CONFIG_MALI_DEVFREQ ساخته می‌شود" \
    "$VEND/drivers/gpu/mediatek/gpu_mali/mali_avalon/mali-r49p1/drivers/gpu/arm/midgard/backend/gpu/Kbuild" \
    'mali_kbase-\$\(CONFIG_MALI_DEVFREQ\) \+='

echo "  --- MTK GED ---"
chk "overlay mt6877: CONFIG_MTK_LEGACY_THERMAL=m است" "$OVL" '^CONFIG_MTK_LEGACY_THERMAL=m'
chk "بلوک‌های حرارتی GED زیر !IS_ENABLED(CONFIG_MTK_LEGACY_THERMAL)‌اند (پس حذف می‌شوند)" \
    "$GEDC" '#if !IS_ENABLED\(CONFIG_MTK_LEGACY_THERMAL\)'
N=$(grep -c 'thermal' "$GEDC")
[ "$N" -le 3 ] && ok "در ged_dvfs.c فقط $N ارجاع thermal هست (همه کامنت/بیت وضعیت)" \
               || bad "در ged_dvfs.c $N ارجاع thermal هست — بازبینی لازم است"
chk "GED_EVENT_THERMAL فقط یک بیت وضعیت است، نه actuator" "$GEDC" \
    'g_ui32EventStatus \|= GED_EVENT_THERMAL'

echo "  --- gpufreq_mt6877.c ---"
N=$(grep -c 'g_thermal_protect_limited_ignore_state' "$GPUF")
[ "$N" -eq 1 ] && ok "g_thermal_protect_limited_ignore_state فقط تعریف شده و هرگز استفاده نمی‌شود (کد مرده)" \
               || bad "g_thermal_protect_limited_ignore_state $N بار ارجاع شده — بازبینی لازم است"
absc "gpufreq_mt6877.c هیچ actuator فرکانسی حرارتی ندارد" "$GPUF" \
     'mt_gpufreq_thermal_protect|gpufreq_set_limit|mt_gpufreq_set_dvfs'
chk "دمای GPU فقط ورودی جدول توان است (__mt_gpufreq_calculate_power)" "$GPUF" \
    '__mt_gpufreq_calculate_power\(i, freq, volt, temp\)'

sec "9) بررسی‌های «چیزی اشتباهی دست‌نخورده»"
NOB="$VEND/drivers/misc/mediatek/thermal/common/thermal_zones/mtk_ts_cpu_noBankv2.c"
TZC="$VEND/drivers/misc/mediatek/thermal/inc/tzcpu_initcfg.h"
# متن واقعی سورس در noBankv2.c:157 این است:
#   static int trip_temp[10] = { 117000, 100000, 85000, 75000, 65000,
chk "کف بحرانی فروشنده: اولین خانهٔ trip_temp = 117000 (117 °C) سر جایش است" \
    "$NOB" '^static int trip_temp\[10\] = \{ 117000,'
chk "TARGET_TJS[i] = 117000 هم دست‌نخورده" "$NOB" 'TARGET_TJS\[i\] = 117000;'
chk "TZCPU_INITCFG_TRIP_0_TEMP (117000) در هدر دست‌نخورده" "$TZC" 'TZCPU_INITCFG_TRIP_0_TEMP[[:space:]]*\(117000\)'
chk "فراخوانی lvts_config_all_tc_hw_protect(trip_temp[0], ...) دست‌نخورده" \
    "$NOB" 'lvts_config_all_tc_hw_protect\(trip_temp\[0\], tc_mid_trip\)'
absc "فایل‌های GKI زنده pristine‌اند (کد گیت ندارند)" "$GKI/drivers/thermal/thermal_helpers.c" 'thermal_perf_gate'
absc "gov_step_wise.c زنده pristine است" "$GKI/drivers/thermal/gov_step_wise.c" 'thermal_perf_gate'
absc "gov_power_allocator.c زنده pristine است" "$GKI/drivers/thermal/gov_power_allocator.c" 'thermal_perf_gate'
absc "cpufreq.c زنده pristine است (hook فقط داخل پچ)" "$GKI/drivers/cpufreq/cpufreq.c" 'thermal_perf_gate|cpufreq_perf_gate_sync'
[ ! -e "$GKI/drivers/thermal/thermal_perf_gate.c" ] \
  && ok "thermal_perf_gate.c در درخت GKI نیست (درست — فقط داخل پچ است)" \
  || bad "thermal_perf_gate.c در درخت GKI پیدا شد؛ kernel-6.6 باید pristine بماند"

# -----------------------------------------------------------------------------
printf '\n========================================================================\n'
printf ' نتیجه:  %d PASS   /   %d FAIL\n' "$PASS" "$FAIL"
printf '========================================================================\n'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
