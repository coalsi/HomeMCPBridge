# Open questions, and the read-only checks that would settle them

Supporting file for `../DEVICE-FACTS.md` (mainly sections 2, 5 and 7). **Nothing in this file has been run.** It
was written on 2026-10-11 from local records only. Every device check below waits for the owner's explicit OK,
given in chat for that check, and runs only with the truck parked in P.

## Ground rules for any later check

- **Read-only means read-only.** The commands below only print to the screen (`getprop`, `dumpsys`, `ls`, `cat`,
  `logcat -d`, `sha256sum`, the on-unit `dexdump`). `adb pull` copies a file to the Mac and changes nothing on the
  unit. Nothing here uses `setprop`, `am`, `pm disable`, `settings put`, `remount`, broadcasts or bus writes, except
  the items in the "not read-only" list at the end, which are labelled.
- **Do not print secrets.** Skip `ro.serialno`, the USB `serial` attribute, Bluetooth/Wi-Fi addresses, Wi-Fi
  credentials and account data. If any of them show up in output, leave them out of notes.
- **Settings-menu checks are for the owner.** Look only: back out of every page without pressing "Save & reboot".
  This document does not record, and nobody should write down, any access code for the factory settings menu.
- **Never** open `com.lfg.szchoiceway.canupgrade` (CAN-gateway firmware updater). Never write `/system`,
  `/product` or `/vendor` (dm-verity: it bricks the unit).
- A connection to the unit itself also needs the owner's OK. Its address is not recorded in these files.

Typing note: inside the tables, `\|` is Markdown escaping. When typing a command, use a plain `|`.

Legend for "Who": **Owner** = the owner looks at something, no tools. **Owner (menu)** = the owner views a vendor
settings page. **Claude (adb, read-only)** = a command Claude would run after an explicit OK.

## Section 2: identifying the unit

| # | Question | Why it matters | Who | Exact check | Settles it when |
|---|---|---|---|---|---|
| 2.1 | Is the GT7A Pro-CAR the unit in the truck today, and where is the GT6-CAR? | README.md and CLAUDE.md still say the GT6 is in the truck; every live record since 2026-07-26 is the GT7A. The vendor AIDL codes and action names came from one unit's APKs | Owner, then optionally Claude | Owner: say which box is behind the dash and where the GT6 is. Optional: `adb devices -l` (product string only) | The answer, or product `GT7APro-CAR` |
| 2.2 | Is the SoC really a Snapdragon 685-class part? | Only the "QCOM 685" model string says so | Claude (adb, read-only) | `adb shell getprop ro.board.platform` ; `adb shell getprop ro.soc.manufacturer` ; `adb shell getprop ro.soc.model` ; `adb shell "grep -i -E 'hardware\|model name' /proc/cpuinfo"` | A platform name such as `bengal`/`SM6225` family, or a different one |
| 2.3 | Are the held EventCenter.apk and console dump from this unit? | They are the source of the binder codes and car-type tables | Claude (adb, read-only) | `adb shell sha256sum /product/app/EventCenter/EventCenter.apk` (expect `49d00361…5692`). For the console: `adb shell "/apex/com.android.art/bin/dexdump -d /product/app/ATSLCarConsole/ATSLCarConsole.apk \| sha256sum"` (expect `55c74d96…5485`) | Hashes match |
| 2.4 | Is there a Fibocom smart module under the ZXW board? | Low priority; explains `fibo_auto_frvc` | Claude (adb, read-only) | `adb shell "getprop \| grep -i -E 'fibo\|fibocom'"` | Any fibo property, or none |

## Section 5: decoder and factory configuration

