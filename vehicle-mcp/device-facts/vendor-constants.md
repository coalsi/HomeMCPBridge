# Vendor names, constants and settings (reference lists)

Supporting file for `../DEVICE-FACTS.md` sections 2 and 5. No access codes for any vendor or factory menu are
recorded here, on purpose.

## 1. Vendor packages seen on the GT7A Pro-CAR [OBSERVED on device]

From the read-only `pm list packages -f` and the 2026-07-29 audit (session transcript ce112634; memory
`head-unit-vendor-stack-audit.md`). 201 packages in all: 193 system + 8 third-party; 33 are vendor packages.

- Shenzhen Choiceway / ZXW: `com.szchoiceway.eventcenter` (broker: CAN, MCU, AUX video, ACC standby),
  `com.szchoiceway.canbus` (Canbus.apk: sends Action_DashboardInfo), `com.szchoiceway.settings` ("NaviSettings"),
  `com.szchoiceway.zxwlink` (built-in CarPlay screen), `zxwcarplayer`, `zxwmedia`, `zxw_dashboard`, `zxw3d`,
  `com.szchoiceway.auxcamera`, `com.szchoiceway.navigation` (actually a side/rear camera selector),
  `com.szchoiceway.btsuite` (phone/dialer), `com.szchoiceway.apkinstall`, `com.szchoiceway.customerui`
  (vendor home, inactive), carddesk, ui/XUIService, landroverbackgroundset, wallpaper, weather, musicplayer,
  videoplayer, car3d, testtools, update, logcatupload/logcapture.
- `com.choiceway.*` (no "sz"): e.g. `com.choiceway.dsp` (24-band EQ); also the action prefix
  `com.choiceway.eventcenter.*`.
- `com.lfg.szchoiceway.canupgrade` ("CanUpgrade"): a CAN-gateway **firmware** updater. Never launch it.
- `com.sylink.service` (built-in CarPlay broker), `com.sykj.fusionlink` (built-in Android Auto screen).
- `com.ucloudlink.*` / `com.ucloudlink.cloudsim` (GlocalMe cellular/eSIM).
- `com.ms.ms2160` in `/product/app/MS9120` (likely a MacroSilicon capture bridge).
- `com.android.atslcarconsole` ("Console", a live raw CAN/serial frame sniffer).
- Also present: AOSP Launcher3 (`/product/app/Launcher3-A14`, dormant fallback); APKPure (`com.apkpure.aegon`) is one
  of the 8 user apps.
- Kernel/system names: `/devices/virtual/misc/zxw_io`, sysprop `sys.zxw.support.xs9922b.common.camera` (unset),
  `/vendor/etc/zxw_logo.bmp`, `/vendor/etc/ksw_logo.bmp`, `/vendor/bin/fibo_auto_frvc`, `/sys/lt8918/lt8918_signal`.

No package from another head-unit family's namespace appears in that inventory. [OBSERVED on device]

## 2. Car-type constants (EventUtils) [FROM FILES we hold]

Values that matter for this truck. Line numbers are the `name` line in ec.txt (EventCenter dump) unless noted.
Entries marked † were checked by the assembler on 2026-10-11.

