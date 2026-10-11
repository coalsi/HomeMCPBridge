# Head-unit files held on this Mac (inventory)

Supporting file for `../DEVICE-FACTS.md` section 3. Compiled 2026-10-11 from local, read-only sources. Nothing
here came from a new connection to the head unit. Sizes and SHA-256 hashes were computed on this Mac on
2026-10-11 (`shasum -a 256`). Every entry in the backup folder's own `SHA256SUMS` was re-checked that day and
matched.

`~` = `/Users/coreysilvia`. "iCloud truck folder" = `~/Library/Mobile Documents/com~apple~CloudDocs/mycarplay-truck/`.
"HEAD" = myCarplay git commit `4a4ef50`.

## A. Files that came from the head unit (GT7A Pro-CAR)

| Path | Size (bytes) | SHA-256 | What it is | Why we think it came from the GT7A |
|---|---|---|---|---|
| `~/mycarplay-refs/EventCenter.apk` | 29,809,259 | `49d0036195ba3faadc8a9692a74c4d00073799d61fc0538be7ca96cd965a5692` | Vendor broker APK `com.szchoiceway.eventcenter`, pulled from `/product/app/EventCenter` | Its versionName `1.0_20260303-17:50:37` matches the eventcenter version recorded live on the GT7A (session transcript ce112634). Pulled 2026-07-26, when the GT7A was the truck's unit. [FROM FILES we hold] |
| `~/mycarplay-refs/ec.txt` | 91,317,713 | `0cd8138bce1708be595e490be417dd96f24804be80ef5d3e6fd21bff978494c8` | `dexdump -d` of `/product/app/EventCenter/EventCenter.apk`, run on the unit with the on-unit dexdump (DEX 039, 1,299,968 lines) | Same day as the APK; the header names the on-unit path (ec.txt:1-2). [FROM FILES we hold] |
| `~/mycarplay-refs/console.txt` | 92,534,008 | `55c74d96fc6e5273b74cb647b3f03662d6ca16035ceebf9e0d962a6e7ea55485` | `dexdump -d` of `/product/app/ATSLCarConsole/ATSLCarConsole.apk` (`com.android.atslcarconsole`, the vendor CAN console), 1,354,808 lines. The APK itself is not held | Dumped 2026-07-26 for the factory-touch fix, whose code takes the Android 14 (SDK > 33) branch. Nothing inside names the GT7, so this is [INFERRED], medium-high |
| `~/mycarplay-refs/device-backups/2026-09-26/privdata2_zxw_config.bin` | 33,554,432 | `5753d9f91f01977b3e826f0206a83f0951886a4cfded664d039838a453ef63ad` | Raw copy of `/dev/block/by-name/privdata2` (sda13). The first 64 KiB is a `[zxw_Config]` text block; the rest is zeros | Backed up from the GT7A on 2026-09-26 (folder README). [FROM FILES we hold] |
| `…/2026-09-26/privdata3.bin` | 67,108,864 | `6fc0c291b7687bbcead7c99b60d2ee7158fbb6f9bfa105c41c41448888b8b09a` | Raw copy of privdata3 (sda14): a copy of `[zxw_Config]`, a `[timing_Config]` block (1440x1920, 4 lanes, 60 fps, porches, power-up sequence), and an empty ext4 | same |
| `…/2026-09-26/bootanimation_trailboss_privdata1.zip` | 34,465,580 | `d92761f3d25cc91d18603937d98a9cd6522e7589b34a2d0ad6a419ddd404dd1b` | `/mnt/privdata1/bootanimation.zip`: the owner's Trail Boss boot animation, 124 entries, `desc.txt` = `1440 1920 15` | same |
| `…/2026-09-26/zxw_logo.bmp` | 120,054 | `1eb1b5418ece36bf4954585d6a10815d5888e2f3d61d8bdc9a5a637e13bf4983` | `/vendor/etc/zxw_logo.bmp`, 200x200 24-bit, the "GT7" first-boot logo. dm-verity protected; never write | same |
| `…/2026-09-26/ksw_logo.bmp` | 404,454 | `10e560c2567c993c570edf07a16bd2a39051014cd3265c9666038fd4f524f38e` | `/vendor/etc/ksw_logo.bmp`, 898x150 24-bit, a KSW-brand logo shipped on the same image | same |
| `…/2026-09-26/README.txt` | 1,133 | `965a7369f7be94c34babc4714674b69af3df9ff7aabcf532f6568751a504cd3e` | Our own notes for the backup. It forbids restoring anything without the owner's approval | ours |
| `…/2026-09-26/SHA256SUMS` | 433 | `953fa30a2a6a177ed234efbc40095e3675a4ecab7c7753096aa6bc4d0f114410` | Hash list for the backup; all entries re-verified 2026-10-11 | ours |
| iCloud truck folder `incident-2026-07-27-raw.log` | 61,746 | `3b11f3a1c85e449bc6662bed81b63a07d7519c7233b1385275cd95b420adaac4` | 342-line logcat excerpt around the ACC-standby kill of 2026-07-27. Line 4: `LogoWindowView onRefreshView getCanCarType(): 16, getLogoType(): 349`. Line 231: a DashboardInfo dump, all `--` except oil and water temperature | Recorded on the GT7A (incident write-up in the same folder). [OBSERVED on device] |
| `~/.claude/projects/-Users-coreysilvia-Documents-head-unit/ce112634-…/tool-results/b8hv78jy3.txt` | 36,392 | `4ce1a4c4dc42679c296b1a39634175e0f7a67052b626b106f13c18b7f2b9fed2` | 60-line logcat excerpt from 2026-09-26: `BaseCanNew: sendDashboard: DashboardInfo{… oilTemp='188 °F', waterTemp='212 °F', transTemp='129 °F', oilPressure='34.8 PSI' …}` every 1-3 s | Recorded on the GT7A. [OBSERVED on device] |
| myCarplay HEAD `app/src/main/jniLibs/arm64-v8a/libcamera_utils.so` | 10,256 | `6a802fa5c0976a9c739de56187d6859512a4ebf0886b13ad3bf43b1be844b5f2` | Vendor AIS-camera JNI shim (`open_camera`, `set_surface`, `set_sensor_output_fmt`; registers `com/szchoiceway/camera/CameraUtils`), added in commit 5451e0f "from the OEM console". Not byte-identical to any of the three variants inside EventCenter.apk. Works only from `/product`, so it is reference-only | [FROM FILES we hold] |
| myCarplay HEAD `IEventService.aidl` / `DashboardInfo.java` | 6,264 / 12,215 | `591ef9b1…` / `d5584cc6…` (truncated in the researcher's notes) | Reconstructed vendor wire contracts (see section C below) | [FROM FILES we hold] |

### Contents of EventCenter.apk (from `aapt dump badging`, `aapt dump xmltree` and `unzip -l`) [FROM FILES we hold]

- Package `com.szchoiceway.eventcenter`, versionName `1.0_20260303-17:50:37`, versionCode 1, minSdk 28, targetSdk 33,
  `sharedUserId android.uid.system`.
- 1,107 zip entries, including `classes.dex`; `lib/*/libserial_port.so` for every ABI (the arm64 copy is 9,904 B,
  sha256 `542226b8…7adc`); three arm64 camera shims: `libcamera_utils.so` (14,400 B, `5f6bbf16…a55`),
  `libcamera_utils_2025-11-05.so` (14,400 B, `e006fae2…7a5`), `libcamera_utils_old.so` (14,376 B, `32e85565…27d`);
  assets `Track07.mp3` and `letterIcon.png`.
- The manifest itself requests `FORCE_STOP_PACKAGES`, `SERIAL_PORT`, `INJECT_EVENTS`, `INSTALL_PACKAGES` and `REBOOT`.
  `.EventService` is `exported=true` with no permission. (This corrects the audit memory, which said
  FORCE_STOP_PACKAGES came only from the shared UID.)

### Landmarks inside ec.txt (EventCenter dexdump) [FROM FILES we hold]

| Lines | What is there |
|---|---|
| 1-2 | Header: `Processing /product/app/EventCenter/EventCenter.apk` |
| 599330, 621108 | The two callers of `EventService.openSerialPort()` |
| 602362 | `EventService$6$1.onCmdCanEvent([B)`, which broadcasts `MCU_MSG_CAN_ALL_INFO` |
| 638160-638183 | `EventService.openSerialPort()`: `new android.serialport.Device("/dev/ttyHS1", "115200")`, then SerialPortManager, then the process-cmd and send threads |
| 638338-638346 | Logo-type group 220 / 349 / 353 / 221 / 224 (Silverado, Silverado new 22, Colorado new, Colorado, Tahoe) handled together before `startModeActivity` (checked 2026-10-11) |
| 654125-654128 | `CARTYPE_BUCIK_HI = 16` (CARTYPE_BUCIK = 15 just above) |
| 655200-655203 | `CARTYPE_Kaluola_LO = 84` (Toyota Corolla), the only EventUtils CARTYPE equal to 84 (checked 2026-10-11) |
| 655870-655878 | `CARTYPE_SILVERADO_LO = 220`, `CARTYPE_SILVERADO_NEW_22 = 349` |
| 656195-656198 | `CARTYPE_WEILANG_HI = 177` (Buick Verano) |
| 656450-656453 | `CARTYPE_yinglang_LO_NEW = 109` (Buick Excelle GT). Corrected by the checker: an earlier draft cited line 656645 as a second CARTYPE equal to 16, but that line is `CAR_AIR_KEY_RWndMaxDefrost = 16`. No other EventCenter CARTYPE equals 16 |
| 758038 | `SysBaseBandModel.getModelName` compares against "GT6" and "GT6-CAR" |
| 660630-660653 | EventUtils UART constants: `UART_DEV_PATH /dev/ttyS1`, PX5 `/dev/ttyS3`, RK3188 and SoFIA `/dev/ttyS0`, `UART_DEV_SPEED 115200` (leftovers; not what openSerialPort uses) |
| 662161-662172 | `getMcuComDevicePath()` = `/dev/ttyS3` (no callers found) |
| 1115425-1116113 | `IEventService$Stub` transaction codes, including sendSystemKey 4, getMCUVer 32, sendCanbusData 48, IsBackCarConneted 88, getCanVer 105, IsBrakeConneted 119, setCanA5DataCallback 132, setDashBoardCallback 143, openCamera 145 |

### Landmarks inside console.txt (ATSLCarConsole dexdump) [FROM FILES we hold]

| Lines | What is there |
|---|---|
| 742811 / 744031 | `Customer$CarType.FORD_FIESTA = 16`, `Customer$CarType.MITSUBISHI_OUTLANDER = 349` (checked 2026-10-11) |
| 752665-752673 | The console's own copy of `EventUtils`: `CARTYPE_BUCIK = 15`, `CARTYPE_BUCIK_HI = 16` |
| 753665 / 755485 | Same class: `CARTYPE_FORD_FIESTA = 16`, `CARTYPE_MITSUBISHI_OUTLANDER = 349` (checked 2026-10-11) |
| 756195-756203 | `CARTYPE_SILVERADO_LO = 220`, `CARTYPE_SILVERADO_NEW_22 = 349` |
| 1000260 | `isCanbus2App()` and the "Simple GM" predicates |
| 1011775-1011811 | `MainActivity.sendBuickAirkey` builds `[2E, E0, 02, key, state, crc]` |
| 1011813+ | `MainActivity.sendBuickCarKey` (type 0xE1) |

Takeaway: in EventCenter (which logged the values) 16 and 349 each have exactly one CARTYPE name. The console's
own tables reuse both numbers (Ford Fiesta, Mitsubishi Outlander), so a name taken from another vendor app's table
may differ. See `../DEVICE-FACTS.md` section 5.

### The `[zxw_Config]` block (privdata2, first 64 KiB; same block in privdata3) [FROM FILES we hold]

`VendorName=ZXW`, `PanelName=MAD200JB1-3`, `PanelInfo=LT9211D_U2`, `ScreenWidth=1440`, `ScreenHeight=1920`,
`isLandScreen=0`, `Rotation=0`, `TouchType=12`, `TouchCalibrate=6`, `ScreenName=KW`, `ScreenChip=5000`,
`BackCarType=0`, `CameraConfig=0`. It holds no CAN or car-type keys.

## B. Firmware packages

- **No head-unit firmware is on this Mac.** A search of `~` (excluding `~/Library` and build folders), `~/Downloads`,
  `~/Documents`, `~/mycarplay`, `~/mycarplay-refs` and the iCloud truck folder found no `update*.zip`, `.img`,
  `dmcu*` or MCU `.bin`. [FROM FILES we hold]
- The head unit's version strings therefore come only from the vendor Software Version screen (viewed 2026-07-29,
  memory `head-unit-vendor-stack-audit.md`) [OBSERVED on device]:
  - MCUVer `RL9Ac_KWYa13___S077`
  - CAN (decoder) `A3bA_s_A_251118`
  - FrameworkVer `QCOM 685-GT7APro-GL-user-20260318.154007`
  - APPVer `20260318-1440x1920-GT7A-YIMI_8918-/-16-349-2-11`
  - Panel-ChipVer `LT9211D_U2--MAD200JB1-3--FRAME RATE:60`
