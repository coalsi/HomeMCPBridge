# Device facts: the Silverado's head unit

**Compiled on 2026-10-11 from local records only.** Nobody connected to the head unit, the truck or any network
device to write this. The sources are: the memory notes; the myCarplay code at git commit `4a4ef50` (read from that
commit, not from the working tree another agent is editing) and its commit messages; the iCloud truck folder; the
vendor APK and dexdumps in `~/mycarplay-refs`; the 2026-09-26 partition backups; earlier session transcripts; and the
cluster projects (`~/cluster-app`, `~/acx-sim`, `~/cor-sim`).

Sections 2, 5 and 7 end with what is still open and the exact read-only check that would settle each item. **None
of those checks has been run.** Each one waits for the owner's explicit OK and runs only with the truck parked.
Checks the owner can do by looking (window sticker, a Settings page, a label) are written for the owner. The full
list is in `device-facts/open-questions-and-checks.md`.

**Provenance tags used on every fact**

- **[OBSERVED on device]**: seen live on the head unit or truck during past work. The cite says where it was
  recorded (memory note, log file, transcript, commit message).
- **[FROM FILES we hold]**: read in a file on this Mac. Cited as `path:line`.
- **[FROM DOCS/forums]**: from published documentation. Nothing was fetched for this document, so this tag is not
  used below; general background knowledge is tagged [INFERRED] and says so.
- **[INFERRED]**: a conclusion. The cite says what it rests on. It is never an observation.

Short forms: **HEAD** = myCarplay commit `4a4ef50`. Code paths such as `obd/…` and `hvac/…` are under
`~/mycarplay/app/src/main/java/com/coreysilvia/mycarplay/`. **audit** = memory note `head-unit-vendor-stack-audit.md`.
**iCloud truck folder** = `~/Library/Mobile Documents/com~apple~CloudDocs/mycarplay-truck/`. **ce112634** and
**274afb41** = session transcripts in `~/.claude/projects/-Users-coreysilvia-Documents-head-unit/`. Private values
appear as [redacted] (see `device-facts/redactions.md`). Inside tables, `\|` is Markdown escaping for a plain `|`.