| Constant | Value | Where |
|---|---|---|
| CARTYPE_BUCIK ("Buick", vendor spelling) | 15 | ec.txt:654120 |
| CARTYPE_BUCIK_HI | 16 | ec.txt:654125 (the only EventCenter CARTYPE equal to 16) |
| CARTYPE_yinglang_LO_NEW (Buick Excelle GT) | **109** (corrected by the checker; an earlier draft said 16) | ec.txt:656450. Line 656645 is `CAR_AIR_KEY_RWndMaxDefrost = 16`, not a CARTYPE |
| CARTYPE_FORD_FIESTA † | 16 | console.txt:753665 (the console's copy of EventUtils); also `Customer$CarType.FORD_FIESTA = 16` at console.txt:742811 |
| CARTYPE_Kaluola_LO (Toyota Corolla) † | 84 | ec.txt:655200 (the only EventCenter CARTYPE equal to 84); the console's copy adds CARTYPE_BM_BMW320 = 84 (console.txt:752595) |
| CARTYPE_WEILANG_HI (Buick Verano) | 177 | ec.txt:656195; the console's copy also has CARTYPE_GM_ASTRA = 177 (console.txt:753850) |
| CARTYPE_SILVERADO_LO | 220 | ec.txt:655870 |
| CARTYPE_TAHOE | 224 | ec.txt:655990 |
| CARTYPE_GMC_OLD | 247 | ec.txt:654815 |
| CARTYPE_GM_A / X / E / S | 257-260 | ec.txt:654815-654848 |
| CARTYPE_SILVERADO_NEW_22 | 349 | ec.txt:655875 |
| CARTYPE_MITSUBISHI_OUTLANDER † | 349 | console.txt:755485; also `Customer$CarType.MITSUBISHI_OUTLANDER = 349` at console.txt:744031 |
| CARTYPE_COLORADO / CARTYPE_COLORADO_NEW | 221 / 353 | ec.txt:654315 / 654320 |

- EventService handles logo types **220 / 349 / 353 / 221 / 224** as one group before `startModeActivity`
  (ec.txt 638338-638346) †. 220 = Silverado (old), 349 = Silverado new 22, 353 = Colorado new, 221 = Colorado,
  224 = Tahoe: a GM truck/SUV group.
- 502 distinct CARTYPE_* names appear in ec.txt (checker count, 2026-10-11); in EventCenter's EventUtils only 4
  values are duplicated (278, 2700, 3800, 3900), none of them 16, 84, 177 or 349. 157 names end in _HI and 147 in
  _LO. What the suffix means is unknown; nothing local supports or contradicts a trim reading. [INFERRED]

## 3. Binder transaction codes, `com.szchoiceway.eventcenter.IEventService` [FROM FILES we hold]

Checked against EventCenter's own Stub (ec.txt:1115425-1116113). Declaration order in myCarplay's
`IEventService.aidl` equals the code; never reorder it.

| Method | Code |
|---|---|
| sendSystemKey | 4 |
| getMCUVer | 32 |
| sendCanbusData | 48 |
| IsBackCarConneted | 88 |
| getCanVer | 105 |
| IsBrakeConneted | 119 |
| setCanA6DataCallback | 131 |
| setCanA5DataCallback | 132 |
| setDashBoardCallback | 143 |
| openCamera | 145 |

The GT6-era port kit (CARPLAY_APP_HANDOFF.md:112) lists the same 4 / 48 / 143, so at least these did not change
between the GT6 and GT7 APKs. Other codes may differ per APK.

## 4. Serial-port constants in EventCenter [FROM FILES we hold]

- Live path: `EventService.openSerialPort()` → `new android.serialport.Device("/dev/ttyHS1", "115200")`
  (ec.txt:638160-638183), through `SerialPortManager` / `libserial_port.so`.
- Leftover per-platform constants in EventUtils (ec.txt:660630-660653): `UART_DEV_PATH = /dev/ttyS1`,
  `UART_DEV_PATH_PX5 = /dev/ttyS3`, `UART_DEV_PATH_RK3188 = /dev/ttyS0`, `UART_DEV_PATH_SOFIA = /dev/ttyS0`,
  `UART_DEV_SPEED = 115200`. `getMcuComDevicePath()` returns `/dev/ttyS3` but has no callers (ec.txt:662161-662172).
- The code also branches on model names "GT6" and "GT6-CAR"; the console has keys `Sys_Is_GT6FE_Model_Key`,
  GT6K, GT6A and strings GT6SE, GT6I, GT6E.

## 5. Vendor settings keys and the few recorded values

Keys present in EventCenter (names only; values on the unit are not held): `Sys_CarType`, `Sys_LogoType`,
`Sys_CarInfor_ID`, `Sys_McuSet`, `Sys_UINumber`, `Sys_CustomerType`, `Sys_Screen_PanelType`, `Sys_Screen_Chip`,
`Sys_TouchType_Key`, `Sys_6806_8836_Screen_Key`. [FROM FILES we hold]

Recorded configuration values [OBSERVED on device]:
- `getCanCarType()` = 16, `getLogoType()` = 349 (incident-2026-07-27-raw.log:4).
- `mCustomerType` = 4 (logged by the console and EventService; StereoFeedController.kt:63-66).
- SysVarProvider: `Sys_UINumber` = [redacted] (a UI style id; withheld as a precaution), `Sys_CustomerType` = 4,
  `Sys_Home_Page_Display` = 1 (audit memory).
- Console source mode 30 = `SRC_ATSL_AIRCONSOLE`; panel `isHorizontal = false`.
- The unit has only `com.szchoiceway.canbus`, so `isCanbus2App()` is false and every console "Simple GM"/canbus2
  predicate is false, including `isChSimpleGm19Silverado8Inch` (needs canbus2 + mCanType 215 + year 6)
  (console.txt:1000260; commit 2fa550e).

## 6. NaviSettings values seen on screen, 2026-07-29 (viewed only, nothing changed) [OBSERVED on device]

- Video: Video In Motion = ON; Original car camera = channel 1 (choices 1 or 2).
- User: Default Navi App = Maps; no app set to start automatically; Voice = Google; Boot Logo and Boot Animation
  entries exist.
- Audio: MIC Gain = 96; Equalizer and Sound Gain entries.
- General: Homepage style = "Classic style"; Day/night, Dimmer, Antenna Power, Language, Units.
- System: Setting Guide, Network, GPS, Wheel settings (an analog resistor-ladder learning tool, HI-Z / LOW-Z plus a
  button grid; probably unused on this CAN-integrated truck), Software Version, Upgrade, Android Settings shortcut.
- Every page has a "Save & reboot" action. Back out without saving when only looking.

## 7. Version strings

See `files-inventory.md` section B (Software Version screen and app versionNames).
