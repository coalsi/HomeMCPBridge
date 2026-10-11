# How myCarplay reads and writes the truck (full path list)

Supporting file for `../DEVICE-FACTS.md` section 4. Code was read at myCarplay git HEAD `4a4ef50` (not the working
tree, which another agent is editing). Paths are relative to `app/src/main/java/com/coreysilvia/mycarplay/` unless
they start with another top-level folder. All rows are [FROM FILES we hold] unless a cell says otherwise.

## A. Every transport, in one table

| # | Transport | Package / class / action / extra | Code | Carries | Used by the source chain? |
|---|---|---|---|---|---|
| 1 | Vendor broadcast | `com.szchoiceway.eventcenter.EventUtils.MCU_CAR_CAN_INFO`, byte[] extra `EventUtils.CAR_CAN_DATA` = [km/h, rpmHi, rpmLo]. The receiver matches `action.endsWith("MCU_CAR_CAN_INFO")` | obd/ChoicewayCanSource.kt:70-86,112-133,144-150 | speed, rpm | Yes, as HU_CAN; nulled after 3 s with no frame |
| 2 | Vendor broadcast | `com.choiceway.eventcenter.EventUtils.MCU_MSG_CAN_ALL_INFO` (no "sz"), byte[] extra `EventUtils.CAR_AIR_DATA`; frames `a5 2e cmd len payload crc`, several per broadcast | obd/Gt7EventBusSource.kt:261-276,379-380; obd/McuFrameDecoder.kt; hvac/HvacManager.kt:65-90,214-215 | cmd 0x26 steering, 0x24 doors, 0x14 rpm, 0x0B speed, 0x36 dash, 0x03/0x13 HVAC | Steering and doors as HU_MCU (aged by the stream, 5 s). HVAC goes straight to the HVAC UI. 0x14, 0x0B and 0x36 are decoded but unused |
| 3 | Vendor broadcast | `Action_DashboardInfo`, Parcelable extra `Extra_DashboardInfo` of class `com.szchoiceway.canbus2.bean.DashboardInfo` (87 fields, positional), sent by `com.szchoiceway.canbus` (logcat tag `BaseCanNew`, `sendDashboard`, every 1-3 s) | obd/Gt7EventBusSource.kt:279-323,359,383-386; data/SignalReadings.kt:47-52,79-89; DashboardInfo.java:6-21 | display strings such as `174 °F`, `30.8 PSI`, `--` | Only coolant, oil temp, trans temp and oil pressure (`DASHBOARD_PROVEN`), stale after 5 s |
| 4 | Vendor broadcast | `com.choiceway.eventcenter.EventUtils.MCU_MSG_BACKCAR_START` / `_END` | Gt7EventBusSource.kt:237-238,365-366 | reverse-camera trigger | VENDOR_BUS, unverified |
| 5 | Vendor broadcast | `com.choiceway.eventcenter.EventUtils.MCU_MSG_BRAKE_EVT` (then re-reads `IsBrakeConneted()`) | :241-246,367 | brake-detect (video-lockout) input | VENDOR_BUS, unverified |
| 6 | Vendor broadcast | `com.szchoiceway.eventcenter.EventUtils.ACTION_ACC_SLEEP_STATUS_EVT`, int extra `ACC_Status` | :247-252,368-369 | ACC 1/0 | VENDOR_BUS, unverified; also used for SessionLog attribution (AppGraph.kt:100) |
| 7 | Vendor broadcast | `com.szchoiceway.eventcenter.EventUtils.MCU_KEY_INFOR`, int extra `EventUtils.MCU_KEY_VALUE` | :253,370-371 | steering-wheel key code | No consumer |
| 8 | Vendor broadcast | `com.choiceway.eventcenter.CanUtils.CAN_CAR_OUT_SIDE_TEMP_EVT`, String extra `com.choiceway.eventcenter.CanUtils.CAN_CAR_OUT_SIDE_TEMP_EVT_EXTRA_STR` (unit suffix required) | hvac/HvacManager.kt:92-104,216-217; cluster/OutsideTempBroadcastClock.kt:60-114 | outside temperature string | First source on the Outside Temp row while ≤ 10 min old. It has never fired on the truck (row 15 sweep) |
| 9 | Bound AIDL | `Intent().setClassName("com.szchoiceway.eventcenter", "com.szchoiceway.eventcenter.EventService")`, interface `com.szchoiceway.eventcenter.IEventService`: setDashBoardCallback 143, setCanA5DataCallback 132, setCanA6DataCallback 131, IsBrakeConneted 119, IsBackCarConneted 88, getMCUVer 32, getCanVer 105 | Gt7EventBusSource.kt:162-217,231-234,361-362; aidl/.../IEventService.aidl | raw dash, A5 and A6 frames (hex-logged only, tag `GT7BUSPROBE`); brake and reverse on bind | The getters feed VENDOR_BUS; the three callbacks are probes only. No record shows they ever fired |
| 10 | Raw binder transaction | EventService bound by action `com.szchoiceway.eventcenter.EventService` + `setPackage`; token `com.szchoiceway.eventcenter.IEventService`, code 48 (`sendCanbusData`), payload `0D 08 2E E0 02 key state crc` | hvac/HvacController.kt:58-64,80-130 | HVAC air-key **writes** | n/a |
| 11 | Broadcast out | `com.szchoiceway.eventcenter.EventUtils.ACTION_MCU_CMD_EVENT`, byte[] extra `EventUtils.MCU_CMD_DATA` | carplay/StereoFeedController.kt:120-145,261-263; carplay/CarplayAudioPlayer.kt:353-360 | LVDS request `49 14 01`, factory touch `0D 08 2E E3 05 …`, audio flag `3F 00 01` + unmute `0A 00` | n/a |
| 12 | Bound AIDL + calls | `setCurModeCallback(30, cb)`, then `openCamera(surface, 0, 0, 6)` (code 145) and `setCameraChannel("6")` | StereoFeedController.kt:93-102,147-168 | factory radio video | n/a |
| 13 | Bound AIDL | `com.sylink.service/.LinkService` (`ILinkInterface`) | carplay/BuiltInCarPlayController.kt:208-213 | built-in CarPlay (disabled: `Features.BUILTIN_CARPLAY = false`) | n/a |
| 14 | Bluetooth SPP | RFCOMM UUID `00001101-0000-1000-8000-00805F9B34FB` to the first bonded device whose name contains OBD / MX+ / ELM / OBDLINK / VLINK / VGATE / VIECAR / KONNWEI | obd/ObdTransport.kt:49-124; obd/BluetoothObdSource.kt:232-264,423-473,531-554,739-740 | HS-CAN PIDs, MIL/DTC/VIN, GM single-wire body frames | OBD_PID and BODY_BUS |
| 15 | Diagnostic probes (opt-in) | ChoicewayCanProbe (7 actions, enabled with log tag `CANPROBE`); McuProbe (125 actions, log tag `MCUPROBE`) | obd/ChoicewayCanProbe.kt:26-34; obd/McuProbe.kt:28-154 | logging only | No |
| 16 | Wi-Fi (corlink) | The cluster's `signals` on an SSE stream from the cluster's corlinkd (port 8770, mDNS `_corcluster._tcp`); the head unit pushes ambient_f, heading_deg, gps_speed_mph, steering_deg, drivetrain back | cluster/ClusterLink.kt:52-66,277-305; corlink-client SourceChain.kt:187-189,231-243; Timing.kt:71-86 | cluster XCI CAN-box values | CLUSTER, only while the link is UP and age ≤ 3 s |
| 17 | Android API | LocationManager (GPS bearing and speed) | location/ | heading, GPS speed | Never used as vehicle speed |
| — | Not used | No content provider, no `/dev/tty*`, no vendor SDK jar. The only ContentResolver use is an image picker (ClusterSettingsSection.kt:574). System properties read: `CarplayConnectStatus`, `sys.zxw.support.xs9922b.common.camera` | SysProp.kt; BuiltInCarPlayController.kt:208; StereoFeedController.kt:67 | — | — |

