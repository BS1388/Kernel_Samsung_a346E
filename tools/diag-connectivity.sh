#!/system/bin/sh
# =============================================================================
# A346E WiFi/BT/GPS connectivity diagnostic (run as root on device)
#
# Usage:
#   adb push tools/diag-connectivity.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/diag-connectivity.sh" > diag.txt
#   (or via KSU terminal: su -c "sh /sdcard/diag-connectivity.sh")
#
# Collects everything needed to find out why WiFi/BT/hotspot are dead:
#   - kernel vermagic vs module vermagic (mismatch = wrong module set)
#   - loaded modules
#   - module load errors (CRC / unknown symbol / signature)
#   - probe/init errors from wlan gen4m, wmt, conninfra, connfem, bt
#   - firmware files & char devices of the combo chip
# =============================================================================
OUT="/data/local/tmp/diag-connectivity.txt"
exec > "$OUT" 2>&1

line() { echo; echo "=================== $* ==================="; }

line "1. Kernel & boot"
uname -a
getprop ro.build.fingerprint
getprop ro.bootimage.build.fingerprint 2>/dev/null
cat /proc/version

line "2. Loaded modules (full lsmod)"
lsmod

line "3. Connectivity modules on disk + vermagic"
# vermagic of the RUNNING kernel:
KVER=$(uname -r)
echo "running kernel release: $KVER"
for d in /vendor_dlkm/lib/modules /vendor/lib/modules /odm/lib/modules /system/lib/modules; do
  if [ -d "$d" ]; then
    echo "--- $d:"
    ls "$d" 2>/dev/null | grep -iE "wlan|wmt|conn|bt|cfg80211|mac80211|gps|fmradio|stp" || echo "  (no connectivity .ko here)"
  fi
done
echo
echo "--- vermagic comparison (must match kernel exactly!):"
for m in $(find /vendor_dlkm/lib/modules /vendor/lib/modules /odm/lib/modules -name "*.ko" 2>/dev/null | grep -iE "wlan|wmt|conn|cfg80211|mac80211|/bt|stp_bt" | head -n 12); do
  echo "[$m]"
  modinfo "$m" 2>/dev/null | grep -E "vermagic|filename" || strings "$m" | grep -m1 vermagic
done

line "4. Module load errors (CRC / symbols / signature)"
dmesg | grep -iE "disagrees about version|unknown symbol|module verification|no symbol version|invalid module format|parameters must have|module_layout" | tail -n 40

line "5. WiFi (wlan gen4m / adaptor / cfg80211 / mac80211)"
dmesg | grep -iE "wlan|cfg80211|mac80211|p2p|wifi" | grep -viE "ipv6|netlink" | tail -n 60
echo "--- net interfaces:"
ip link 2>/dev/null || netcfg 2>/dev/null
echo "--- wlan0 present?"; ip link show wlan0 2>/dev/null || echo "NO wlan0"
getprop | grep -iE "wifi|wlan" | head -n 20

line "6. BT (wmt / stp / mt66xx)"
dmesg | grep -iE "wmt|stp|bluetooth|btif|combo|conninfra|connfem" | tail -n 60
echo "--- combo char devices:"
ls -l /dev/stpbt /dev/stpgps /dev/stpwmt /dev/wmtWifi 2>/dev/null || echo "NO stp/wmt char devices (wmt driver did not init!)"
echo "--- hci:"
dmesg | grep -iE "hci|rfkill" | tail -n 20

line "7. Firmware files of combo chip"
ls -l /vendor/firmware/ 2>/dev/null | grep -iE "WIFI|MT66|mt79|BT|GPS|CONN" | head -n 30
ls -l /vendor/firmware/connfw 2>/dev/null || true

line "8. GNSS/FM (same combo chip - if these work, chip itself is alive)"
dmesg | grep -iE "gps|mnld|fmradio" | tail -n 20

line "9. subsys / connsys state (mtk)"
cat /proc/connsys/ 2>/dev/null || true
for f in /proc/connsys/dump_state /proc/connsys/subsys_status; do
  [ -f "$f" ] && { echo "--- $f:"; cat "$f" 2>/dev/null | head -n 40; }
done

line "DONE"
echo
echo "Output saved to $OUT - pull it and send it back:"
echo "  adb shell su -c 'cat $OUT'"