| # | Question | Why it matters | Who | Exact check | Settles it when |
|---|---|---|---|---|---|
| 5.1 | What CAN profile is set (protocol, brand, model, year)? We have the numbers 16 / 349 but not the menu's own words | The numbers are reused across vendor tables, so the names are inferred | Owner (menu) | In the vendor Settings app, open the factory settings menu and find the CAN / car-model page. Note the protocol, brand, model and year shown. Back out without saving. Do not change it: a wrong profile can break climate and factory touch | The owner reads the page text to us |
| 5.2 | Does the live unit still report car type 16 / logo type 349? | Confirms the 2026-07-27 log | Claude (adb, read-only) | `adb shell "logcat -d \| grep -E 'getCanCarType\|getLogoType'"` (only finds something if the log buffer holds a recent ACC cycle) | A matching LogoWindowView line |
| 5.3 | Who makes the CAN decoder box? | Decides which protocol documentation applies (only the 0x2E framing is known) | Owner | Look at the head-unit kit's order page or manual for the canbox brand; or read the label on the decoder box in the harness behind the screen the next time the dash is open. Do not remove trim just for this | A brand/model name |
| 5.4 | Which UART does EventService really hold open: `/dev/ttyHS1` (hard-coded) or `/dev/ttyS1` (default constant)? | Needed only if we ever sniff the serial link | Claude (adb, read-only) | `adb shell "ls -l /proc/\$(pidof com.szchoiceway.eventcenter)/fd 2>/dev/null \| grep -E 'tty\|serial'"` | A symlink to `/dev/ttyHS1` (expected) or another tty |
| 5.5 | What is `mAirSupplierID` on this unit? | Explains which console sender branch applies | Claude (adb, read-only) | `adb shell "logcat -d \| grep -i -E 'mAirSupplierID\|mCanType'"`. If the buffer has nothing, the value is only logged while the vendor Console is open, and opening it changes the MCU source mode and pauses audio (see "not read-only") | A logged value |
| 5.6 | Where do "car type 84" and "mCarType 16-177" come from? | Our comments disagree with the observed 16 / 349; the only EventUtils CARTYPE equal to 84 is a Toyota Corolla entry | Claude (adb pull, read-only on the unit) | `adb shell pm path com.szchoiceway.canbus`, then `adb pull <that path> ~/mycarplay-refs/Canbus.apk`, then on the Mac search its dexdump for `BuickCanService`, `84` and `177` | The canbus app's own profile table explains them |
| 5.7 | Trim: LT Trail Boss or Custom Trail Boss? | Dual-zone automatic climate suggests LT; not confirmed | Owner | Window sticker, registration, or the RPO list on the Service Parts Identification label in the glovebox | The trim name |
| 5.8 | Platform: 2022 "1500 LTD" carryover (old interior) or the refreshed 2022? | Our body-bus decodes are Global A layouts; the vendor names the profile "SILVERADO_NEW_22" | Owner | The window sticker or registration says "1500 LTD" for the carryover. General knowledge, not from our files: the refreshed 2022 has a 13.4-inch horizontal centre screen and a digital cluster, while the carryover has a smaller radio screen | Either label |
| 5.9 | Factory radio screen: 7-inch or 8-inch? | Only the 800x480 touch space is known; a code comment says 8-inch | Owner | The owner knows the factory radio; or the RPO list in the glovebox | The size |
| 5.10 | Bose / premium amplifier? | Nothing on record anywhere | Owner | Look for Bose badges on the door speaker grilles; or the window sticker / glovebox RPO list | Yes or no |
| 5.11 | Which bytes carry the door bits (0x24) and the 0x36 values? | The code reads payload[0] for doors, but a captured example has 0x80 in payload[2]; the 0x36 example and the code differ by one byte | Claude (adb, read-only), owner opens doors | Parked: owner opens and closes the driver door, then the passenger door, while Claude afterwards runs `adb shell "logcat -d \| grep -E 'MCUDEC\|BaseCanNew'"`. This works only if the installed build logs raw frames under tag MCUDEC; if not, a logging-only build is needed first (a code change, no device write) | Raw frames line up with the door events and with the vendor's dashboard values |
| 5.12 | Is MCU cmd 0x0B road speed? | One valid 0x0B frame was seen in the vendor console; /16 gives 108 on a probably parked truck | Claude (adb, read-only) after a normal drive | Owner drives normally; nobody touches the unit while moving. Afterwards: `adb shell "logcat -d \| grep MCUDEC"` and compare 0x0B values with GPS speed for the same times | 0x0B tracks speed, or it does not |
| 5.13 | What unit is the MCU steering value (cmd 0x26, raw/195)? | Max ±168 "degrees" is far below a truck's ~±540° wheel range | Owner + Claude (adb, read-only) | Parked, engine running: owner turns lock to lock once, slowly, counting wheel turns. Afterwards read the logged 0x26 values as in 5.11 | Ratio of logged range to the counted turns |
| 5.14 | Steering-wheel button codes (`MCU_KEY_INFOR` / `EventUtils.MCU_KEY_VALUE`) | Received but unmapped | Owner + Claude (adb, read-only) | Parked: owner presses each wheel button once, in a stated order. Afterwards `adb shell "logcat -d \| grep -i -E 'MCU_KEY\|KEY_VALUE'"`. If nothing logs it, a logging-only build is needed first | One code per button |
| 5.15 | Do `setDashBoardCallback` / `setCanA5DataCallback` / `setCanA6DataCallback` deliver frames? | If A5/A6 carry raw GMLAN ids, gear / 4WD / SOC could come without the MX+ | Claude (adb, read-only) | `adb shell "logcat -d \| grep GT7BUSPROBE"` with myCarplay running and the engine on | Any frame counts above zero |