**Checked on 2026-10-11 (local files only).** More than 60 facts were checked against their cited sources, including
every fact in section 2 and every row of the 4.2 table. Corrections made: the claim that 16 is also
`CARTYPE_yinglang_LO_NEW` was a misread (it is 109), so in EventCenter 16 and 349 each have exactly one name; the
logo-type group includes the Colorado; the 33 vendor packages span five namespaces; the coolant and oil-pressure ranges
now match the logs; two tags were changed from [OBSERVED] (console mode / `isHorizontal`, the app's heading path);
the MCU command list in 6.5 now separates what our app saw from what came from the console or the code; an
engine-detail row was added to 4.2; one vendor number was redacted.

### The short answer to the owner's question

Yes. Most of what is needed was saved during earlier work: what the unit is, how the app talks to it, which truck
signals really arrive and which never do, the decoder profile, the GM bus maps and the hardware details. They are
collected below. Without touching the head unit we can fix stale docs and comments, make code changes that need no
new capture (section 4.4), and keep testing against the simulator. About a dozen questions remain. Most of them the
owner can answer by looking: trim, Bose, factory screen size, the decoder box label, the dongle label. The rest are
short read-only checks for a later session, run only with the owner's OK.

---

## 1. What we already know

### 1.1 Which head unit is in the truck

- Two units appear in the records. **GT6-CAR** (described as "GT6-EAU / Choiceway (SD665)", Android 13) was the
  truck's first unit. **GT7A Pro-CAR** (Android 14, SDK 34) replaced it. [FROM FILES we hold]
  HEAD CARPLAY_APP_HANDOFF.md:7; HEAD README.md:28-33; HEAD CLAUDE.md:18-24.
- **Every live observation from 2026-07-26 on is of the GT7A Pro-CAR:** the adb product string (2026-07-29 and
  2026-09-26), the vendor Software Version screen (2026-07-29) and the logcats of 2026-07-27 and 2026-09-26.
  [OBSERVED on device] ce112634:163 (adb `devices -l` / `getprop`, 2026-07-29T20:52Z); audit:58; iCloud truck folder
  `incident-2026-07-27-raw.log`; PROJECTS.md:15 in the iCloud truck folder.
- README.md and CLAUDE.md still say the GT6 is "in the truck" and the GT7A is "going in now". That text is stale
  (see 1.7). Where the GT6 is now is not recorded.

### 1.2 The unit in one paragraph

A ZXW / Shenzhen Choiceway "GT7A Pro" Android 14 head unit on a Qualcomm "685" platform, with a 1440x1920 portrait
panel, ~8 GB RAM and 8 cores. It keeps the factory GM radio, shows that radio's 800x480 screen over LVDS, and sends
touches back to it through the CAN box. A vendor broker app, `com.szchoiceway.eventcenter`, owns the MCU serial link
and the CAN box behind it. Details and evidence: section 2. [OBSERVED on device] audit:58; ce112634:163,1054;
[FROM FILES we hold] `privdata2_zxw_config.bin`; HEAD carplay/StereoFeedController.kt:17-39.

### 1.3 How the vendor stack behaves

- **Vendor broker.** `com.szchoiceway.eventcenter` (`.EventService`, shared system uid 1000) brokers CAN and
  telemetry, AUX/factory video and MCU commands. myCarplay reaches everything it needs as a normal app through it,
  without root. [OBSERVED on device] audit; incident-2026-07-27-app-restart.md:20-49.
- **ACC standby kills our app.** On ACC off, `AccEvent.Utils.standby()` turns Wi-Fi off, stops the soft AP, then
  force-stops every third-party app, myCarplay included (its allowlist names four hardcoded packages, so holding HOME
  does not help). myCarplay comes back as HOME ~9 s later. Seen live on 2026-07-27 at 18:59 (pid 4080 = eventcenter).
  [OBSERVED on device] incident-2026-07-27-app-restart.md; incident-2026-07-27-raw.log:1-30; HEAD state/SessionLog.kt:46-55.
- **HOME role.** myCarplay (`com.coreysilvia.mycarplay`, uid 10127, in `/data/app`) holds `android.app.role.HOME`
  alone. AOSP Launcher3 (`/product/app/Launcher3-A14`) is a dormant fallback; customerui's `PortraitMainActivity`
  also declares HOME but never resolves. myCarplay is direct-boot aware since 0.1.127 (commit 22ef542), which fixed
  the vendor launcher winning after cold boots. [OBSERVED on device] audit:19; incident-2026-07-27-raw.log:9-13.
- **Brick rule.** `/system`, `/product` (and `/vendor`) are dm-verity **enforcing**; writing them bricks the unit.
  There is no fastboot, no exposed USB device port and no recovery. Writable, verity-free: `/data` and
  `/mnt/privdata1`. [OBSERVED on device] iCloud HANDOFF.md:86-88; HEAD README.md:35-40.
- **Security posture looser than stock:** SELinux Permissive, vbmeta unlocked, adbd runs as root (`u:r:su:s0`);
  APKPure is one of the 8 user apps. [OBSERVED on device] audit:17,25; ce112634:254.
- **Debug access is Wi-Fi only.** Root adbd on a fixed TCP port since 2026-07-27 (`persist.adb.tcp.port`; address
  [redacted]). The link drops at every ACC standby because Wi-Fi is cycled. `screencap` renders video planes black,
  so video, CarPlay and the factory screen can only be judged on the glass. `dexdump` is on the unit at
  `/apex/com.android.art/bin/dexdump`. [OBSERVED on device] iCloud HANDOFF.md:94-114; memory air-build-environment.md:25-28.
- **Built-in CarPlay is off on purpose.** The vendor embed (`com.sylink.service` → `com.szchoiceway.zxwlink`) works
  but forces the head unit's Wi-Fi off, which drops the instrument cluster off the LAN. `Features.BUILTIN_CARPLAY`
  stays false; the wired Carlinkit dongle is the required renderer. [OBSERVED on device] HEAD CLAUDE.md:44-48;
  HEAD state/Features.kt:38.
- **The amplifier listens to the MCU, not Android.** The vendor's Silverado profile sets
  `mAndroidAudioMngStandard=false`. CarPlay audio needs the MCU frame `3F 00 01` ("ARM audio active") plus unmute
  `0A 00` and a 2 s heartbeat; confirmed on build 109 (2026-07-26). Claiming a source (`01 0B`) would cut the FM
  radio. Only `SRX sendData` log lines prove a frame reached the MCU. [OBSERVED on device] iCloud HANDOFF.md:90-91,123-129;
  HEAD carplay/CarplayAudioPlayer.kt:58-82,353-360.

### 1.4 What the truck sends natively, and what only arrives over OBD

- An McuProbe sweep with the engine running subscribed to all 125 vendor CAN/MCU broadcast actions. **Only three
  ever fired:** `MCU_MSG_CAN_ALL_INFO` (raw `a5 2e` frames), `MCU_CAR_CAN_INFO` (speed, rpm) and
  `com.choiceway.canbus.carairstruct` (HVAC), plus `Action_DashboardInfo`. `CAN_CAR_FUEL_INFO`,
  `CAN_CAR_OUT_SIDE_TEMP_EVT` and the other 120 are defined in vendor code but never sent on this truck.
  [OBSERVED on device] commit 5ee8d96 message (2026-07-25); HEAD obd/McuProbe.kt:10-22.
- **Native (no OBD adapter needed):** speed and rpm; coolant, oil temp, trans temp and oil pressure; HVAC state;
  steering (MCU cmd 0x26, event-driven); driver and passenger doors (cmd 0x24, event-driven); factory radio video and
  touch. [OBSERVED on device] HEAD obd/ChoicewayCanSource.kt:22-24; obd/McuFrameDecoder.kt:96-124;
  hvac/HvacManager.kt:16-21; commits 0632a89, b3ce20b, 28aa1dc, b992b6d.
- **The vendor itself shows `--` (or 0) for:** battery volts, outside temp, fuel, speed (in the dashboard feed),
  range, odometer, oil life, TPMS and gear (`gearInfo` = 0 even in Park). So these are not parsing gaps on our side.
  [OBSERVED on device] commits 0632a89, b3ce20b; incident-2026-07-27-raw.log:231.
- **Only from the OBDLink MX+** (GM single-wire body CAN, reverse-engineered live on 2026-07-05): gear, odometer, oil
  life, drivetrain, lighting/turn, roll; plus, decoded but not yet truck-checked, TPMS, fuel, range, SOC, park brake
  (partial), trailer, lockers and doors. [OBSERVED on device] HEAD obd/SwCanBody.kt:7-11,92-93,211; obd/BluetoothObdSource.kt:416-473.

### 1.5 Proven on the truck

| Feature | Date | Provenance |
|---|---|---|
| Factory-screen touch with the GM/"Buick" frame `2E E3 05 …` (778/778 frames) | 2026-07-26, build 111 | [OBSERVED on device] memory factory-touch-gm-variant.md:11-31 |
| Factory radio video over LVDS (`/sys/lt8918/lt8918_signal` = 1, AIS counter ~60/s) | 2026-07-26 | [OBSERVED on device] HEAD StereoFeedController.kt:17-39; commits 2fa550e, dd1843b |
| CarPlay audio auto-start via the MCU 3F flag | 2026-07-26, build 109 | [OBSERVED on device] iCloud HANDOFF.md "Settled" |
| HVAC read and HVAC write (air keys via binder transaction 48), owner-confirmed and owner-locked | original confirmation attributed to the GT6; Max A/C noted working on the truck 2026-10-11 | [FROM FILES we hold] HEAD CLAUDE.md:49-53; README.md:28-33; memory hvac-ios27-restyle.md |
| Speed/rpm live from the MCU broadcast (on 2026-07-26 a touch test was refused because the truck read 70 mph) | 2026-06-30; 2026-07-26 | [OBSERVED on device] ChoicewayCanSource.kt:22; iCloud HANDOFF.md "Standing facts" |
| Dashboard temps and oil pressure from `Action_DashboardInfo` | 2026-07-25, 2026-07-27, 2026-09-26 | [OBSERVED on device] commits 0632a89, b3ce20b; incident raw log:231; ce112634 tool-results/b8hv78jy3.txt |
| Wired CarPlay dongle: no route guidance at all (310 frames, only MediaSongPlayTime; `supportFeatures` empty). Google Maps was navigating; Apple Maps never tried | 2026-07-26 | [OBSERVED on device] memory carplay-dongle-sends-no-nav.md:11-35 |

### 1.6 Caveat: which unit made the older observations

Records from before 2026-07-26 do not always say which unit they were made on. These may come from the GT6:
the speed/rpm confirmation (2026-06-30), the 2026-07-25 broadcast sweep, the door and steering ground truth, and the
original HVAC confirmation (README credits the GT6). Body-bus decodes come from the truck's own bus through the MX+,
so the head unit does not matter for them. Several were seen again on the GT7A (dashboard temps, speed, HVAC write),
and the 2026-07-25 code was named `Gt7EventBusSource` against an AIDL "reconstructed from the GT7 eventcenter", which
suggests that work was done on the GT7A. [INFERRED] from the dates above, HEAD IEventService.aidl:1-7, and the
re-observations listed in 1.5.

### 1.7 Where the sources disagree, and which one wins

| Question | Source A | Source B | Verdict and why |
|---|---|---|---|
| Which unit is in the truck | README/CLAUDE.md: GT6 | adb product strings, Software Version screen, logcats, EventCenter versionName: GT7A | **GT7A.** Live observations beat stale doc text. |
| Car profile number | Comments and commit 5ee8d96: "car type 84", "Buick/GMOld" | Logcat 2026-07-27: `getCanCarType(): 16, getLogoType(): 349` | **16 / 349 for EventCenter** (observed). One researcher said no CARTYPE equals 84; a check on 2026-10-11 found one, `CARTYPE_Kaluola_LO = 84` (Toyota Corolla, ec.txt:655200-655203), which cannot be this truck; the console's copy adds `CARTYPE_BM_BMW320 = 84` (console.txt:752595), also not GM. So 84 comes from another numbering, most likely the canbus app's own profile table (Canbus.apk, not held) or the GT6 APK. Unresolved, but not evidence against 16 / 349. |
| What 16 and 349 mean | ec.txt (EventCenter, the service that logged them): 16 = `CARTYPE_BUCIK_HI` and 349 = `CARTYPE_SILVERADO_NEW_22`, and no other EventCenter CARTYPE has either value (checker, 2026-10-11: only 4 duplicated values among the 501 CARTYPE constants in its EventUtils, none of them 16 or 349) | Only the vendor **console's** own tables reuse them: 16 = `CARTYPE_FORD_FIESTA` (console.txt:753665), 349 = `CARTYPE_MITSUBISHI_OUTLANDER` (console.txt:755485), both also in `Customer$CarType`. (An earlier draft said 16 = `CARTYPE_yinglang_LO_NEW` at ec.txt:656645; that was wrong: that line is `CAR_AIR_KEY_RWndMaxDefrost = 16`, and yinglang_LO_NEW = 109 at ec.txt:656450.) | **GM profile: high confidence; EventCenter names: high; names in other vendor apps: may differ.** Independent evidence: the GM/"Buick" HVAC and touch senders are the ones that work, and EventService groups logo types 220/349/353/221/224 (Silverado, Silverado new 22, Colorado new, Colorado, Tahoe) together (ec.txt 638338-638346). |
| `_HI` / `_LO` suffix | One researcher: high/low trim configuration | No local evidence either way (157 `_HI` and 147 `_LO` names in EventCenter; the "same value under both suffixes" example given earlier was a misread, see the row above) | **Meaning unknown.** The trim reading stays low confidence because nothing supports it, not because anything contradicts it. [INFERRED] |
| HVAC key timing | CARPLAY_APP_HANDOFF.md:125: ~95 ms holds + COMMIT_KEY(16) | HvacController.kt:72-79: 45 ms, no trailing key | **Code wins.** 16 is SYNC; the extra press toggled Sync (commit fe7d9b3), and the code was checked against the console's `BuickClickEvent`. |
| Outside temp broadcast | HvacManager registers `CAN_CAR_OUT_SIDE_TEMP_EVT` as the first source | 2026-07-25 sweep: never broadcast | **The sweep (an observation) wins.** The registration is harmless but should not be counted as a working source. |
| Dashboard feed | README "Known gaps": captured and logged only; commit b992b6d: the 0x36 decode replaced DashboardInfo | HEAD code: `Action_DashboardInfo` feeds the four temps; the 0x36 decode is unused | **HEAD code wins.** `setDashBoardCallback` is a separate, undecoded probe. |
| MCU cmd 0x0B | McuFrameDecoder.kt:87: "never yet observed" | Vendor console sniffer, 2026-07-29: `A5 2E 0B 02 06 C0 2C` (valid CRC) | **Both true in scope:** our app never logged one; the MCU does send 0x0B. Read as speed it gives 108 on a probably parked truck, so the meaning is doubtful. Open (5.12). |
| Factory video deserializer | CameraUtils.java comment: PR2000 | Live sysfs `/sys/lt8918/lt8918_signal = 1`; "YIMI_8918" in APPVer | **LT8918** (observed). The PR2000 comment was copied verbatim from vendor code and may describe another variant. |
| EventCenter.apk origin | One researcher: GT7A likely but not proven | aapt: versionName `1.0_20260303-17:50:37`, which matches the eventcenter version recorded live on the GT7A | **GT7A, high confidence.** A hash check would make it certain (2.3). |
| FORCE_STOP_PACKAGES | Audit: inherited from the shared uid only | aapt: EventCenter's own manifest requests it | **aapt (file) wins.** |
| GMLAN header rule | CARPLAY_APP_HANDOFF.md:93: "DBC id \| 0x10000000 \| 0x40" | Arithmetic on every id: `(prio<<26) \| (msg<<13) \| src` | **Arithmetic wins.** |
| Global A or Global B | One researcher's background note: 2019+ Silverado "generally described as Global B" | General knowledge: the 2019-2021 trucks and the 2022 "LTD" carryover are Global A; the refreshed 2022 moved to Global B | **Neither is from our files.** Our recorded evidence (Global A low-speed layouts decode and validate on this truck) is what counts; platform stays open (5.8). |
| GPS in the app | iCloud HANDOFF.md (2026-07-27): nothing wired | HEAD: LocationManager heading and GPS speed | **HEAD is newer and wins.** |
| Dongle model | Docs: Carlinkit CPC200-CCPA | BOX_SETTINGS: productType `A15W`, boxType `YA` | **Both recorded; open** (7.3). Probably seller name vs firmware name. [INFERRED] |
| Is the cluster installed | own-cluster-ui.md:23: "when the cluster arrives" | corlink-status-2026-10-10.md:59 and theme work imply it is in the truck | **Open** (7.7). |

---

## 2. Identifying the unit

### Verdict

**Family: ZXW (Shenzhen Choiceway) GT series, i.e. the "ZXW-GT6" family, in its newer GT7A Pro generation
(Qualcomm "685", Android 14).** It is not MTCH, Z35/ZongHeng, Joying or Topway.
**Confidence: high** that it is the ZXW/Choiceway family; **medium** on how far GT6-specific details carry over to
this GT7A generation (three checked binder codes match, but some numbering, such as "car type 84", may differ).
[INFERRED] from the evidence below.

### Evidence for

- The early-boot config partition literally says `VendorName=ZXW` (`[zxw_Config]` block). [FROM FILES we hold]
  `~/mycarplay-refs/device-backups/2026-09-26/privdata2_zxw_config.bin` (first 64 KiB).
- adb reports `product:GT7APro-CAR model:GT7APro_CAR device:GT7APro-CAR` (serial [redacted]); the Software Version
  screen says Device name `GT7APro-CAR`, Model `QCOM 685-GT7APro`. [OBSERVED on device] ce112634:163; audit:58.
- 33 vendor packages in the `szchoiceway` / `choiceway` / `sykj` / `sylink` / `ucloudlink` namespaces (eventcenter,
  canbus, NaviSettings, zxwlink, zxwcarplayer, zxwmedia, zxw_dashboard, zxw3d, auxcamera, navigation, btsuite,
  apkinstall, customerui, `com.sylink.service`, `com.sykj.fusionlink`, `com.ucloudlink.*` …), plus
  `com.lfg.szchoiceway.canupgrade` and `com.ms.ms2160`; 201 packages in all (193 system + 8 third-party).
  [OBSERVED on device] ce112634:254 §5 ("33 packages: szchoiceway/choiceway/sykj/sylink/ucloudlink"); audit:27-29.
- ZXW names throughout the system: `ZXW_CAN_*` actions, kernel node `/devices/virtual/misc/zxw_io`, sysprop
  `sys.zxw.support.xs9922b.common.camera`, boot logo `/vendor/etc/zxw_logo.bmp` (the "GT7" logo). [FROM FILES we hold]
  HEAD obd/McuProbe.kt:56-62; carplay/StereoFeedController.kt:67; CarplayAudioPlayer.kt:67; device-backups README.txt:4-8.
- The vendor code itself branches on model names "GT6" and "GT6-CAR"; the console has keys `Sys_Is_GT6FE_Model_Key`,
  GT6K, GT6A and strings GT6SE, GT6I, GT6E. [FROM FILES we hold] ec.txt:758038 (`SysBaseBandModel.getModelName`,
  the "GT6" / "GT6-CAR" comparisons); console.txt.
- The truck's previous unit was a GT6 ("GT6-EAU / Choiceway (SD665)"), and binder transaction codes 4 / 48 / 143 are
  the same in the GT6 port kit and the GT7A EventCenter. [FROM FILES we hold] HEAD CARPLAY_APP_HANDOFF.md:7,112;
  ec.txt:1115960-1116113.

### Evidence against, and caveats

- Different generation from a GT6: Snapdragon 685-class and Android 14 here vs SD665 and Android 13 on the GT6.
  [OBSERVED on device] audit:58 vs [FROM FILES we hold] CARPLAY_APP_HANDOFF.md:7.
- The vendor code is multi-platform: EventUtils carries UART paths for PX5 (`/dev/ttyS3`), RK3188 and SoFIA
  (`/dev/ttyS0`), so code presence alone proves little. The live path is the Qualcomm-style `/dev/ttyHS1`.
  [FROM FILES we hold] ec.txt:660630-660653, 638160-638183.
- One image serves many car brands: a Land Rover background app, Nissan GT-R widget assets, ~24 disabled OEM widget
  SKUs, and a `ksw_logo.bmp` (another brand) next to `zxw_logo.bmp`. [OBSERVED on device] audit:27; ce112634:254 §3;
  [FROM FILES we hold] device-backups README.txt.
- `ro.build.fingerprint` is a spoofed Pixel 3 XL ("crosshatch") fingerprint, so it cannot identify the vendor:
  `google/crosshatch/crosshatch:14/UKQ1.231108.001/20260318.154007:user/release-keys`. [OBSERVED on device] ce112634:163.
- `/vendor/bin/fibo_auto_frvc` (first-boot logo and fast rear camera) hints at a Fibocom smart module under the ZXW
  board; the vendor's kill-sweep allowlist also exempts `com.fibocom.multicamera` (recorded from the disassembly in
  HEAD state/SessionLog.kt:52-54). [INFERRED, low-medium] from those names, audit:17.
