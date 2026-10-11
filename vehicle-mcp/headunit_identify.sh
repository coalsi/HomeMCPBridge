#!/usr/bin/env bash
# headunit_identify.sh — READ-ONLY fingerprint of a Chinese Android head unit over ADB.
#
# Run this from the Mac (or any machine with adb) against the head unit:
#   ./headunit_identify.sh 192.168.x.x:5555
#   ./headunit_identify.sh 192.168.x.x:5555 --try-root   # also attempt `adb root`
#
# It answers the questions that decide every next step:
#   * exact SoC/board (qcm6125 "trinket"?) and which vendor family (MTCH, ZXW/GT6,
#     Z35/ZongHeng, Joying, FYT, Topway...) the firmware belongs to
#   * MCU version string (firmware/MCU files are MCU-specific — cross-flash = brick)
#   * whether adb/su root is already available (many QCM6125 units ship with it)
#   * bootloader / verified-boot lock state
#   * which serial (tty) devices exist — the CAN decoder -> MCU -> Android path
#   * which vendor services/apps carry vehicle (CAN) data to apps like mycarplay
#
# Nothing here writes to the device. `--try-root` only runs `adb root`, which
# restarts adbd with elevated privileges on debuggable builds (no persistent change).

set -u
TARGET="${1:-}"
TRY_ROOT="${2:-}"
if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <ip:port | serial> [--try-root]" >&2
  exit 1
fi

OUT="headunit-identity-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

sh() { adb -s "$TARGET" shell "$@" 2>&1; }
section() { printf '\n==================== %s ====================\n' "$1"; }
prop() { printf '%-40s %s\n' "$1" "$(sh getprop "$1" | tr -d '\r')"; }

echo "Head unit identification — $(date)"
echo "target: $TARGET"
adb connect "$TARGET" >/dev/null 2>&1 || true
adb -s "$TARGET" get-state >/dev/null 2>&1 || { echo "adb cannot reach $TARGET"; exit 2; }

section "PLATFORM / SoC"
for p in ro.board.platform ro.hardware ro.boot.hardware ro.product.board ro.product.device \
         ro.product.model ro.product.manufacturer ro.product.brand ro.product.name \
         ro.vendor.product.device ro.bootloader ro.baseband ro.soc.model ro.soc.manufacturer \
         ro.chipname ro.boot.hwversion; do prop "$p"; done
echo "--- /proc/cpuinfo (hardware line)"; sh cat /proc/cpuinfo | grep -iE 'hardware|model name|processor' | sort -u | head
echo "--- kernel"; sh cat /proc/version
echo "--- memory"; sh cat /proc/meminfo | head -2
echo "--- display"; sh wm size; sh wm density

section "BUILD / ANDROID VERSION"
for p in ro.build.fingerprint ro.build.display.id ro.build.id ro.build.version.release \
         ro.build.version.sdk ro.build.version.security_patch ro.build.date ro.build.type \
         ro.build.tags ro.build.user ro.build.host ro.vendor.build.fingerprint \
         ro.vendor.build.date ro.odm.build.fingerprint; do prop "$p"; done
echo "NOTE: QCM6125 units are often an older Android spoofed to a newer version — compare sdk vs release."

section "ROOT / SECURITY STATE"
for p in ro.secure ro.debuggable ro.adb.secure persist.sys.usb.config persist.adb.tcp.port \
         service.adb.tcp.port ro.boot.verifiedbootstate ro.boot.flash.locked \
         ro.boot.vbmeta.device_state ro.boot.veritymode ro.oem_unlock_supported \
         sys.oem_unlock_allowed ro.boot.secureboot; do prop "$p"; done