- Vendor app versionNames recorded live (transcripts in `~/.claude/projects/-Users-coreysilvia-Documents-head-unit/ce112634-*`):
  auxcamera `1.0_20251219`, carddesk `2025-10-16`, customerui `1.0_20260316`, eventcenter `1.0_20260303`,
  ui `1.0_202511051518`, zxw_dashboard `1.0_20251126`. [OBSERVED on device]
- The only firmware package held is for a different unit, the ACX_Dash instrument cluster (see section E).

## C. Vendor-derived artifacts inside the myCarplay repo (HEAD) [FROM FILES we hold]

- `app/src/main/aidl/com/szchoiceway/eventcenter/IEventService.aidl`: 148 methods reconstructed from the GT7
  EventCenter. Declaration order equals the binder transaction code, so never reorder it.
- `ICallbackfn.aidl`, `ICameraService.aidl`, `ICommunication.aidl` (eventcenter); `ILinkInterface.aidl`,
  `ILinkEventListener.aidl` (`com.sylink.service`, built-in CarPlay).
- `app/src/main/java/com/szchoiceway/canbus2/bean/DashboardInfo.java`: the 87-field Parcel layout taken from
  `com.szchoiceway.canbus` (`/product/app/Canbus/Canbus.apk`) `writeToParcel`.