- In APPVer `…-GT7A-YIMI_8918-/-16-349-2-11`, "16-349" matches car type 16 / logo type 349, "8918" likely refers to the
  LT8918 LVDS receiver, "YIMI" is probably an ODM or customer code, and "2-11" is unknown. [INFERRED, medium] from the
  string vs incident-2026-07-27-raw.log:4 and StereoFeedController.kt:36.

### Why not the other families

None of the other families' package namespaces appear among the 201 packages, and the SoC is Qualcomm rather than
the Rockchip or MediaTek parts those families commonly use. [OBSERVED on device] package inventory, ce112634:254;
the other families' namespaces and SoCs are general knowledge, so the exclusion is [INFERRED].

### Identity card (GT7A Pro-CAR)

| Item | Value | Provenance |
|---|---|---|
| adb product / model / device | `GT7APro-CAR` / `GT7APro_CAR` / `GT7APro-CAR` | [OBSERVED on device] ce112634:163 (2026-07-29) |
| Serial | [redacted] | — |
| Android | 14 / SDK 34, OS built 2026-03-18 | [OBSERVED on device] audit:58; HEAD CLAUDE.md:21 |
| Fingerprint | spoofed Pixel 3 XL (see above) | [OBSERVED on device] ce112634:163 |
| Model string | `QCOM 685-GT7APro` | [OBSERVED on device] audit:58 |
| SoC | Snapdragon 685 class (SM6225 family). Read from the model string only; `ro.board.platform` was never captured | [INFERRED, medium] |
| FrameworkVer | `QCOM 685-GT7APro-GL-user-20260318.154007` | [OBSERVED on device] audit:58 |
| MCUVer | `RL9Ac_KWYa13___S077` | [OBSERVED on device] audit:58 |
| CAN (decoder firmware) | `A3bA_s_A_251118` | [OBSERVED on device] audit:58 |
| APPVer | `20260318-1440x1920-GT7A-YIMI_8918-/-16-349-2-11` | [OBSERVED on device] audit:58 |
| Panel-ChipVer | `LT9211D_U2--MAD200JB1-3--FRAME RATE:60` | [OBSERVED on device] audit:58 |
| Panel config | `[zxw_Config]`: PanelName MAD200JB1-3, PanelInfo LT9211D_U2, 1440x1920, isLandScreen 0, Rotation 0, TouchType 12, TouchCalibrate 6, ScreenName KW, ScreenChip 5000, BackCarType 0, CameraConfig 0 | [FROM FILES we hold] privdata2_zxw_config.bin |
| RAM / CPU | 7,875,564 kB (~8 GB class), 4 GB swap, 8 cores; eventcenter was the top process at ~120 % CPU | [OBSERVED on device] ce112634:1054 (2026-09-26 `top`) |
| eventcenter version | `1.0_20260303-17:50:37` live (`dumpsys package`, 2026-07-29), identical to the held APK's versionName | [OBSERVED on device] ce112634:210; [FROM FILES we hold] aapt |
| Security | SELinux Permissive, vbmeta unlocked, root adbd, dm-verity enforcing on /system and /product | [OBSERVED on device] audit |

### Still open in section 2 (checks not run; owner's OK needed)

| # | Open item | Check (details in `device-facts/open-questions-and-checks.md`) |
|---|---|---|
| 2.1 | Confirm the GT7A is in the truck today, and where the GT6 is | Owner says so; optionally `adb devices -l` |
| 2.2 | Confirm the SoC | `adb shell getprop ro.board.platform`, `ro.soc.manufacturer`, `ro.soc.model`; `/proc/cpuinfo` Hardware line |
| 2.3 | Prove the held APK and console dump came from this unit | `adb shell sha256sum /product/app/EventCenter/EventCenter.apk` (expect `49d00361…5692`); on-unit `dexdump -d` of ATSLCarConsole piped to `sha256sum` (expect `55c74d96…5485`) |
| 2.4 | Fibocom module? (low priority) | `adb shell "getprop \| grep -i fibo"` |

---

## 3. Head-unit files we hold

Hashes computed on this Mac on 2026-10-11 (`shasum -a 256`); the backup folder's own `SHA256SUMS` re-verified the
same day. Full inventory, APK contents and line landmarks: `device-facts/files-inventory.md`.
All rows [FROM FILES we hold].

| Path | Size (bytes) | SHA-256 | What it is |
|---|---|---|---|
| `~/mycarplay-refs/EventCenter.apk` | 29,809,259 | `49d0036195ba3faadc8a9692a74c4d00073799d61fc0538be7ca96cd965a5692` | Vendor broker `com.szchoiceway.eventcenter` from `/product/app/EventCenter`. versionName `1.0_20260303-17:50:37`, versionCode 1, minSdk 28 / targetSdk 33, sharedUserId `android.uid.system`. 1,107 entries: `classes.dex`, `libserial_port.so` (all ABIs), three arm64 `libcamera_utils*.so` variants, assets `Track07.mp3`, `letterIcon.png` |
| `~/mycarplay-refs/ec.txt` | 91,317,713 | `0cd8138bce1708be595e490be417dd96f24804be80ef5d3e6fd21bff978494c8` | On-unit `dexdump -d` of that APK (1,299,968 lines): serial port, car-type constants, binder codes |
| `~/mycarplay-refs/console.txt` | 92,534,008 | `55c74d96fc6e5273b74cb647b3f03662d6ca16035ceebf9e0d962a6e7ea55485` | On-unit `dexdump -d` of `/product/app/ATSLCarConsole/ATSLCarConsole.apk` (vendor CAN console; the APK itself is not held) |
| `~/mycarplay-refs/device-backups/2026-09-26/privdata2_zxw_config.bin` | 33,554,432 | `5753d9f91f01977b3e826f0206a83f0951886a4cfded664d039838a453ef63ad` | Raw privdata2 (sda13): `[zxw_Config]` panel/touch block, rest zeros |
| `…/2026-09-26/privdata3.bin` | 67,108,864 | `6fc0c291b7687bbcead7c99b60d2ee7158fbb6f9bfa105c41c41448888b8b09a` | Raw privdata3 (sda14): config copy, `[timing_Config]`, empty ext4 |
| `…/2026-09-26/bootanimation_trailboss_privdata1.zip` | 34,465,580 | `d92761f3d25cc91d18603937d98a9cd6522e7589b34a2d0ad6a419ddd404dd1b` | The owner's Trail Boss boot animation (`1440 1920 15`) |
| `…/2026-09-26/zxw_logo.bmp` | 120,054 | `1eb1b5418ece36bf4954585d6a10815d5888e2f3d61d8bdc9a5a637e13bf4983` | `/vendor/etc` "GT7" first-boot logo, 200x200 |
| `…/2026-09-26/ksw_logo.bmp` | 404,454 | `10e560c2567c993c570edf07a16bd2a39051014cd3265c9666038fd4f524f38e` | `/vendor/etc` KSW-brand logo, 898x150 |
| iCloud truck folder `incident-2026-07-27-raw.log` | 61,746 | `3b11f3a1c85e449bc6662bed81b63a07d7519c7233b1385275cd95b420adaac4` | 342-line logcat around the ACC-standby kill; line 4 car type 16 / logo type 349; line 231 DashboardInfo dump |
| ce112634 `tool-results/b8hv78jy3.txt` | 36,392 | `4ce1a4c4dc42679c296b1a39634175e0f7a67052b626b106f13c18b7f2b9fed2` | 60-line logcat, 2026-09-26: `BaseCanNew sendDashboard` every 1-3 s |
| myCarplay HEAD `jniLibs/arm64-v8a/libcamera_utils.so` | 10,256 | `6a802fa5c0976a9c739de56187d6859512a4ebf0886b13ad3bf43b1be844b5f2` | Vendor AIS-camera JNI shim from the console (commit 5451e0f); reference only |