Manifest (AndroidManifest.xml:16-17,39-49): uses-permission `com.szchoiceway.permission.broadcast`; `<queries>` for
`com.szchoiceway.eventcenter`, `com.sylink.service`, `com.szchoiceway.zxwlink`. Receivers are registered
`RECEIVER_EXPORTED` (required on API 33+).

**Two package spellings are on the wire.** `com.szchoiceway.eventcenter.*` (EventService, most CAN actions) and
`com.choiceway.eventcenter.*` (no "sz": the raw firehose, backcar, brake, outside temp). Copy them verbatim
(Gt7EventBusSource.kt:364; CARPLAY_APP_HANDOFF.md:111,113).

## B. Source-chain priority at HEAD

`SourceChain.firstFresh` (corlink-client/.../SourceChain.kt:91-203; data/VehicleSignals.kt:136-155;
data/SignalReadings.kt:193-212):

1. OBD-only names
2. Verified vendor bus (park_brake / reverse / acc). All three verification flags are false today, so this step
   never fires.
3. OBD MIL (check_engine)
4. Body bus, for BODY_FIRST names
5. HU MCU (steering)
6. HU CAN (speed / rpm, 3 s)
7. Vendor dashboard (5 s)
8. Cluster (link up, 3 s)
9. The fresher of OBD PID (35 s; speed/rpm 5 s) and body bus
10. Weather (ambient)

After that: MCU doors win while the MCU stream is live, reverse/gear reconciliation runs, and the cluster level
calibration applies. Unverified readings rank after every verified one, carry an "(unverified)" label, and never
light lamps (obd/VendorBus.kt:91-128; data/ClusterVerification.kt:29-34; SourceChain.kt:116-163).