echo "--- adb shell identity:"; sh id
echo "--- su binary present?"; sh 'ls -l /system/bin/su /system/xbin/su /sbin/su /vendor/bin/su 2>/dev/null || echo "(no su on PATH locations)"'
echo "--- su works? (non-interactive test)"; sh 'su -c id 2>&1 | head -1'
echo "--- Magisk?"; sh 'ls -d /sbin/.magisk /data/adb/magisk 2>/dev/null || echo "(no magisk dirs)"'
if [[ "$TRY_ROOT" == "--try-root" ]]; then
  echo "--- attempting adb root"; adb -s "$TARGET" root; sleep 2; adb connect "$TARGET" >/dev/null 2>&1; sh id
fi

section "MCU / CANBUS / VENDOR FAMILY PROPS"
echo "--- any prop mentioning mcu / can / canbus / canbox / decoder / vehicle:"
sh getprop | grep -iE 'mcu|canbus|canbox|can_|decoder|vehicle|carinfo|protocol|zxw|hct|mtc|fyt|syu|joying|topway|ts\.|zongheng|zh\.|z35|sta_gt|gt6|gt7' | head -80
echo "--- vendor family markers:"
sh 'ls -d /system/priv-app/HCTManagerService /system/priv-app/MTCManager 2>/dev/null && echo "=> MTCH/MTCD (Microntek) family" || true'
sh 'ls /oem/app 2>/dev/null | head -5 && echo "=> FYT family marker (/oem/app)" || true'
sh 'ls /mnt/privdata1/zxw_factory_config.xml 2>/dev/null && echo "=> ZXW / GT6 family (zxw_factory_config.xml)" || true'
sh 'ls /system/etc/reglink_autorun_whitelist.txt 2>/dev/null && echo "=> Reglink family" || true'

section "SERIAL DEVICES (decoder -> MCU -> Android path)"
sh 'ls -l /dev/ttyHS* /dev/ttyMSM* /dev/ttyHSL* /dev/ttyV* /dev/ttyS* /dev/ttyUSB* /dev/ttyACM* /dev/ttyGS* /dev/mcu* /dev/canbus* 2>/dev/null || echo "(no matching tty nodes visible — may need root)"'
echo "--- socketcan interfaces (almost certainly none on a head unit):"
sh 'ls /sys/class/net 2>/dev/null; ip -brief link 2>/dev/null | grep -i can || echo "(no can0 — vehicle data arrives via serial, not SocketCAN)"'

section "VEHICLE / CAN RELATED PACKAGES & SERVICES"
echo "--- packages:"; sh pm list packages | grep -iE 'can|mcu|car|vehicle|hct|mtc|fyt|syu|zxw|joying|topway|ts\.|zh|zongheng|carplay|mycarplay|factory|setting' | sort | head -80
echo "--- running system services with vehicle-ish names:"; sh service list | grep -iE 'can|mcu|car|vehicle|hct|mtc|fyt|zxw' | head -40
echo "--- processes:"; sh 'ps -A 2>/dev/null || ps' | grep -iE 'can|mcu|car|vehicle|hct|mtc|fyt|zxw|syu' | head -40

section "PARTITIONS (for dump/EDL planning)"
sh 'ls -l /dev/block/by-name 2>/dev/null | head -80 || ls -l /dev/block/bootdevice/by-name 2>/dev/null | head -80 || echo "(by-name not readable without root)"'
sh 'cat /proc/partitions 2>/dev/null | head -60'
sh 'mount | grep -E " / | /system | /vendor | /oem | /odm | /product " '

section "USB / OTG"
for p in sys.usb.state sys.usb.config persist.vendor.usb.config ro.boot.usbcontroller; do prop "$p"; done
sh 'ls /sys/class/udc 2>/dev/null; cat /sys/class/udc/*/state 2>/dev/null'
echo "NOTE: the USB port that puts the unit in 'device/OTG' mode is the one QFIL/EDL uses."

section "RECENT LOG LINES MENTIONING CAN / MCU (snapshot only)"
sh 'logcat -d -t 400 2>/dev/null' | grep -iE 'can|mcu|canbus|canbox|decoder|tty|vehicle' | tail -60

section "DONE"
echo "Saved to $OUT — share this file (it contains no secrets, but review before posting publicly)."