## Section 7: physical / USB

| # | Question | Why it matters | Who | Exact check | Settles it when |
|---|---|---|---|---|---|
| 7.1 | Physical diagonal and mounting of the 1440x1920 panel | Not recorded anywhere | Owner | Tape-measure the visible screen area corner to corner | A number in inches |
| 7.2 | What is the second USB device (VID 0x534D, likely MacroSilicon)? Is it the reverse-camera or AV capture path? | Reverse camera is still unresolved | Claude (adb, read-only) | `adb shell 'for d in /sys/bus/usb/devices/*; do [ -f $d/idVendor ] && echo "$d $(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/manufacturer 2>/dev/null) $(cat $d/product 2>/dev/null)"; done'` (deliberately does not read `serial`) | Product id and name |
| 7.3 | Dongle model: Carlinkit CPC200-CCPA (docs) or "A15W" (what the box reports)? | Same device under two labels, or not | Owner | Read the model printed on the dongle's case or box | A model string |
| 7.4 | Reverse camera: eventcenter-brokered like the factory LVDS feed, or Camera2 through auxcamera? | Integration path | Owner (shifts) + Claude (adb, read-only) | Passive park test in a safe open spot: a second person, engine running and foot on the brake, shifts to R and back. Claude watches `adb shell "logcat -v time \| grep -i -E 'BACKCAR\|auxcamera\|ms2160\|frvc'"` and runs `adb shell dumpsys SurfaceFlinger --list` before and during. Never spoof the gear signal | Which component draws the camera |
| 7.5 | Factory video deserializer: LT8918 (observed) or PR2000 (a vendor code comment)? | Tidies a contradiction | Claude (adb, read-only) | `adb shell ls /sys/lt8918` ; `adb shell "dmesg \| grep -i -E 'lt8918\|pr2000\|ms2160\|ms9120'"` | Which drivers load |
| 7.6 | Storage type (UFS?) | Low priority | Claude (adb, read-only) | `adb shell "ls -l /dev/block/by-name/ \| head -40"` ; `adb shell cat /sys/block/sda/device/model` (model only) | `sda` devices and a UFS model string |
| 7.7 | Is the ACX_Dash cluster physically installed yet? | Records disagree | Owner | Say so | The answer |

## Questions that need no device at all (desk work)

- Fix stale text: README/CLAUDE.md "GT6 in the truck"; "car type 84" comments (HvacState.kt:5, ChoicewayCanSource.kt:15-16);
  README "Known gaps" (dashboard feed is decoded, not just logged); CardSlotsStore.kt:53-54 comment; commit b992b6d's
  claim; DataCatalog GMLAN labels for steering ("0x124") and SOC ("0x148").
- Recover the GT6-era memory notes and raw captures from the Mac Studio's CorPlayDroid project memory
  (`headunit-canbus`, `headunit-hvac`, `obd-elm327-live`, `gmlan-opendbc-map`, `xlink-carlinkit`). This needs the
  owner to copy them over; nothing on this Mac has them.
- Decide the fuel header (0C800040 vs 10800040) in code by accepting both until a capture settles it.

## Not read-only (excluded from the lists above; each needs a separate, explicit owner OK)

- Rear-defrost air key 20 and airflow key 33: these **write to the vehicle bus**.
- Opening the vendor Console (`com.android.atslcarconsole`): passive for the bus, but it switches the MCU source mode
  (30, SRC_ATSL_AIRCONSOLE) and pauses audio. Leave it with its own Quit button; HOME does not close it.
- Re-running McuProbe or ChoicewayCanProbe: needs `setprop log.tag.MCUPROBE V` / `log.tag.CANPROBE V`, a runtime
  property change. Harmless, but not strictly read-only.
- Any change in NaviSettings or the factory settings menu ("Save & reboot").
