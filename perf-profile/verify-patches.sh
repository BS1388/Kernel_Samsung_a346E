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
chkp "پیام SUPPRESSED موقع فعال‌سازی" 'SUPPRESSED \(performance profile engaged\)'

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
chk "پیام [GATE] GPU DVFS pinned to peak OPP" "$GPUP" '\[GATE\] GPU DVFS pinned to peak OPP'
chk "پیام [GATE] GPU DVFS limits released" "$GPUP" '\[GATE\] GPU DVFS limits released'
chk "gate روی stack limit table هم اعمال می‌شود (dual-buck)" "$GPUP" 'gpuppm_gate_release\(g_stack_limit_table\)'
chk "gate روی limit table اصلی اعمال می‌شود" "$GPUP" 'gpuppm_gate_release\(g_gpu_limit_table\)'
absc "تابع ساختگی gpuppm_reset_limit() صدا زده نمی‌شود" "$GPUP" 'gpuppm_reset_limit'

# -----------------------------------------------------------------------------
sec "8) ap_thermal_limit.c — مسیر ATM/DTM → بودجهٔ توان PPM (فایل زنده)"
[ -f "$ATM" ] && ok "فایل موجود است" || bad "فایل موجود نیست: $ATM"
chk "گیت سمت CPU" "$ATM" '^[[:space:]]if \(thermal_perf_gate_enabled\(\)\)'
chk "final_limit = 0x7FFFFFFF (سنتینل «بدون محدودیت» خودِ فایل)" "$ATM" 'final_limit = 0x7FFFFFFF;'
N=$(grep -cE '^[[:space:]]if \(thermal_perf_gate_enabled\(\)\)' "$ATM")
[ "$N" -eq 2 ] && ok "دقیقاً ۲ نقطهٔ گیت (CPU و GPU) — نه کمتر نه بیشتر" \
               || bad "تعداد نقاط گیت = $N، انتظار ۲"

# -----------------------------------------------------------------------------
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
[ ! -e "$GKI/drivers/thermal/thermal_perf_gate.c" ] \
  && ok "thermal_perf_gate.c در درخت GKI نیست (درست — فقط داخل پچ است)" \
  || bad "thermal_perf_gate.c در درخت GKI پیدا شد؛ kernel-6.6 باید pristine بماند"

# -----------------------------------------------------------------------------
printf '\n========================================================================\n'
printf ' نتیجه:  %d PASS   /   %d FAIL\n' "$PASS" "$FAIL"
printf '========================================================================\n'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