**Firmware packages:** none for the head unit are on this Mac (no `update*.zip`, `.img`, `dmcu*` or MCU `.bin`). Its
version and MCU strings exist only as the Software Version screen text in section 2. The only firmware package held,
`~/Documents/head unit/ACX_Dash.zip`, is for the instrument cluster, a different unit. [FROM FILES we hold]

**Not on this Mac:** `Canbus.apk` (`com.szchoiceway.canbus`), the ATSLCarConsole APK binary, the Software Version
screenshot, and the GT6-era memory notes and raw captures that code comments cite (CorPlayDroid memory, probably on
the Mac Studio). **Not head-unit files:** `~/mycarplay-refs/xlc.txt` is a dexdump of our own app; the rollback APKs
and `mycarplay.apk` are our builds. [FROM FILES we hold]

---

## 4. How myCarplay gets truck data, and what is wrong

### 4.1 The paths in brief

myCarplay uses **broadcast intents and a bound AIDL service from the vendor broker**, plus Bluetooth to the MX+ and
Wi-Fi to the cluster. It uses **no content provider and no tty**; EventService owns the MCU UART. All rows
[FROM FILES we hold] at HEAD. Full table with every action, extra and line: `device-facts/data-paths.md`.

| Path | Name | Code (HEAD) |
|---|---|---|
| Broadcast | `com.szchoiceway.eventcenter.EventUtils.MCU_CAR_CAN_INFO`, extra `EventUtils.CAR_CAN_DATA` = [km/h, rpmHi, rpmLo] | obd/ChoicewayCanSource.kt:70-86,144-150 |
| Broadcast | `com.choiceway.eventcenter.EventUtils.MCU_MSG_CAN_ALL_INFO` (no "sz"), extra `EventUtils.CAR_AIR_DATA`: `a5 2e cmd len payload crc` frames | obd/Gt7EventBusSource.kt:261-276; obd/McuFrameDecoder.kt; hvac/HvacManager.kt:65-90 |
| Broadcast | `Action_DashboardInfo`, Parcelable `Extra_DashboardInfo` (`com.szchoiceway.canbus2.bean.DashboardInfo`, from `com.szchoiceway.canbus`) | obd/Gt7EventBusSource.kt:279-323 |
| Broadcast | `com.choiceway.eventcenter.EventUtils.MCU_MSG_BACKCAR_START/_END`, `…MCU_MSG_BRAKE_EVT`; `com.szchoiceway.eventcenter.EventUtils.ACTION_ACC_SLEEP_STATUS_EVT` (`ACC_Status`), `…MCU_KEY_INFOR` (`EventUtils.MCU_KEY_VALUE`) | obd/Gt7EventBusSource.kt:237-253,365-371 |
| Broadcast | `com.choiceway.eventcenter.CanUtils.CAN_CAR_OUT_SIDE_TEMP_EVT` (`…_EXTRA_STR`) | hvac/HvacManager.kt:92-104; cluster/OutsideTempBroadcastClock.kt:60-114 |
| Bound AIDL | `com.szchoiceway.eventcenter/.EventService`, `IEventService`: setDashBoardCallback 143, setCanA5DataCallback 132, setCanA6DataCallback 131, IsBrakeConneted 119, IsBackCarConneted 88, getMCUVer 32, getCanVer 105, openCamera 145 | obd/Gt7EventBusSource.kt:162-234; StereoFeedController.kt:93-102,147-168 |
| Raw binder (write) | transaction 48 `sendCanbusData`: `0D 08 2E E0 02 key state crc` (HVAC) | hvac/HvacController.kt:58-64,80-130 |
| Broadcast (write) | `com.szchoiceway.eventcenter.EventUtils.ACTION_MCU_CMD_EVENT`, extra `EventUtils.MCU_CMD_DATA`: LVDS `49 14 01`, touch `0D 08 2E E3 …`, audio `3F 00 01` | carplay/StereoFeedController.kt:120-145; carplay/CarplayAudioPlayer.kt:353-360 |
| Bluetooth SPP | OBDLink MX+ (STN2255): HS-CAN PIDs + GM single-wire CAN (STP 61) | obd/ObdTransport.kt; obd/BluetoothObdSource.kt |
| Wi-Fi | Cluster `signals` over SSE (corlinkd :8770, mDNS `_corcluster._tcp`) | cluster/ClusterLink.kt:52-66,277-305 |

Two package spellings are on the wire (`com.szchoiceway.eventcenter.*` and `com.choiceway.eventcenter.*`);
receivers must be `RECEIVER_EXPORTED`; the manifest holds `com.szchoiceway.permission.broadcast`. [FROM FILES we hold]
HEAD AndroidManifest.xml:16-17,39-49; CARPLAY_APP_HANDOFF.md:111,113.

Source priority per signal (SourceChain): OBD-only names → verified vendor bus → OBD MIL → body bus (BODY_FIRST
names) → HU MCU (steering) → HU CAN (speed/rpm, 3 s) → vendor dashboard (5 s) → cluster (link up, 3 s) → fresher of
OBD PID and body bus → weather. Unverified readings rank last and never light lamps. [FROM FILES we hold]
corlink-client SourceChain.kt:91-203.

### 4.2 The core table

"Works reliably?" uses: **YES** with where it was seen; **NO** = the source never delivers it on this truck;
**UNVERIFIED** = a verification flag in code is false; **unknown** = needs a capture. Body bus = GM single-wire CAN
through the MX+ (header ids in `device-facts/gm-body-bus.md`).

