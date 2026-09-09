#!/system/bin/sh
# =============================================================================
# collect-thermal-log.sh
#
# این اسکریپت را روی دستگاه (با root) اجرا کن؛ لاگ را خودش در
#   /storage/emulated/0/Download/thermal-log-<تاریخ>.txt
# ذخیره می‌کند و در پایان مسیر و اندازهٔ فایل را چاپ می‌کند.
# همهٔ مسیرها از خودِ سورس این کرنل استخراج شده‌اند، نه حدسی.
#
# اجرا:
#   adb push perf-profile/collect-thermal-log.sh /data/local/tmp/
#   adb shell "su -c 'sh /data/local/tmp/collect-thermal-log.sh'"
#
# زیر بار (هم‌زمان یک بازی/benchmark سنگین اجرا کن):
#   adb shell "su -c 'sh /data/local/tmp/collect-thermal-log.sh --watch 30'"
#
# برداشتن فایل:
#   adb pull /storage/emulated/0/Download/thermal-log-<تاریخ>.txt
#
# اگر نوشتن در Download به SELinux خورد، اسکریپت خودش به /data/local/tmp
# می‌نویسد و بعد کپی می‌کند؛ یا دستی:
#   adb shell "su -c 'sh /data/local/tmp/collect-thermal-log.sh --dir /data/local/tmp'"
#
# برای دیدن هم‌زمان روی صفحه:  --stdout
# =============================================================================

# -----------------------------------------------------------------------------
# گزینه‌ها
#   --watch [N]   نمونهٔ زمانی N ثانیه‌ای (پیش‌فرض ۲۰) — زیر بار اجرا کن
#   --dir PATH    مسیر ذخیره (پیش‌فرض /storage/emulated/0/Download)
#   --stdout      هم‌زمان روی صفحه هم چاپ شود (اگر tee موجود باشد)
# -----------------------------------------------------------------------------
WATCH=0
STDOUT=0
OUTDIR="/storage/emulated/0/Download"

while [ $# -gt 0 ]; do
  case "$1" in
    --watch)  WATCH="${2:-20}"; [ $# -ge 2 ] && shift ;;
    --dir)    OUTDIR="${2:-$OUTDIR}"; [ $# -ge 2 ] && shift ;;
    --stdout) STDOUT=1 ;;
    *) echo "گزینهٔ ناشناخته: $1" ;;
  esac
  shift
done

GATE=/sys/kernel/thermal_perf
CPUL=/sys/devices/system/cpu/cpufreq_limit
CPUS=/sys/devices/system/cpu

hr() { echo "----------------------------------------------------------------------"; }
sec() { echo; hr; echo "### $1"; hr; }
show() {
  if [ -e "$1" ]; then
    echo "--- $1"
    cat "$1" 2>/dev/null || echo "  (خوانده نشد)"
  else
    echo "--- $1   [موجود نیست]"
  fi
}

# -----------------------------------------------------------------------------
# انتخاب مسیری که واقعاً قابل نوشتن است.
# روی اندروید نوشتنِ روت به /storage/emulated/0 گاهی به SELinux می‌خورد، پس
# یک زنجیرهٔ fallback داریم و در نهایت از /data/local/tmp کپی می‌کنیم.
# -----------------------------------------------------------------------------
pick_dir() {
  _d="$1"
  mkdir -p "$_d" 2>/dev/null
  if ( : > "$_d/.tlog_probe" ) 2>/dev/null; then
    rm -f "$_d/.tlog_probe" 2>/dev/null
    return 0
  fi
  return 1
}

CAN_WRITE_TARGET=1
if ! pick_dir "$OUTDIR"; then
  CAN_WRITE_TARGET=0
  for d in /sdcard/Download /storage/emulated/0 /data/local/tmp; do
    if pick_dir "$d"; then OUTDIR="$d"; break; fi
  done
fi

STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo notime)
OUT="$OUTDIR/thermal-log-$STAMP.txt"

