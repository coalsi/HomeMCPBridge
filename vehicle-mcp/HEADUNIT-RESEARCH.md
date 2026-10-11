# Head unit research: 15.6" GM Silverado/Sierra Qualcomm unit

*Running memory for the mycarplay project. Compiled 2026-10-11 from public sources
(linked inline). Nothing here was read off the actual device yet — see
"Open questions" for what only the device can answer.*

Unit under study: Amazon ASIN B0DDCCJDVW, brand "VIKNAN", 15.6" vertical
("Tesla-style") 2K IPS, "Qualcomm 8G+128G", fits 2019–2023 Silverado/Sierra,
ships with harness + CAN decoder box. Owner has: a custom launcher (mycarplay) set
as default, ADB over Wi-Fi, **no root yet**.

---

## 1. What this device actually is

### It's a commodity ODM product, not a "VIKNAN" design
The same 15.6" GM unit is sold under at least a dozen storefront names with
near-identical copy: VIKNAN, SNATEEN, XUENAV, AUCARAUTO/AuCar, AutoTecPro,
CoupleNavi, ZWNAV, TPXINXIN, plus eBay/Walmart/Newegg relists
([search summary](https://www.amazon.com/clp/B0DG291Q91),
[ZWNAV @ Walmart](https://www.walmart.com/ip/ZWNAV-15-6-Inch-Qualcomm-Android-Car-Radio-Chevrolet-Chevy-Silverado-GMC-Sierra-2019-2020-2021-2022-2023-2024-Stereo-Upgrade-Tesla-Style-Head-Multime/15985100856),
[AuCar](https://aucarauto.com/product/aucar-tesla-android-15-6-car-radio-for-gmc-sierra-chevrolet-silverado-2019-2024/),
[AutoTecPro](https://autotecpro.com/product/chevrolet-silverado-gmc-sierra-15-6-ips-qhd-2k-touch-screen-navigation-infotainment-system-android-13-gps-bt-wifi-carplay-onstar-4g-lte/)).
"VIKNAN" is the Amazon storefront of **VIKNAV** ([viknav.com](https://viknav.com/)),
a Shenzhen-area (+86, GMT+8, Shenzhen/HK trade shows) reseller/"developer" that
does not name a factory and publishes no firmware. The actual mainboard maker is
upstream of all of these brands and is **not identifiable from listings** — only
from the device itself (see §6).

### The silicon: Qualcomm QCM6125 ("Snapdragon 665")
Every listing in this family that names a chip says Snapdragon 665. In head units
that is the **QCM6125**, Qualcomm's IoT/automotive bin of the SM6125, board
codename **`trinket`**, usually delivered inside a **Quectel SC668S-EM** module,
kernel **4.14.x**
([XDA: identify SM6125/trinket/Z35](https://xdaforums.com/t/help-identify-android-head-unit-qualcomm-sm6125-trinket-z35-mcu-kernel-4-14-117.4745109/),
[XDA: Snapdragon-based headunit identify/rooting](https://xdaforums.com/t/recent-snapdragon-based-headunit-identify-resources-rooting.4663908/)).
Resolution reported as 1920×1440 (or 1440×1920 portrait). "Android 13" claims on
this platform are frequently an older Android with a spoofed version string
([XDA Joying SD665](https://xdaforums.com/t/custom-rom-development-2023-joying-qualcomm-snapdragon-665-headunits.4661801/)) —
check `ro.build.version.sdk` against `release`.

### QCM6125 is a known, well-trodden XDA platform with several sub-families
Same SoC, **different vendor firmware stacks and MCUs**. Which one you have
decides which firmware/root threads apply:

| Family | Markers | Notes |
|---|---|---|
| **MTCH** (Microntek Qualcomm; Dasaita, Eonon…) | `/system/priv-app/HCTManagerService`, `ro.board.platform=qcm6125` | Shared Android `update.zip` across makers; MCU `dmcu.img` is per-maker ([XDA MTCH QCM6125](https://xdaforums.com/t/mtch-qualcomm-snapdragon-665-head-units-qcm6125-android-12.4635019/)) |
| **ZXW / "GT6"** (Xtrons-type) | `/mnt/privdata1/zxw_factory_config.xml` | SM6125 = GT6, SM6225 = GT7; USB `update13.zip` ([kamilbrk FAQ](https://kamilbrk.github.io/headunits/faq/zxw/)) |
| **Z35 / "ZongHeng TD QCM6125"** (Coika & many AliExpress/Amazon brands) | MCU string like `z35.qxs241030a.z665` / `Z35_QXH230329A_…_6125` | Update refused if MCU model mismatches ([XDA Z35](https://xdaforums.com/t/new-aliexpress-head-unit-audi-a6-coika-vendor-9-android-12-mcu-z35-qcm6125.4556469/)) |
| **Joying** (own stack) | Joying branding/apps | Locked: no recovery, no fastboot; EDL+QFIL root works ([XDA Joying QCM6125](https://xdaforums.com/t/official-2023-newer-redesigned-joying-head-unit-discussion-qcm6125-android-12.4619495/)) |
| **Topway/Toparea QCM6125** | Topway apps, Android 11 | Signature-verified update path blocked Magisk ([XDA](https://xdaforums.com/t/looking-for-root-path-on-topway-toparea-qcm6125-android-11-head-unit.4791799/)) |
| **STA_GT MCU**, **G3986 (2000×1200)** | MCU strings | Other QCM6125 variants seen ([XDA](https://xdaforums.com/t/looking-for-firmware-update-qualcomm-sc668s-qcm6125-mcu-sta_gt.4783877/), [XDA](https://xdaforums.com/t/firmware-and-mcu-needed-g3986-qcm6125-11-rkq1-qti-trinket-2000-1200-mcu-v0-20-1-g14726-please-help.4795950/)) |

Dead end checked and ruled out: **Topway TS18 is UNISOC (UIS8581A), not
Qualcomm** — TS18 firmware/root threads do **not** apply
([XDA TS18](https://xdaforums.com/t/ts18-devices-branded-topway-alwinner-online-help-firmwares-and-other-stuff.4558675/)).

---

## 2. How the truck's data reaches Android (this changes the plan)

**The Android SoC never sees raw CAN.** The architecture on essentially all of
these units:

```
 truck CAN  →  CAN decoder box (own STM32-class MCU, in the harness)
            →  UART  →  head-unit MCU (power/SWC/amp/CAN gateway)
            →  UART  →  Android, exposed as a virtual serial port (e.g. /dev/ttyV0,
                        19200/38400/115200 baud) parsed by the VENDOR framework
            →  vendor service / broadcasts / SDK  →  apps (mycarplay)
```
([XDA: how CAN messages get into the unit](https://xdaforums.com/t/how-do-can-bus-messages-make-it-into-the-unit.3352343/),
[XDA CANBOX reverse engineering](https://xdaforums.com/t/canbox-can-decoder-reverse-engineering.4057759/page-3),
[darkspr1te decoder re-firmware](https://github.com/darkspr1te/Android_obd_Remote)).

Consequences:

1. **There is no `can0`/SocketCAN inside the head unit.** The SocketCAN discovery
   tool in this folder applies to a *raw* bus tap (e.g. via the OBDLink MX+ or a
   USB CAN adapter), not to what the head unit itself receives.
2. **"Some things are off" is most likely a decoder-protocol selection problem,
   not an app bug.** The decoder brand (Raise, Hiworld, XP, Simple Soft…) and the
   vehicle/trim variant are chosen in the hidden **Factory Settings** menu.
   Silverado owners report steering-wheel controls and climate data working
   "INSTANTLY" once the correct manufacturer/trim was selected
   ([silveradosierra thread](https://www.silveradosierra.com/threads/android-head-unit-update.718889/));
   a reported ambient-temp readout that jumps to −255 °C below 0 °C is a classic
   decoder/parse mismatch. The 7" vs 8" OEM-screen variants of the 2019+ trucks
   use **different wiring and software** — the wrong variant mis-decodes.
3. **Fixing mycarplay reliably therefore means:** (a) correct decoder/vehicle
   config in Factory Settings, (b) know which vendor service/API mycarplay reads
   from, and (c) with root, sniff the MCU↔Android serial to see the actual
   decoder frames and compare against what the vendor service publishes.

The decoder serial framing seen in the wild is `start byte, command, length,
data…, checksum` (vendor-specific values); Raise-style boxes often run 19200
8N1. This is what a root shell would let us capture.

---

## 3. Can we build our own Android OS for it? (Question 1)

**Short answer: not from scratch — but a "focused firmware" built *on top of* the
stock one is realistic and is what the community actually does.**

Why a ground-up build is blocked:
- **No kernel source.** The GPL-mandated kernel source is not published; Quectel
  told an XDA member they only release it to companies
  ([XDA Joying SD665 custom ROM thread](https://xdaforums.com/t/custom-rom-development-2023-joying-qualcomm-snapdragon-665-headunits.4661801/page-4)).
  Phone SM6125 trees exist (Xiaomi/OPPO) but do not match head-unit hardware
  (display, MCU UART, audio DSP, touch).
- **No device tree / vendor blobs** for this board; the MCU protocol lives in
  proprietary vendor framework code.
- **Firmware mismatch = unit stuck at boot with no recovery** (the ZXW FAQ's
  explicit warning; the MTCH thread's warning that MCU files are per-maker).

What *is* realistic ("modified stock" firmware — the Malaysk-ROM model):
- Keep the vendor **kernel, vendor/odm partitions and MCU firmware untouched**.
- Root (Magisk, systemless) and then: debloat, install **mycarplay as a
  privileged/persistent system app** and the only HOME, auto-start it, add your
  own services (e.g. a CAN-serial reader), lock down OTA.
- A community ROM of exactly this kind already exists for QCM6125:
  [Malaysk ROM QCM6125 (MTCH/HCTGQ, Android 12–13, Magisk)](https://xdaforums.com/t/rom-qcm6125-s-12-0-13-0-malaysk-rom-qcm6125-mcu-mtch-hctgq-android-12-13.4650179/page-2)
  — only applicable if the unit turns out to be MTCH/HCTGQ family.

This gives "my launcher as the heart, control of every user-facing aspect" with a
fraction of the risk. **Never flash another maker's MCU (`dmcu.img`).**

---

## 4. Taking control without soldering (Question 2)

Ordered by risk, lowest first. Stop at the first one that works.

1. **Check whether root is already there.** Many QCM6125 units ship with
   `su`/root-capable adb (the Joying dump was taken with "SU adb access"; ZXW
   docs assume `su` works over adb). Run `headunit_identify.sh` — it reports
   `ro.debuggable`, `id`, `su -c id`, `adb root`. If this is yes, *most of the
   work is already done*: dump partitions from `/dev/block/by-name`, modify
   `/system`, no flashing needed.
2. **Factory Settings password.** Opens decoder selection, MCU info, developer
   options. **The code for this unit is known to the owner (confirmed working
   2026-10-11) — deliberately not stored in this repo.** For reference, other
   firmwares use **8888, 1234, 000000, 126, 3368**, date-based
   (`yyyymmdd` / `yyyy.mm.dd`), or `7890`+hour
   ([XDA](https://xdaforums.com/t/android-head-unit-factory-setting-password.4063267/),
   [pin list](https://android-headunits.com/pin-codes-for-android-headunit/)).
   Also simply ask the seller — they usually give it.
3. **Vendor update package via USB stick** (the sanctioned flash path). Ask the
   seller for the **exact firmware + MCU package for your MCU string**. It is the
   golden reference for dissection (contains boot/system images) without touching
   the device. Flashing *modified* packages is usually blocked by signature
   checks, so this is for reading, not for installing custom builds.
4. **Qualcomm EDL (9008) over USB.** No soldering: on the Joying QCM6125 units
   people connected the **port marked OTG** to a PC, used **QFIL → Partition
   Manager** to back up `boot`, Magisk-patch it, and write it back
   ([XDA Joying QCM6125 p.2](https://xdaforums.com/t/official-2023-newer-redesigned-joying-head-unit-discussion-qcm6125-android-12.4619495/page-2)).
   Entry is normally `adb reboot edl`; fallbacks are an EDL (shorted D+/D−)
   cable, then test points (requires opening — last resort). Needs a
   **firehose loader matching the device's root-cert hash**; SM6125 loaders
   circulate (`prog_emmc_firehose_Sm6125_ddr.elf` in
   [hoplik/Firehose-Finder](https://github.com/hoplik/Firehose-Finder)) but must
   be verified by hash, not filename
   ([XDA loader identification](https://xdaforums.com/t/identifying-edl-firehose-loaders.4525079/page-8)).
   Tooling: [bkerler/edl](https://flashguidehub.com/bkerler-edl/) or QFIL.
   **A full EDL read of the eMMC is the complete "dissection"** — and reading is
   far safer than writing.
5. **fastboot** — reported *disabled* on these units; don't plan on it.

Hard rules: back up every partition before writing anything; only ever write
`boot` (Magisk) unless you have a verified full backup; never write MCU.

---

## 5. Wi-Fi vs USB — my risk assessment (Question 3)

- **ADB over Wi-Fi for reading is fine.** `getprop`, `pull`, partition dumps —
  verify with `sha256sum` on both ends. A dropped connection just re-runs.
- **Never write over Wi-Fi — and you mostly can't anyway.** The tools that
  actually flash (EDL/QFIL, fastboot) are **USB protocols**; the question largely
  answers itself. If root lets you `dd` to a partition from a shell, do that over
  **USB** adb with the truck's power stable.
- The truck's hotspot being inches away makes link quality a non-issue. The
  real risks are different: **power** (ignition/accessory timeout cutting the
  unit mid-write → brick; keep ignition on or a battery maintainer on) and
  **exposure** (adb on tcp/5555 accepts any paired host on that Wi-Fi; harmless
  in a truck, but turn it off when done: `adb usb`).
- USB port roles: one is a **host** port (CarPlay dongle / USB stick with
  `update*.zip`), the other usually goes **device/OTG** mode for a PC — that's
  the QFIL/EDL port. `headunit_identify.sh` prints the UDC state to tell them
  apart.

---

## 6. Open questions only the device can answer

Run from the Mac: `./headunit_identify.sh <ip>:5555` and paste the output file.
It decides the family (§1 table), root state, MCU string, serial nodes, and the
vendor service that feeds mycarplay. Also needed:

1. **Factory Settings**: can you get in? Which code worked? What **decoder brand**
   and **vehicle/trim** options exist, and what is selected now (7" vs 8" OEM
   screen variant, Bose, auto vs manual HVAC)?
2. **Stickers**: on the CAN decoder box in the harness (brand/model — Raise,
   Hiworld, XP…) and on the unit's rear label (model, MCU, board code).
3. **How mycarplay gets truck data today** — vendor SDK, broadcast intents,
   content provider, or reading a tty? (The identify script's package/service
   lists will suggest it.)
4. **Truck**: exact model year and trim; OEM screen size; HVAC type.
5. **Seller firmware**: ask VIKNAN/VIKNAV for the firmware + MCU update package
   and the factory password for your unit's MCU version.
6. **USB**: which port is labelled OTG; does a PC enumerate the unit when
   plugged in (and as what — ADB, MTP, or "QDLoader 9008")?

---

## 7. Recommended path

1. Identify (script) → place the unit in the §1 table.
2. Get into Factory Settings → fix decoder/vehicle config → see how much of
   "data is off" disappears before touching anything else.
3. If root already present → dump, then build the mycarplay-centric system mod.
4. Else → seller firmware package (read) + EDL boot-patch root (USB).
5. With root → capture MCU↔Android serial while performing truck actions (same
   method as `can_discovery.py`, different source) → definitive signal map.
6. Keep the OBDLink MX+ path as an independent raw-bus cross-check.