| Signal | Source API (priority order at HEAD) | Works reliably? | Symptom when wrong | Notes |
|---|---|---|---|---|
| Vehicle speed | (1) `MCU_CAR_CAN_INFO` byte0 km/h, 3 s; (2) cluster `speed_mph`; (3) OBD 010D, 5 s | **YES** [OBSERVED on device] 2026-06-30 (ChoicewayCanSource.kt:22); live 2026-07-26 (touch test refused at 70 mph, iCloud HANDOFF.md) | Before commit 2b72697 the last frame latched: a parked truck showed "SPEED 45 / 1,850 RPM" [OBSERVED on device]. Now blanks after 3 s | Whole km/h, so ~0.6 mph steps [INFERRED]. Vendor dashboard speed is `--`. MCU 0x0B unused (open 5.12) |
| RPM | (1) `MCU_CAR_CAN_INFO` bytes1-2 BE; (2) cluster; (3) OBD 010C | **YES** [OBSERVED on device] idle ~720 (2026-06-30), 797 (2026-07-25, b3ce20b) | Same latch bug, fixed | MCU 0x14 decoded, unused |
| Coolant | (1) `Action_DashboardInfo.waterTemp` ("212 °F"), 5 s; (2) cluster; (3) OBD 0105 | **YES** [OBSERVED on device] 208-210 °F warm (2026-07-25 commits 0632a89, b3ce20b); 210-212 °F (2026-09-26 GT7A log b8hv78jy3.txt); 111-113 °F cold (2026-07-27 GT7A log, incident raw log) | Values are display strings: if the unit's Units setting went metric, °C would be read as °F [INFERRED] Gt7EventBusSource.kt:290-294. A Parcel layout mismatch gives a silent null (vendor carddesk fails "consumed 544, expected 640") [OBSERVED on device] | Body 0x170 coolant matched OBD at 210 °F |
| Engine oil temp | DashboardInfo `oilTemp` → cluster → body 0x170 | **YES** [OBSERVED on device] 186-199 °F | as coolant | Own MCU 0x36 decode exists, unused, possible offset bug (5.11) |
| Trans temp | DashboardInfo `transTemp` → cluster → body 0x170 | **YES** [OBSERVED on device] 123-141 °F | as coolant | — |
| Oil pressure | DashboardInfo `oilPressure` ("34.8 PSI") → cluster → body 0x170 ×4 kPa | **YES** [OBSERVED on device] 25.6-28.0 psi (2026-07-25 commits); 34.0-36.4 psi (2026-09-26 log) | as coolant | MCU 0x36 sentinel 0xFFFF = none |
| Gear (PRNDL) | (1) verified vendor reverse could add R (flag false); (2) cluster `gear`; (3) body `102CC040` byte2 CF/CE/CD/C1; reverse lamp forces R | Head unit: **NO** [OBSERVED on device] `gearInfo` 0 even in Park (0632a89). Body: **YES** [OBSERVED on device] "verified stable across repeated controlled captures" (SwCanBody.kt:211) | P shown 150-900 ms after P→R (fixed 90859eb); freezes ~1.5-2.5 s during each HS-CAN excursion (BluetoothObdSource.kt:734-739); old scheduler lagged ~8 s (8a4f5c8) | D, L, M all read C1. No gear without the MX+ unless the cluster sends it (XCI gear enum unverified) |
| Reverse | (1) body gear R or reverse lamp `1020C040` b2 bit1; (2) cluster gear "R"; (3) vendor `IsBackCarConneted()` + `MCU_MSG_BACKCAR_START/_END` | Vendor: **UNVERIFIED** (VendorBus.kt:123). Body: **YES** with the gear decode | The vendor value is the reverse-camera trigger, not the gear; a missed broadcast or stale bind-time value holds the wrong state (VendorBus.kt:103-104) | Unverified vendor reverse never changes the gear |
| Parking brake | (1) body `1022A040` byte2 & 0xA0; (2) cluster; (3) vendor `IsBrakeConneted()` / `MCU_MSG_BRAKE_EVT` | Body: **partial** [OBSERVED on device] 00→A0→00 transient on a toggle 2026-07-19; steady state unconfirmed (a28c26d). Vendor: **UNVERIFIED** | Old byte4 bit6 decode lit a phantom red brake lamp [OBSERVED on device]. The vendor reads the brake-detect (video-lockout) wire, which installers often ground: it can read SET forever (VendorBus.kt:99-104) | DashboardInfo.handbrake always false in captured dumps |
| Doors: driver, passenger | (1) MCU cmd 0x24 bits 0x40 / 0x80 (while the MCU stream is live, 5 s); (2) body `10630040` / `102F6040`; (3) cluster | MCU: **YES** [OBSERVED on device] ground-truthed 2026-07-25 (McuFrameDecoder.kt:96-105). Body: unknown | Edge-triggered: blank after app start until a door changes. Vendor `ACCORD_DOOR_INFO` never arrives. Before 91e5ac3 a stale MCU door state outranked fresh sources | Byte-offset question open (5.11) |
| Rear doors, hood, tailgate | body `102F8040` / `102FA040` / `10728040`; tailgate from cluster only | unknown (other 0x24 bits unlabelled) | — | Decoded, never shown |
| Turn signals | (1) cluster `turn_l`/`turn_r`; (2) body `1020C040` stalk b0[6:5] / lamp nibbles b3; also `10220040` b6 bit0 | Body: **YES** [OBSERVED on device] "validated on our blinker captures" (SwCanBody.kt:224,310) | Aggregate `turnFlashing` misses the off-phase; may linger up to ~5 s through an HS excursion [INFERRED] | DashboardInfo turn booleans always false |
| Hazards, high beam, brake lamp | body lighting b0 bit2 / b1 bit5 / b1 bit7; high beam also from cluster | unknown (only the turn fields are tied to captures) | — | Hazards and brake lamp not in the chain |
| Fuel level | (1) cluster `fuel_frac`; (2) fresher of body `0C800040` b1 ×0.392157 and OBD 012F (150 s) | Head unit: **NO** [OBSERVED on device] innage `--`, `CAN_CAR_FUEL_INFO` never fires (5ee8d96). Body: unknown | Blank with no MX+ and no cluster | The truck may send header `10800040` instead; then the body decode never fires [INFERRED] |
| Range (DTE) | cluster → body `10448040` ×0.015625 km | Head unit **NO**; body unknown | — | — |
| Odometer | cluster → body `106C0040` BE ×0.015625 km | Body: **YES** [OBSERVED on device] "validated exact vs the truck dash" (SwCanBody.kt:92-93). Head unit **NO** | Read 1 mile low (fixed) | Persisted as last-known |
| Oil life | cluster → body `102D0040` b4 ×100/255 | Body: **YES** [OBSERVED on device] dash-validated. Head unit **NO** | — | — |
| Battery voltage | cluster `battery_v` → OBD 0142 | Head unit **NO** (`--`); others unknown | — | SW-CAN 0x124 volts not offered to the chain |
| 12 V state of charge | body `10248040` (30 s) → AGM rest-voltage estimate | unknown | Before 91e5ac3 a restored SOC looked live and could fire a CRITICAL alert; latched rpm disarmed Battery Guard (fixed 2b72697) | Battery Guard only, not the chain |
| TPMS (4) | cluster `psi_*` → body `103D4040` b2-5 ×0.5802 | Head unit **NO**; body unknown | Sensors sleep when parked, so blank (by design). XCI 0xFFF forwarded raw would read 594 psi | — |
| Outside temp | (0) `CAN_CAR_OUT_SIDE_TEMP_EVT` (10 min); cluster; OBD 0146 (75 s); Open-Meteo (1 h) | **NO** [OBSERVED on device] never broadcast in the sweep; dashboard `--`; AppGraph.kt:124-126 "doesn't reliably carry it" | Header blank offline (983146f); "58° °" (fixed 91e5ac3) | See 1.7 |
| Steering angle | (1) body `10240040` ×0.0625; (2) MCU 0x26 LE int16 / 195 | MCU: frames **YES** [OBSERVED on device] 121 per lock-to-lock sweep; scale unchecked. Body: unknown | Silent while the wheel is still (a parked capture once "proved" it absent); freezes in HS excursions | Max ±168 "deg" vs a ~±540° wheel: may be a guide-line unit [INFERRED] (5.13) |
| Drivetrain / 4WD | body `10264040` b6 high nibble (2H/4H/4L) + `10780040` enum (Auto wins) → cluster | Body: 2H/4H/4L **YES** [OBSERVED on device] 2026-07-05 live work; enum/Auto unknown. Head unit **NO** | — | The cluster's XCI box has no 4WD path |
| Drive mode | cluster `drive_mode` | unknown | — | — |
| Ignition / ACC | `ign_run`: body `10242040`; `acc`: body → cluster ACC → vendor `ACTION_ACC_SLEEP_STATUS_EVT` | Vendor **UNVERIFIED** (may skip the wake broadcast, VendorBus.kt:105-106); body unknown | Battery Guard ignores unverified ACC | — |
| HVAC state | `MCU_MSG_CAN_ALL_INFO` cmd 0x03 + 0x13, decoded like `refreshBuickAirInfor` | **YES** [OBSERVED on device] owner-confirmed, live-captured bits; owner-locked (HvacManager.kt:20) | The generic `refreshCarAirInfor` table gives wrong vents and inverted SYNC; in AUTO the fan byte is the stale manual request (68e092d) | Rear-defrost bit pending |
| HVAC control (write) | binder transaction 48 `0D 08 2E E0 02 key state crc`; down, 45 ms, up | **YES** [FROM FILES we hold] owner-confirmed (CLAUDE.md:49-53; memory hvac-ios27-restyle.md) | A trailing key 16 toggled SYNC (fe7d9b3); a 0 ms down/up can be dropped by the MCU's debounce, so each press holds ~45 ms (HvacController.kt:83-89) | Writes to the vehicle bus. Keys 20 (rear defrost) and 33 (airflow) untested |
| Trailer | body `10264040` bit14 → cluster `trailer_brake` | unknown; cluster **UNVERIFIED** (ClusterVerification.kt:29-34) | The cluster may send 0 with no trailer, which would read "connected" | — |
| Pitch / roll | pitch: body `0C800040`; roll: body `10780040` → cluster accelerometer | Roll "verified" [FROM FILES we hold] SwCanSignals.kt:26; pitch unknown (header question) | Cluster value depends on mounting | — |
| Check engine / DTC / VIN | OBD 0101 across ECUs (1 min) → cluster | unknown: "pending truck verification" (BluetoothObdSource.kt:603-604) | — | OBD only |
| Steering-wheel keys | `MCU_KEY_INFOR` / `EventUtils.MCU_KEY_VALUE` → `swcKey` | unknown; **no consumer** | — | Codes unrecorded (5.14) |
| Seatbelt, lockers, DFM, cruise, wheel speeds, pedals, yaw | body readable map only | unknown; cruise "verify live" (SwCanSignals.kt:58) | — | — |
| Factory radio video | `ACTION_MCU_CMD_EVENT` `49 14 01`, then `openCamera(surface,0,0,6)` | **YES** [OBSERVED on device] owner-confirmed 2026-07-26 | Black surface with channel 1 or without the LVDS request; `sendMode()` pauses music | screencap shows it black |
| Factory radio touch | `ACTION_MCU_CMD_EVENT` `0D 08 2E E3 05 p xLo xHi yLo yHi chk` | **YES** [OBSERVED on device] 778/778 | The generic FF 55 sender is silently ignored | — |
| CarPlay amplifier wake | `ACTION_MCU_CMD_EVENT` `3F 00 01` + `0A 00`, 2 s heartbeat | **YES** [OBSERVED on device] build 109 | Silent speakers; never claim a source (cuts FM) | — |
| Heading / GPS speed | Android LocationManager | GNSS fix: **YES** [OBSERVED on device] ~20 satellites, ~10 m (iCloud HANDOFF.md:143-144, 2026-07-27, recorded before the app requested location); a fix also shows in the 2026-09-26 `dumpsys location` read (ce112634:1054). The app's own heading path on the truck: not separately recorded [INFERRED works] | Heading invalid below ~1 mph (holds last) | Never used as vehicle speed |
| Engine detail (throttle, load, abs load, MAF, timing, STFT/LTFT, intake, catalyst temp, baro, runtime) | OBD PIDs only (SourceChain `OBD_ONLY`, SourceChain.kt:145-148; DataCatalog) | Partly: the OBD coolant PID matched body 0x170 at 210 °F [OBSERVED on device] (SwCanSignals.kt:7-8); the others are not individually recorded [unknown] (DTC/VIN: see the Check engine row) | Blank without the MX+; the cluster's CAN box cannot supply them (memory corlink-rev2.md:30-35) | PIDs refresh only ~every 30 s while the body bus streams |
| MCU / CAN version | `getMCUVer()` / `getCanVer()` on bind | logged only | — | — |