- `app/src/main/java/com/szchoiceway/camera/CameraUtils.java`: copied verbatim from the console.
- `jniLibs/arm64-v8a/libcamera_utils.so` (table A).

## D. Not on this Mac (would have to come from the unit or another machine)

- `/product/app/Canbus/Canbus.apk` (`com.szchoiceway.canbus`, which sends `Action_DashboardInfo` and, per the code
  comments, holds `BuickCanService`). The "car type 84" and "mCarType 16-177" comments probably come from here.
- The ATSLCarConsole APK binary (only its dexdump is held).
- The screenshot `nav_swversion.png` of the Software Version screen (2026-07-29); the transcript records its text,
  the image is gone.
- The GT6-era memory notes cited by code comments (`headunit-canbus`, `headunit-hvac`, `obd-elm327-live`,
  `gmlan-opendbc-map`, `xlink-carlinkit`) and the CorPlayDroid repo. `CARPLAY_APP_HANDOFF.md:5` points to
  `~/.claude/projects/-Users-coreysilvia-coreApps-CorPlayDroid/memory/`, which does not exist on this Mac (it is
  probably on the Mac Studio). These likely hold the raw captures behind the body-bus and HVAC "verified" claims.

## E. Excluded on purpose

Our own builds (not vendor files):
- iCloud truck folder `mycarplay.apk`: 40,624,962 B, `1447c53b…3444`, `com.coreysilvia.mycarplay` 0.1.109 (61c3e4e+).
- `~/mycarplay-refs/rollback/mycarplay-0.1.127-22ef542.apk` (`6f447f14…b42a`, embedded versionName
  `0.1.127 (e67c7fa+)`) and `mycarplay-0.1.128-7b91fdc.apk` (`e0d02b4f…58aa`, embedded `0.1.128 (22ef542+)`).
  The file names do not match the embedded versions; check before using either for a rollback.
- `~/acx-sim/lab/artifacts/apk/app-debug.apk` (0.1.132) and everything under `*/build/outputs`.
- `~/mycarplay-refs/xlc.txt` (2,989,691 B, `3a9a6240e74dc4cbff6166e59702dc5e9fd47431fcfd0078987833df5b57058c`): a
  partial dexdump of OUR app, not vendor code.

A different unit (the instrument cluster, not the head unit):
- `~/Documents/head unit/ACX_Dash.zip`, byte-identical to `~/acx-sim/firmware/ACX_Dash.vendor.zip`
  (103,785,940 B, `d5b0842c…ab23`): the vendor (SNTron/Navirider) update package. Allwinner T507, Linux 4.9.170,
  Qt 5.14.2 Launcher `GM@20241008 r30446`; extracted under `~/acx-sim/firmware/ACX_Dash`.
- The Stage 0 `factory.zip` copies (4,777 B, `9b9185a7…f27a`) are our own read-only backup script for the cluster.
  `VehicleEvent_signal_catalog.txt` is the cluster plugin's signal list.