# -----------------------------------------------------------------------------
main() {

sec "0) هویت بیلد — اول از همه این را چک می‌کنم"
echo "date        : $(date)"
echo "uname -a    : $(uname -a)"
show /proc/version
show /proc/cmdline
echo "kernelsu    : $(cat /data/adb/ksu/version 2>/dev/null || echo 'n/a')"

sec "1) وضعیت گیت — مهم‌ترین بخش"
show $GATE/enabled
show $GATE/stats
show $GATE/allow_list
# allow_extra عمداً 0200 است (فقط‌نوشتنی) پس خواندنی نیست
[ -e "$GATE/allow_extra" ] && echo "--- $GATE/allow_extra   [موجود، 0200 فقط‌نوشتنی]"
if [ ! -d "$GATE" ]; then
  echo
  echo "!!!  $GATE اصلاً وجود ندارد."
  echo "!!!  یعنی Image فلش‌شده پچ ما را ندارد (یا thermal_perf_gate_init خطا داده)."
  echo "!!!  بخش ۱۲ (dmesg) را حتماً بفرست."
fi

sec "2) دما — همهٔ thermal zone ها"
for z in /sys/class/thermal/thermal_zone*; do
  [ -d "$z" ] || continue
  printf "  %-24s temp=%-9s mode=%s\n" \
    "$(cat $z/type 2>/dev/null)" "$(cat $z/temp 2>/dev/null)" "$(cat $z/mode 2>/dev/null)"
done

sec "3) همهٔ cooling device ها و وضعیت فعلی‌شان"
echo "  (اگر گیت فعال باشد، همه باید cur_state=0 باشند جز allowlist"
echo "   که شامل: bcct / charger / batt / shutdown / kshutdown / sysrst است)"
for c in /sys/class/thermal/cooling_device*; do
  [ -d "$c" ] || continue
  t=$(cat "$c/type" 2>/dev/null)
  s=$(cat "$c/cur_state" 2>/dev/null)
  x=$(cat "$c/max_state" 2>/dev/null)
  flag=""
  [ "$s" != "0" ] && [ -n "$s" ] && flag="   <== غیر صفر!"
  printf "  %-26s cur=%-5s max=%-5s%s\n" "$t" "$s" "$x" "$flag"
done

sec "4) فرکانس CPU — همهٔ کلاسترها"
for p in $CPUS/cpu[0-9]*/cpufreq; do
  [ -d "$p" ] || continue
  cpu=$(echo "$p" | sed 's#.*/cpu\([0-9]*\)/.*#\1#')
  printf "  cpu%-3s cur=%-9s min=%-9s max=%-9s gov=%s\n" "$cpu" \
    "$(cat $p/scaling_cur_freq 2>/dev/null)" "$(cat $p/scaling_min_freq 2>/dev/null)" \
    "$(cat $p/scaling_max_freq 2>/dev/null)" "$(cat $p/scaling_governor 2>/dev/null)"
done
echo
echo "  بالاترین فرکانس سخت‌افزاری هر کلاستر (cpuinfo_max_freq):"
for p in $CPUS/cpu[0-9]*/cpufreq; do
  [ -d "$p" ] || continue
  cpu=$(echo "$p" | sed 's#.*/cpu\([0-9]*\)/.*#\1#')
  printf "    cpu%-3s hw_max=%-9s hw_min=%s\n" "$cpu" \
    "$(cat $p/cpuinfo_max_freq 2>/dev/null)" "$(cat $p/cpuinfo_min_freq 2>/dev/null)"
done
echo
echo "  هسته‌های online (اگر cpu isolate کار کرده باشد کم می‌شود):"
cat $CPUS/online 2>/dev/null; cat $CPUS/offline 2>/dev/null

sec "5) cpufreq_limit — آیا hard-lock واقعاً اعمال شده؟"
echo "  (kobject زیر bus_get_dev_root(&cpu_subsys) ساخته می‌شود)"
show $CPUL/cpufreq_table
show $CPUL/cpufreq_min_limit
show $CPUL/cpufreq_max_limit
show $CPUL/over_limit

sec "6) GPU — gpufreq و وضعیت limiter ها"
echo "  (نام دایرکتوری از gpufreq/v2_legacy/include/gpufreq_debug_legacy.h:12"
echo "   → GPUFREQ_DIR_NAME=\"gpufreqv2\")"
# مهم‌ترین فایل: limit_table سقف/کف هر limiter را نشان می‌دهد
show /proc/gpufreqv2/limit_table
show /proc/gpufreqv2/gpufreq_status
show /proc/gpufreqv2/gpu_working_opp_table
show /proc/gpufreqv2/gpu_signed_opp_table
show /proc/gpufreqv2/fix_target_opp_index
show /proc/gpufreqv2/opp_stress_test
echo "--- لیست کامل /proc/gpufreqv2:"
ls -1 /proc/gpufreqv2 2>/dev/null | sed 's/^/    /' || echo "    [/proc/gpufreqv2 موجود نیست]"
echo
echo "  در limit_table باید برای LIMIT_THERMAL_AP / _EB / LIMIT_PBM سقف و کف = 0"
echo "  ببینی وقتی گیت فعال است. عدد دیگری = فیکس GPU کار نکرده."
echo
echo "--- GED:"
ls -1 /sys/kernel/ged/hal/ 2>/dev/null | sed 's/^/    /' || echo "    [/sys/kernel/ged موجود نیست]"
show /sys/kernel/ged/hal/gpu_dvfs_enable
show /sys/kernel/ged/hal/gpu_utilization

sec "7) ATM / DTM — همان مسیری که در ممیزی بسته شد"
show /proc/clatm
show /proc/clatm_setting
show /proc/clatm_cpu_min_opp
show /proc/clatm_gpu_threshold
show /proc/clctm
echo
echo "  اگر در clatm یک بودجهٔ توان محدود دیدی و گیت فعال بود، یعنی فیکس"
echo "  ap_thermal_limit.c کار نکرده -> این مهم‌ترین مدرک است."

sec "8) PPM — وضعیت policy ها"
for f in /proc/ppm/policy/*; do
  [ -f "$f" ] || continue
  show "$f"
done
show /proc/ppm/profile
echo "--- لیست کامل /proc/ppm:"
ls -1R /proc/ppm 2>/dev/null | sed 's/^/    /' || echo "    [/proc/ppm موجود نیست]"

sec "9) thermal zone خودِ CPU (mtk_ts_cpu_noBankv2 — برای mt6877 build می‌شود)"
show /proc/tzcpu
show /proc/thermlmt
show /proc/ttpct
show /proc/tzcpu_read_temperature
show /proc/tzcpu_fastpoll

sec "10) SSPM — تنها مسیری که از کرنل قابل کنترل نیست"
show /proc/sspm_thermal_throttle
show /proc/clatm_sspm
echo
echo "  اگر گیت فعال است و فرکانس هنوز افت می‌کند و همهٔ بخش‌های بالا تمیزند،"
echo "  متهم SSPM است (firmware است، نه کد کرنل). این دو فایل را حتماً بفرست."

sec "11) سایر limiter ها"
show /proc/thermal_mdla_limit
show /proc/thermal_vpu_limit
show /proc/tx_thro_limit
show /proc/bcctlmt
show /proc/battery_status
show /proc/clabcct
show /proc/clbcct
echo
echo "  نکته: /proc/pmic_current_limit ، /proc/set_sspm_big_limit_threshold و"
echo "  /proc/cldebug برای mt6877 build نمی‌شوند (به ترتیب در mtk_ts_cpu.c،"
echo "  v1/mt6893 و mtk_cooler_3Gmutt.c) — [موجود نیست] برای اینها طبیعی است."

sec "12) dmesg — پیام‌های گیت و خطاها"
echo "--- thermal_perf_gate (باید 'registered' و موقع فعال‌سازی 'SUPPRESSED' ببینی):"
dmesg 2>/dev/null | grep -iE "thermal_perf_gate|thermal_perf" | tail -30
echo "--- hard-lock سی‌پی‌یو:"
dmesg 2>/dev/null | grep -iE "hard-locked|cpufreq_limit" | tail -20
echo "--- گیت GPU:"
dmesg 2>/dev/null | grep -iE "\[GATE\]" | tail -20
echo "--- خطاهای thermal / oops / WARN:"
dmesg 2>/dev/null | grep -iE "thermal.*(fail|error)|Unable to handle|BUG:|WARNING:|Oops|Call trace" | tail -30
echo "--- آخرین ۶۰ خط dmesg:"
dmesg 2>/dev/null | tail -60

sec "13) نتیجهٔ خودکار (چک سریع)"
if [ -e "$GATE/enabled" ]; then
  echo "  gate enabled      : $(cat $GATE/enabled 2>/dev/null)"
  echo "  gate stats        : $(cat $GATE/stats 2>/dev/null | tr '\n' ' ')"
else
  echo "  gate enabled      : [sysfs موجود نیست - پچ در این Image نیست]"
fi
NZ=0
for c in /sys/class/thermal/cooling_device*; do
  s=$(cat "$c/cur_state" 2>/dev/null)
  t=$(cat "$c/type" 2>/dev/null)
  case "$t" in
    *bcct*|*charger*|*batt*|*shutdown*|*sysrst*) continue ;;  # allowlist عمداً فعال است
  esac
  [ -n "$s" ] && [ "$s" != "0" ] && { echo "  هنوز throttle فعال: $t = $s"; NZ=$((NZ+1)); }
done
[ "$NZ" = "0" ] && echo "  cooling device غیر allowlist با state غیرصفر: هیچ"

if [ "$WATCH" != "0" ]; then
  sec "14) نمونهٔ زمانی ${WATCH} ثانیه‌ای (زیر بار اجرا کن!)"
  echo "epoch,cpu0_cur,cpu6_cur,max_temp,gpu_status,clatm"
  i=0
  while [ "$i" -lt "$WATCH" ]; do
    BIGT=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
    C0=$(cat $CPUS/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    C6=$(cat $CPUS/cpu6/cpufreq/scaling_cur_freq 2>/dev/null)
    ATM=$(cat /proc/clatm 2>/dev/null | tr '\n' ' ' | cut -c1-40)
    GPU=$(cat /proc/gpufreqv2/gpufreq_status 2>/dev/null | grep -iE "current|freq" | head -1 | cut -c1-30)
    echo "$(date +%s),$C0,$C6,$BIGT,$GPU,$ATM"
    i=$((i+1))
    sleep 1
  done
fi

sec "پایان"
echo "این فایل را کامل بفرست. بخش‌های ۱، ۳، ۴، ۶، ۷ و ۱۰ از همه مهم‌ترند."
echo "hostname : $(getprop ro.product.device 2>/dev/null || uname -n)"
echo "saved-at : $(date)"

}   # --- پایان main() ---------------------------------------------------------

# -----------------------------------------------------------------------------
# اجرا و ذخیره
# -----------------------------------------------------------------------------
if [ "$STDOUT" = "1" ] && command -v tee >/dev/null 2>&1; then
  main 2>&1 | tee "$OUT"
else
  main > "$OUT" 2>&1
fi

# اگر مسیر اصلی قابل نوشتن نبود، از مسیر موقت کپی کن
if [ "$CAN_WRITE_TARGET" = "0" ]; then
  for d in /storage/emulated/0/Download /sdcard/Download; do
    mkdir -p "$d" 2>/dev/null
    if cp "$OUT" "$d/thermal-log-$STAMP.txt" 2>/dev/null; then
      OUT="$d/thermal-log-$STAMP.txt"
      break
    fi
  done
fi

# -----------------------------------------------------------------------------
# تأیید اینکه فایل واقعاً نوشته شده (نه اینکه ساکت شکست خورده باشد)
# -----------------------------------------------------------------------------
if [ -s "$OUT" ]; then
  SZ=$(wc -c < "$OUT" 2>/dev/null)
  LN=$(wc -l < "$OUT" 2>/dev/null)
  echo "ذخیره شد: $OUT"
  echo "اندازه  : $SZ بایت ، $LN خط"
  echo
  echo "برای برداشتن از گوشی:"
  echo "  adb pull $OUT"
  echo
  echo "اگر می‌خواهی فقط این فایل را بفرستی، همین را ضمیمه کن."
else
  echo "خطا: لاگ نوشته نشد یا خالی است: $OUT"
  echo "این‌ها را امتحان کن:"
  echo "  1) با root اجرا کن:  su -c 'sh .../collect-thermal-log.sh'"
  echo "  2) مسیر دیگر بده:    --dir /data/local/tmp"
  echo "  3) SELinux موقتاً:   su -c 'setenforce 0'  (بعداً setenforce 1)"
  exit 1
fi