## C. Data that is collected but nothing reads

- `Gt7EventBusSource.swcKey` (steering-wheel keys), `rpm` and `speedMph` (MCU 0x14 / 0x0B), `doorMask`,
  `dashFrameSeen`, `canFramesSeen`.
- The MCU 0x36 decode (oil pressure, oil, trans, coolant): computed in McuFrameDecoder.kt:107-124, never consumed.
  The ACTION_CAN_ALL handler reads only rpm, speedMph, steeringDeg and doors (Gt7EventBusSource.kt:261-276).
- DashboardInfo fields outside the four proven ones: gear, fuel, TPMS, handbrake, turn signals, high beam, seatbelt.
- Constants for `ZXW_CAN_WHEEL_TRACK_EVT` and `ACCORD_DOOR_INFO` are declared but never registered.

## D. Raw MCU command map (`a5 2e cmd len payload crc`)

`crc = (sum of cmd..payload) XOR 0xFF`; the `a5 2e` preamble is excluded. Vendor indexing: `byData[0]` = cmd,
`byData[2]` = first payload byte (McuFrameDecoder.kt:14-29,57-77).

| cmd | Meaning / decode at HEAD | Status |
|---|---|---|
| 0x03 | HVAC main air, 7 bytes a0..a6 (see `hvac-and-canbox-frames.md`) | [OBSERVED on device], owner-locked |
| 0x13 | Seat-cool byte (a7) | [OBSERVED on device], all-zero on this truck (commit 35b64db) |
| 0x14 | rpm, big-endian u16 of payload[0..1] | [OBSERVED on device], CRC sample `14 02 03 25 -> c1` |
| 0x0B | Road speed, `((p0<<8)|p1)/16`, capped at 255 | Code says "never yet observed". The vendor console sniffer did show a valid frame `A5 2E 0B 02 06 C0 2C` on 2026-07-29 (audit memory). CRC checks: 0x0B+0x02+0x06+0xC0 = 0xD3, XOR 0xFF = 0x2C. It would decode to 108 on a probably parked truck, so the "speed" meaning is doubtful [INFERRED] |
| 0x24 | Doors: 0x40 driver, 0x80 passenger, read from payload[0]; event-driven | [OBSERVED on device] 2026-07-25 (McuFrameDecoder.kt:96-105). Open: the CRC example `24 03 00 04 80` carries 0x80 in payload[2], not payload[0] |
| 0x26 | Steering, little-endian int16 of payload[0..1] / 195; event-driven | [OBSERVED on device], 121 frames in one lock-to-lock sweep, scale never cross-checked |
| 0x29 | All-zero payload | [OBSERVED on device], meaning unknown |
| 0x30 | Firmware version string | known, unhandled |
| 0x36 | Oil pressure BE/10 psi (0xFFFF = none), then oil, trans, coolant as `(x−40)·1.8+32` °F (0xFF = none) | [OBSERVED on device] (172 frames + one vendor-logged frame); decoded but unused. Open: the documented example `01 30 77 58 89 00 00 -> 30.4 PSI / 174 / 118 / 206 °F` decodes only if psi is payload[0..1], but the code reads payload[1..2]. Either the comment drops a leading byte or the code is off by one |

Only 7 command types have ever appeared (commit 5ee8d96).

## E. Wire layers (cheat sheet)

- **MCU → Android** (inside `MCU_MSG_CAN_ALL_INFO`): `a5 2e <cmd> <len> <payload…> <crc>`.
- **Android → CAN box, through the MCU**: payload `0D 08` + a 0x2E-family box frame `2E <type> <len> <data> <chk>`.
  Types: E0 air key, E1 car key, E3 touch. Other 2E commands seen on the bus with unknown meaning: 2E 90, 2E E2,
  2E 82, 2E E4.
- **Direct MCU commands** (no `0D 08`): `3F 00 01` (ARM audio active), `0A 00` (unmute), `49 14 01` (LVDS request).
  Never send a source claim such as `01 0B`: it cuts the FM radio.
- **EventService UART framing**: `0d 0a <len> <payload> <chk> 00`, `chk = 0xFF − ((len + Σpayload) & 0xFF)`.
  Captured example: `0d 0a 0d | 0d 08 ff 55 95 05 01 02 00 02 00 9f | 4b 00` (the old generic FF 55 touch, which the
  factory radio ignored). [OBSERVED on device] (memory factory-touch-gm-variant.md; commit dd1843b)
- **Port**: `/dev/ttyHS1` at 115200 baud, opened by `EventService.openSerialPort()` (ec.txt:638160-638183)
  [FROM FILES we hold]. Not yet confirmed live with an open-file listing.
- **Proof that a frame reached the MCU**: only `SRX sendData` log lines count. `now start sound pid … PkgName = …`
  fires on uevent parsing and proves nothing (iCloud HANDOFF.md "Settled").