### 4.3 What is wrong

1. **The head unit's decoder never sends gear, fuel, range, odometer, oil life, battery, TPMS, drivetrain or outside
   temp** on this profile. That is an upstream limit (decoder box or its car profile), not our parsing. Without the
   MX+ or the cluster these stay blank. [OBSERVED on device] commit 5ee8d96. Whether another decoder profile would
   pass them is unknown, and testing it means changing factory configuration, which is out of scope.
2. **Vendor-bus park brake, reverse and ACC are unverified**, and each has a known trap: park brake is the
   video-lockout wire (often grounded), reverse is the camera trigger, ACC can skip its wake broadcast.
   [FROM FILES we hold] obd/VendorBus.kt:91-128.
3. **Decodes that exist but are not used:** MCU 0x36 (oil/trans/coolant/pressure), 0x14 rpm, 0x0B speed, the
   steering-wheel key value, and most DashboardInfo fields. The 0x36 decode may also be off by one byte.
   [FROM FILES we hold] Gt7EventBusSource.kt:261-276 vs McuFrameDecoder.kt:107-124.
4. **Possible header mismatch for fuel % and pitch** (`0C800040` read vs `10800040` declared). [INFERRED]
   SwCanSignals.kt:125-126 vs SwCanBody.kt:110,223.
5. **Possible door byte offset** in cmd 0x24. [INFERRED] McuFrameDecoder.kt:66-72 vs :96-105.
6. **Outside temp is registered from a broadcast that never fires.** [OBSERVED on device] 5ee8d96 vs HvacManager.kt:92-104.
7. **Event-driven MCU signals look absent when nothing moves** (steering, doors), and body values freeze during each
   HS-CAN excursion. [OBSERVED on device] commit 28aa1dc; BluetoothObdSource.kt:734-739.
8. **Stale comments and labels:** "car type 84"; GMLAN labels for steering and SOC; README "Known gaps"; the
   CardSlotsStore comment. List: `device-facts/history-and-stale-docs.md`.

### 4.4 What can be done now, without the head unit

- Correct the stale docs and comments above (README/CLAUDE.md unit status, "car type 84", labels).
- Make the fuel/pitch decode accept both headers until a capture decides.
- Stop counting `CAN_CAR_OUT_SIDE_TEMP_EVT` as a live source, or label it unverified.
- Add log lines for the steering-wheel key value and raw 0x24 / 0x36 / 0x0B frames, so the next parked session can
  settle 5.11-5.14 passively.
- Keep testing against `~/cor-sim` (its frame periods and truck numbers are assumptions, see `device-facts/gm-body-bus.md` §5).

These are suggestions for the owner to approve. myCarplay is mid-edit by another agent; nothing was changed.

---

## 5. Decoder and factory configuration

### 5.1 Configuration at a glance

| Setting | Value | Provenance |
|---|---|---|
| CAN car type (`getCanCarType()`) | **16** | [OBSERVED on device] incident-2026-07-27-raw.log:4 (2026-07-27 18:59:45, eventcenter) |
| Logo / vehicle type (`getLogoType()`) | **349** = `CARTYPE_SILVERADO_NEW_22` | [OBSERVED on device] same line; [FROM FILES we hold] ec.txt:655875-655878 |
| Name for 16 | `CARTYPE_BUCIK_HI` (vendor spelling of Buick), the only EventCenter CARTYPE with that value; the console's own tables reuse 16 for Ford Fiesta (see 5.2) | [FROM FILES we hold] ec.txt:654125-654128; console.txt:753665 |
| HVAC decode path | `refreshBuickAirInfor`, "logoType 349 / mCarType 16-177" (177 = `CARTYPE_WEILANG_HI`, Buick Verano, in EventCenter; the console's copy also has `CARTYPE_GM_ASTRA = 177`, console.txt:753850; both GM); why 177 appears is undocumented | [FROM FILES we hold] HEAD hvac/HvacManager.kt:18-20; HvacController.kt:112-113; ec.txt:656195-656198 |
| "Car type 84 / GMOld" | In comments and commit 5ee8d96; not the EventCenter value (see 1.7) | [FROM FILES we hold] HvacState.kt:5; ChoicewayCanSource.kt:15-16 |
| APPVer suffix | `-16-349-2-11` (matches 16 / 349) | [OBSERVED on device] audit:58; meaning [INFERRED] |
| Customer type | `mCustomerType` = 4; SysVarProvider `Sys_CustomerType` = 4, `Sys_UINumber` = [redacted] (a UI style id; value withheld as a precaution), `Sys_Home_Page_Display` = 1 | [OBSERVED on device] StereoFeedController.kt:63-68; audit:13 |
| canbus app | Only `com.szchoiceway.canbus`; `isCanbus2App()` false, so every console "Simple GM" predicate is false (incl. `isChSimpleGm19Silverado8Inch`) | [FROM FILES we hold] console.txt:1000260; commit 2fa550e |
| Console source mode | 30 = `SRC_ATSL_AIRCONSOLE`; panel `isHorizontal = false` | [FROM FILES we hold] StereoFeedController.kt:245-250 (derived from the console's decompiled branch, not read off the unit); mode 30 is what the factory-video path uses, and that path was owner-confirmed working on 2026-07-26 [OBSERVED on device] commits 2fa550e, dd1843b |
| HU → MCU serial link | `/dev/ttyHS1` at **115200** (`EventService.openSerialPort()`, `android.serialport.Device`) | [FROM FILES we hold] ec.txt:638160-638183 |
| CAN-box frame family | 0x2E head, checksum = (type + len + data) XOR 0xFF (0x2E excluded): E0 air key, E1 car key, E3 touch; also 2E 90 / E2 / 82 / E4 seen | [FROM FILES we hold] memory factory-touch-gm-variant.md:22-28; HvacController.kt |
| CAN decoder firmware | `A3bA_s_A_251118` | [OBSERVED on device] audit:58 |
| CAN decoder brand | unknown | — |
| Vehicle | 2022 Chevrolet Silverado (1500) Trail Boss, L84 5.3 L V8 with Dynamic Fuel Management (gas, so no diesel/AdBlue signals) | [FROM FILES we hold] HEAD CLAUDE.md:3; CARPLAY_APP_HANDOFF.md:7; obd/SwCanSignals.kt:136 |
| Climate | Dual-zone automatic: AUTO, SYNC/DUAL, separate temps, A/C, recirc, rear defrost. No heated or cooled seats, no ECO, no rear-seat temp, heated wheel unreadable | [OBSERVED on device] HvacManager.kt:22-28; Hvac.kt:27-37; owner chat 2026-10-11 (274afb41) |
| Factory screen | 800x480 touch space (x 15..702, y 17..457 over 778 frames); a code comment says "Stock GM 8-inch"; 7 vs 8 inch not confirmed | [OBSERVED on device] factory-touch memory; [FROM FILES we hold] StereoFeedController.kt:255-257 |
| Head-unit screen | 1440x1920 portrait, MAD200JB1-3 panel, LT9211D_U2 bridge, 60 Hz, TouchType 12 | [FROM FILES we hold] `[zxw_Config]`; [OBSERVED on device] audit:58 |
| Bose / amplifier | unknown; no record anywhere. Volume is relative only (±1 per key); the amplifier path is invisible to AudioManager; the vendor `CAR_AMPLIFIER_EVT` never fired | [FROM FILES we hold] CARPLAY_APP_HANDOFF.md:114; McuProbe.kt:101-102; commit 5ee8d96 |
| Cluster's own decoder | XCI box, `CANBOX_VENDOR_XCI (5)`, GM brand 0, UART2 `/dev/ttyS2` 115200 8N1 (from the vendor package, not the device) | [FROM FILES we hold] ~/acx-sim/firmware/ACX_Dash/etc/common/Global.qml:144-151,1186 |

### 5.2 What the car-type numbers mean

The live unit reports car type 16 and logo type 349 [OBSERVED on device]. In EventCenter's constants, 16 is
`CARTYPE_BUCIK_HI` and 349 is `CARTYPE_SILVERADO_NEW_22`, and no other EventCenter CARTYPE has either value
(2026-10-11 check: 501 CARTYPE constants in its EventUtils, only 4 duplicated values, none 16 or 349) [FROM FILES we hold]. The vendor
console's own tables do reuse them: 16 = `CARTYPE_FORD_FIESTA` (console.txt:753665) and 349 =
`CARTYPE_MITSUBISHI_OUTLANDER` (console.txt:755485), also in `Customer$CarType` [FROM FILES we hold]. So a name read
from another vendor app's table may differ, but EventCenter, which logged the values, maps them unambiguously. The GM
reading also holds on independent evidence: the working touch and HVAC paths are the vendor's "Buick" senders, and
EventService handles logo types 220 / 349 / 353 / 221 / 224 (Silverado, Silverado new 22, Colorado new, Colorado,
Tahoe) as one group (ec.txt 638338-638346) [FROM FILES we hold]. What the `_HI` / `_LO` suffix means is unknown
[see 1.7].

### 5.3 The serial link and where the decoder sits

`EventService.openSerialPort()` opens `/dev/ttyHS1` at 115200 through `SerialPortManager` / `libserial_port.so` and is
called from two places (ec.txt:599330, 621108) [FROM FILES we hold]. `ttyHS` is Qualcomm's high-speed UART naming,
which fits this platform; the EventUtils constants (`/dev/ttyS1`, PX5 `/dev/ttyS3`, RK3188/SoFIA `/dev/ttyS0`) are
leftovers [INFERRED]. The line goes to the head unit's MCU, and the CAN decoder sits behind the MCU: commands leave as
`0D 08 <box frame>` inside `0d 0a len … chk 00`, and decoded frames come back as `a5 2e cmd len payload crc`
[INFERRED] from the framing (factory-touch memory; HvacManager.kt:16; McuFrameDecoder.kt:14-20). Not yet checked with
an open-file listing on the unit (5.4 below).

### 5.4 Decoder brand

Unknown. The firmware string is `A3bA_s_A_251118` [OBSERVED on device]. The 0x2E header and XOR-0xFF checksum match
the widely used Raise (RZC) canbox framing, and cluster-app's `src/proto/framing.h:16-18` names the truck's HVAC frame
Raise-family [FROM FILES we hold]; the brand itself is [INFERRED, low]. EventCenter also has code for other boxes
(XBS Infiniti 360, `mIsXFYCanBox`, `ZHTYCanBoxEnable`, `CarBaojun730_RZC`, `SYS_UPGRADE_CANBOX_VERSION`), so code
presence does not identify the fitted box [FROM FILES we hold]. A CAN-gateway firmware updater
(`com.lfg.szchoiceway.canupgrade`) is installed: never launch it [OBSERVED on device] audit:29.

### 5.5 Trim and platform

- Trim is probably **LT Trail Boss** rather than Custom Trail Boss: dual-zone automatic climate and the L84 fit the
  LT, while the Custom Trail Boss normally has manual single-zone climate. [INFERRED, low] general GM trim knowledge
  plus HvacManager.kt:22-28.
- Platform is probably the **2019-2021 body carried into 2022 ("1500 LTD"), GM Global A**, not the refreshed 2022.
  Evidence: the single-wire CAN on OBD pin 1 decodes and validates with opendbc `gm_global_a_lowspeed` layouts, the
  factory radio screen is 800x480 and fed over LVDS. Against: the vendor names the profile `SILVERADO_NEW_22`, which
  could mean either. [INFERRED, low] SwCanBody.kt:7-12; SwCanSignals.kt:5-9; factory-touch memory; ec.txt:655875.

### 5.6 Vendor settings seen on screen (2026-07-29, viewed only)

Video In Motion ON; Original car camera = channel 1; Default Navi App = Maps; no auto-start app; Voice = Google; MIC
Gain 96; Homepage style "Classic style"; a "Save & reboot" action on every page. "Wheel settings" is an analog
resistor-ladder learning tool; steering-wheel keys reach this unit over CAN through EventService, so it is probably
unused [INFERRED]. The vendor Console (`com.android.atslcarconsole`) is a live raw frame sniffer showing lines such as
`0xA5 0x2E 0x0B 0x02 0x06 0xC0 0x2C 0x25…` and firmware readouts "8836" and "OS 6806" (video-chip mode labels, compare
the vendor key `Sys_6806_8836_Screen_Key` and `RequestCar8836LVDS()`; not access codes) [INFERRED for the meaning];
HOME does not close it, its own Quit button does. [OBSERVED on device] audit:35-58. Full list: `device-facts/vendor-constants.md`.

### 5.7 Still open in section 5 (checks not run; owner's OK needed)

| # | Open item | Check (details in `device-facts/open-questions-and-checks.md`) |
|---|---|---|
| 5.1 | The CAN profile in the menu's own words (protocol, brand, model, year) | Owner: in the vendor Settings app, open the factory settings menu, find the CAN / car-model page, read it, back out without saving |
| 5.2 | Still car type 16 / logo 349 today? | `adb shell "logcat -d \| grep -E 'getCanCarType\|getLogoType'"` |
| 5.3 | Decoder brand | Owner: head-unit kit order page or manual; or the label on the decoder box next time the dash is open |
| 5.4 | Which UART is live | `adb shell "ls -l /proc/\$(pidof com.szchoiceway.eventcenter)/fd \| grep -E 'tty\|serial'"` |
| 5.5 | `mAirSupplierID` value | `adb shell "logcat -d \| grep -i -E 'mAirSupplierID\|mCanType'"` |
| 5.6 | Origin of "84" and "16-177" | `adb shell pm path com.szchoiceway.canbus`, `adb pull` that APK to `~/mycarplay-refs/`, search its dexdump on the Mac |
| 5.7 | Trim | Owner: window sticker, registration, or the glovebox RPO label |
| 5.8 | LTD carryover or refreshed 2022 | Owner: window sticker / registration ("1500 LTD") |
| 5.9 | Factory radio 7 or 8 inch | Owner |
| 5.10 | Bose | Owner: Bose badges on the speaker grilles, or the window sticker / glovebox RPO label |
| 5.11-5.15 | Door byte, 0x36 offset, 0x0B meaning, steering scale, wheel-button codes, A5/A6 callbacks | Passive logcat reads while parked (or after a normal drive), listed in the checks file |
| — | Rear-defrost key 20 / airflow key 33 | **Not read-only** (bus writes): separate owner-approved live test only |

---

## 6. What the cluster-app project knows about the truck

### 6.1 cluster-app itself: almost nothing truck-specific

`~/cluster-app` (HEAD d35be2a) implements generic canbox framings only (Raise 0x2E, HiWorld 5A A5, RealDash 44/66)
with an illustrative Raise map; its UART decoder is a self-declared stub with guessed offsets, and its baud table
tries 38400 first while the vendor uses 115200. The dimmer/illumination id is unknown (plan: diff captures while
turning the knob). [FROM FILES we hold] src/proto/framing.h:1-24; src/proto/uart_feed.c:105-123; serial.c:9;
PHASE0-BENCH-RUNBOOK.md:3-14. The truck knowledge lives in myCarplay (body bus, MCU frames) and in `~/acx-sim` (the
cluster's XCI box).

### 6.2 GM body bus (single-wire CAN, OBD pin 1, through the MX+)

- **Protocol:** GM single-wire CAN at 33.3 kbit/s, read with STN `STP 61` after `ATH1 ATS1 ATCAF0`, `STCSWM 3`,
  `STPO`, `STMA`; HS-CAN (ISO 15765-4, 11-bit, 500k) for PIDs. A bare ELM327 cannot read it. [FROM FILES we hold]
  BluetoothObdSource.kt:233-251,362-372,417-429.
- **Header format:** 29-bit `(priority << 26) | (message id << 13) | source node`; most frames come from node 0x040.
  [INFERRED] arithmetic on every id (see 1.7).
- **Layouts:** comma.ai opendbc `gm_global_a_lowspeed`, Motorola bit order. [FROM FILES we hold] SwCanSignals.kt:5-12.
- **Validated on this truck** (from code comments and commits; raw logs not on this Mac):

| Message (header) | Field | Validation |
|---|---|---|
| 0x166 (`102CC040`) | byte2 PRNDL: CF P, CE R, CD N, C1 D/L/M | [OBSERVED on device] repeated controlled captures (SwCanBody.kt:211) |
| 0x132 (`10264040`) | byte6 high nibble: 00 2H, 10 4H, 20 4L | [OBSERVED on device] 2026-07-05 live work |
| 0x110 (`10220040`) | byte6 bit0 turn flashing | [OBSERVED on device] original live work |
| 0x106 (`1020C040`) | stalk, lamps, hazards, reverse/brake lamp, high beam (turn fields validated) | [OBSERVED on device] blinker captures |
| 0x168 (`102D0040`) | byte4 oil life ×100/255 | [OBSERVED on device] dash-validated |
| 0x360 (`106C0040`) | odometer BE ×0.015625 km | [OBSERVED on device] exact vs dash |
| 0x3C0 (`10780040`) | roll byte6[6:0] ×0.703125−45 | [FROM FILES we hold] "verified" |
| 0x170 (`102E0040`) | coolant 63/8−40 | [OBSERVED on device] 210 °F = OBD |
| 0x115 (`1022A040`) | byte2 park brake 00 / A0 | partial: toggle transient only (a28c26d) |

  Everything else (doors, hood, TPMS, lockers, steering/IMU, cruise, trailer, battery/SOC, wheel speeds, climate
  0x39A/0x40A, ignition, fuel/pitch) is opendbc-borrowed and not truck-checked. Full table:
  `device-facts/gm-body-bus.md`.

### 6.3 GM Global B / 2019+ Silverado specifics

Nothing about Global B is recorded in any local file (acx-sim, cor-sim, cluster-app, myCarplay HEAD, memory).
[FROM FILES we hold] grep, no hits. The truck's body bus behaves like Global A: Global A low-speed layouts decode and
validate. As general background, not from our files: the refreshed 2022 trucks moved to Global B, while the
2019-2021 trucks and the 2022 "LTD" carryover stayed on Global A. That fits the platform reading in 5.5. [INFERRED, low]

### 6.4 HS-CAN (ECM) PIDs

Request 7DF/7E0, reply 7E8. Polled: 01 04 05 06 07 0C 0D 0E 0F 10 11 1F 2F 33 3C 42 43 46, plus modes 03/07/0A/04/09 02.
GM mode-22 DIDs (ECM 7E0 / TCM 7E2) are untested community candidates. While the body bus streams, PIDs refresh only
~every 30 s. [FROM FILES we hold] BluetoothObdSource.kt:90-120; ~/cor-sim/elm.py:54-55,133-134.

### 6.5 Head-unit MCU frames

`a5 2e cmd len payload crc`, crc = sum(cmd..payload) XOR 0xFF. Our app has only ever seen 7 command types
[OBSERVED on device] (commit 5ee8d96): 0x03 HVAC, 0x13 seat-cool (all zero), 0x14 rpm, 0x24 doors, 0x26 steering,
0x29 (all zero), 0x36 dashboard (commits 28aa1dc, 35b64db, b992b6d). Which 7 is [INFERRED] from those commits; the
sweep commit gives only the count. Also: 0x0B (meaning doubtful) appeared once, in the vendor console sniffer on
2026-07-29, never in our app [OBSERVED on device] audit:37; 0x30 (firmware string) is known from vendor code only
[FROM FILES we hold] McuFrameDecoder.kt:126-128. Map and status: `device-facts/data-paths.md` §D.

### 6.6 The cluster's XCI box

The ACX_Dash cluster (Allwinner T507, 1920x720) reads its own XCI CAN box on `/dev/ttyS2` at 115200 with the same
0x2E framing; types 0xE1-0xE5 are MCU-flash commands there and must never be sent. Readings are always metric, with
no-data sentinels (coolant 0xFF, TPMS 0xFFF …) that turn into nonsense if forwarded as numbers. The package has
Silverado models 57/58 (2014-18) and 59/60/75 (2019-23); which one this cluster uses is unknown. XCI cannot supply
4WD state or steering angle. **No XCI field has been checked on the truck.** [FROM FILES we hold] acx-sim REVIEW.md:89,96-97,107;
sim_server.py:172-200,309-360; VehicleModels.qml:122-147. Details: `device-facts/cluster-xci.md`.

### 6.7 By topic

- **Steering wheel buttons:** reach the head unit as `MCU_KEY_INFOR` / `EventUtils.MCU_KEY_VALUE` (collected, never
  mapped). On the cluster, vendor codes Back 1, Up 2, Down 3, Enter 4, Left 5, Right 6 (state 0/1/2). Which code each
  Silverado button sends is unrecorded on both. [FROM FILES we hold] Gt7EventBusSource.kt:253,370-371; Global.qml:2112-2118.
- **Climate:** verified path is head-unit MCU cmd 0x03/0x13 and the air keys (see `device-facts/hvac-and-canbox-frames.md`).
  Body-bus climate frames 0x39A / 0x40A (node 0x099) exist but are unverified. [OBSERVED on device] / [FROM FILES we hold]
- **Doors:** MCU 0x24 (driver 0x40, passenger 0x80, verified); body 0x318 / 0x17B / 0x17C / 0x17D / hood 0x394
  (unverified); cluster XCI type 0x05 (unverified).
- **Lighting:** body 0x106 Lighting_Status_LS (turn fields validated); turn bit on 0x110; dimmer id unknown.
- **Speed / engine:** head-unit `MCU_CAR_CAN_INFO`; body 0x165 Engine_1 (unverified); OBD PIDs.

---

## 7. Physical / USB facts

| Item | Fact | Provenance |
|---|---|---|
| Head-unit display | 1440x1920 portrait (`wm size` on the truck unit); density 320; myCarplay forces a 1440 dp design canvas. Panel MAD200JB1-3 behind a Lontium LT9211D MIPI-to-LVDS bridge, 4 lanes, 60 Hz. Diagonal not recorded | [OBSERVED on device] 274afb41:1701 (2026-09-26); ce112634:1282; audit:58; [FROM FILES we hold] `[zxw_Config]`, `[timing_Config]` |
| Factory radio video in | 800x480 LVDS through an LT8918 receiver: `/sys/lt8918/lt8918_signal` = 1, AIS frame counter ~60/s, dmesg hact 800 / vact 480. Path: `RequestCar8836LVDS()` (`49 14 01`), then `openCamera(surface, 0, 0, channel 6)`; only channel 6 enables the LT8918. 0 standard Android cameras; auxcamera's analog AV-in has nothing wired | [OBSERVED on device] StereoFeedController.kt:17-39,147-168; commits 5451e0f, 2fa550e, dd1843b |
| CarPlay video plane | Its own SDE plane (pipe 44, BT601_625, full range), separate from the app's GPU layer; screencap cannot see it | [OBSERVED on device] memory carplay-card-skin.md:21-23 |
| CarPlay dongle (USB host) | VID 0x1314 (4884) PID 0x1520, "Magic Communication Tec." / "Auto Box"; claimed as interface 0, IN 0x81 / OUT 0x01. `device_filter.xml` lists ids in decimal; also PID 0x1521 and 0x08E4:0x01C0 | [OBSERVED on device] ce112634:1054,1606; 274afb41:1750; [FROM FILES we hold] device_filter.xml; MessageTypes.kt:287-297 |
| Dongle identity | BOX_SETTINGS (2026-09-26): MFD 20251015, boxType `YA`, OemName `carlink`, productType `A15W`, HiCar 1, supportLinkType `HiCar,CarPlay,AndroidAuto`, supportFeatures empty, hwVersion `YMA0-WN16-0003` (uuid and MACs [redacted]). Session 1414x1159 @ 30 fps, format 5, packetMax 49152. Docs call it a Carlinkit CPC200-CCPA | [OBSERVED on device] 274afb41:1729; HEAD CLAUDE.md:47 |
| USB permission | Granted once through the invisible `UsbAttachActivity` ("use by default" persists across reboots). MainActivity has no ATTACHED filter, because the GT6 re-enumerated the dongle and the filter yanked the launcher forward | [FROM FILES we hold] HEAD README.md:199-204 |
| Second USB device | vendor_id 21325 (0x534D, MacroSilicon's VID), fitting `com.ms.ms2160` in `/product/app/MS9120` (likely a capture bridge). Product id and role not captured | [OBSERVED on device] ce112634:1054 (VID); mapping and role [INFERRED] |
| Storage | By-name partitions map to `sdaN` (privdata2 = sda13, 32 MiB; privdata3 = sda14, 64 MiB), so probably UFS | [FROM FILES we hold] device-backups README.txt; UFS [INFERRED] |
| Writable areas | `/data` and `/mnt/privdata1` (boot animation, checked before `/system/media`). `/system`, `/product`, `/vendor` dm-verity enforcing | [OBSERVED on device] README.md:35-40,204-206; audit:17-25 |
| Boot visuals | `/mnt/privdata1/bootanimation.zip` (1440x1920 at 15 fps, installed 2026-07-01); first-boot "GT7" logo `/vendor/etc/zxw_logo.bmp` drawn by `/vendor/bin/fibo_auto_frvc`. A USB stick can supply `bootanimation.zip`, `zxwbootanimation.ts` or `zxwDeletebootanimation.txt` at its root | [OBSERVED on device] audit:15-17 |
| Debug port | None for USB; wireless adb only (root) | [OBSERVED on device] iCloud HANDOFF.md; README.md:35-40 |
| Radios | GNSS (good fix, ~20 satellites, ~10 m); Wi-Fi client and soft AP; Bluetooth (vendor pairing name `GT7-BT-[redacted]`); built-in cellular/eSIM through ucloudlink/GlocalMe, "Data connection not enabled" | [OBSERVED on device] iCloud HANDOFF.md:143-144; audit:39,41 |
| Amplifier wake | EventService reacts to a kernel uevent on `/devices/virtual/misc/zxw_io` (`notifyARMMuteState`) | [FROM FILES we hold] CarplayAudioPlayer.kt:60-92; commit 61c3e4e |
| OBD port | OBDLink MX+ (STN2255) on Bluetooth SPP; HS-CAN 500k for PIDs and single-wire CAN on pin 1 for body signals | [FROM FILES we hold] SwCanBody.kt:8-11; BluetoothObdSource.kt:239-249; CARPLAY_APP_HANDOFF.md:91 |
| Other peripherals | AuxBeam-class BLE switch panel (service FFF0, control FFF1, state FFF2, 10 channels); ACX_Dash digital cluster (Allwinner T507, 1920x720, own XCI CAN box on UART2, LIS3DH accelerometer, no GPS) | [FROM FILES we hold] BleSwitchPanelSource.kt; ACX_Dash_HANDOFF.md:11-12,37-38; VehicleEvent.qml:55-67 |

### Still open in section 7 (checks not run; owner's OK needed)

| # | Open item | Check (details in `device-facts/open-questions-and-checks.md`) |
|---|---|---|
| 7.1 | Panel diagonal and mounting | Owner: tape-measure the visible area corner to corner |
| 7.2 | Second USB device (0x534D): product id, role | `adb shell` loop over `/sys/bus/usb/devices/*/idVendor`, `idProduct`, `manufacturer`, `product` (never `serial`) |
| 7.3 | CPC200-CCPA vs A15W | Owner: read the model on the dongle case or box |
| 7.4 | Reverse-camera path | Passive park test: a second person shifts to R with the engine running and foot on the brake; Claude watches `logcat` for BACKCAR / auxcamera / ms2160 / frvc and lists SurfaceFlinger layers. Never spoof the gear signal |
| 7.5 | LT8918 vs PR2000 | `adb shell ls /sys/lt8918`; `adb shell "dmesg \| grep -i -E 'lt8918\|pr2000\|ms2160\|ms9120'"` |
| 7.6 | Storage type | `adb shell "ls -l /dev/block/by-name/ \| head -40"`; `adb shell cat /sys/block/sda/device/model` |
| 7.7 | Is the cluster installed | Owner |

---

**Supporting files**

All in `/Users/coreysilvia/Documents/head unit/device-facts/` (text only; nothing copied from the unit beyond short
quoted strings):

- `files-inventory.md`: every head-unit-derived file with full hashes, APK contents, line landmarks, what is missing.
- `data-paths.md`: every broadcast, AIDL call and write path with file:line, source-chain priority, MCU command map,
  wire layers.
- `hvac-and-canbox-frames.md`: HVAC byte map, air-key codes, touch frame, other outbound frames.
- `gm-body-bus.md`: the single-wire CAN frame table, header encoding, PIDs, simulator assumptions.
- `cluster-xci.md`: what cluster-app and acx-sim know (XCI packet types, sentinels, wheel-button codes, vehicle models).
- `vendor-constants.md`: vendor packages, car-type constants, binder codes, UART constants, settings keys and values.
- `open-questions-and-checks.md`: every open question with the exact read-only check and who does it.
- `history-and-stale-docs.md`: recorded misbehaviours and stale statements to distrust.
- `redactions.md`: what kinds of private values were left out.
