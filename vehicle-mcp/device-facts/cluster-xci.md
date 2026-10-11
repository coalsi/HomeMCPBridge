# What the cluster projects know about the truck

Supporting file for `../DEVICE-FACTS.md` section 6. Sources: `~/cluster-app` (HEAD d35be2a, read only), `~/acx-sim`
(vendor package analysis and simulator), `~/Documents/head unit/ACX_Dash_HANDOFF.md`, and the memory notes
`cluster-plugin-facts.md`, `acx-theme-mechanics.md`, `corlink-rev2.md`. **No field of the cluster's XCI CAN box has
been checked on the truck yet**: there is no Stage 0 dump and no day-one capture (CORLINK-1.1-DRAFT.md:406-420).
Everything below is [FROM FILES we hold] (vendor package analysis), not observation.

## 1. cluster-app itself

- It has **no truck-specific CAN map**. It implements generic canbox framings only: Raise `0x2E`, HiWorld `5A A5`,
  RealDash `44`/`66`, with an explicitly illustrative Raise signal map (src/proto/framing.h:1-24).
- framing.h:16-18 notes that the truck's verified HVAC frame (`2E E0 02 key state crc`) is Raise-family.
- Its UART decoder (src/proto/uart_feed.c:105-123) is a self-declared STUB with guessed offsets (types 0x21/0x24,
  little-endian), and its baud table tries 38400 first (serial.c:9), while the vendor uses 115200.
- The interior-illumination (dimmer) arbitration id is unknown; the plan is to diff captures while turning the knob
  (PHASE0-BENCH-RUNBOOK.md:3-14). No public DBC entry was found.

## 2. The ACX_Dash cluster hardware and decoder setup

- Allwinner T507, 1920x720, Linux 4.9.170, Qt 5.14.2 "Launcher" `GM@20241008 r30446`, vendor SNTron/Navirider
  (ACX_Dash_HANDOFF.md:11-12,37-38).
- Vehicle data arrives on UART2 = `/dev/ttyS2` at 115200 8N1 from its own XCI CAN box: `CANBOX_VENDOR_XCI (5)` for
  `vehicleBrand 0` = GM (firmware/ACX_Dash/etc/common/Global.qml:144-151,1186; VehicleEvent.qml:31-38). The KYC box at
  38400 is used only when `mGmModel == 1`; REVIEW.md:96 says this unit runs `mGmModel = 0`.
- Own LIS3DH accelerometer (gyroBus 1), so pitch/roll depend on how the cluster is mounted ("Set level here"). No
  GPS (gpsPort −1), no pressure sensor (VehicleEvent.qml:55-67).
- Silverado vehicle models in the package: 57 `14-18_silverado_h`, 58 `14-18-silverado_l`, 59 `19-23_silverado_h`,
  60 `19-23_silverado_l`, 75 `19-23_silverado_h_3500`. Which one this cluster is set to is unknown until the Stage 0
  `/private` dump. Models 57, 60 and 75 share model 59's ui2 layout (VehicleModels.qml:122-147; memory
  acx-theme-mechanics.md).
- Whether the cluster is physically in the truck yet: records disagree (own-cluster-ui.md:23 "when the cluster
  arrives" vs corlink-status-2026-10-10.md:59). Open.

## 3. XCI framing and host commands

Byte-identical to the Raise framing: `2E | type | len | data | ~sum` (`xci::calchecksum`), with interleaved ACK
bytes 0xFF / 0xF0. Host → box: ACK `FF`; startEnd `2E 81 01 01 7C`; heartbeat `2E 85 01 01 78` (~1.1 s); polls
`2E 82 01 03` and `2E 82 01 17`. **Types 0xE1-0xE5 are MCU-flash commands: never send them.** (REVIEW.md:89,107)

## 4. XCI packet types (jump table in `xci::parseRxData`, libVehicleEvent.so)

| Type | Notifies | Getters (always metric) |
|---|---|---|
| 0x01 / 0x02 / 0x03 | ready / swcInfo / brightInfo | getSwcKey/State; getBright, getBrightMode, getDarkBright |
| 0x04 | speedInfo (only on a change of speed or rpm), lpkInfo | getVehicleSpeed km/h, getTachoSpeed rpm, getLpk L/100 km |
| 0x05 | accInfo, doorInfo, gearInfo | getAcc (ACC line, not Run), getColdIap, getGearIndex/getGearNum (getGear is "" on XCI), getDoor LF/RF/LR/RR/TRUNK/HOOD, radar |
| 0x06 | rtc | getRtc |
| 0x07 | tpmsInfo | getTpmsPressure(0..3 = LF RF LR RR) raw kPa; getTpmsState 0 None / 1 Normal / 2 Low / 3 High (4 Learning is set by the UI) |
| 0x08 | vehicleInfo, waterInfo | coolant °C, oil temp, oil pressure raw×4 kPa, battery V, trans temp, outside °C, oil life %, VIN, boost |
| 0x09 | fuelInfo, tripInfo | fuel %, fuel state, DTE km, odometer km, trip A/B, average fuel/speed, travel time |
| 0x0A / 0x0B / 0x0C / 0x20 | since reset / refuel / start | getSince*(arg required) |
| 0x0D / 0x0F | cruise / turn | getCruiseState, getCruiseSetSpeed; getTurnLeft/RightLight |
| 0x10 / 0x11 / 0x12 / 0x17 | version / telltale table / pop-up warnings / XCI notices | getAlarm(0..254); the GM UI uses 53 indices (AlarmTable.qml); 18 = high beam and 23 = park brake are guesses from the icon art |
| 0x16 | driverModeInfo, ldaInfo | getDriverMode (GM: Tour / Sport / Snow / 4WD / OffRoad / Track), getCompass 0..7 = N..NW, getTrucksTrailerBrakeState (0x1F = none) |
| 0x2F-0x33 / 0x36 | OEM media/nav text / seat heat | getMediaCurrentInfo*, getSeatWarmLevel |
| never on XCI | fourWDInfo, trackInfo, dashboardInfo, oilMeter | JLY/KYC decoders only: so XCI cannot give 4WD state or steering angle |

(~/acx-sim/runtime/sim_server.py:172-200,309-360; Global.qml:2924-2931; a temporary session scratch note,
`I_cluster-signals.md:11,15-26`, in this session's scratchpad, which will not persist)

Gear enum on XCI is unknown (assumed P, R, N, D, L, M = 0..5). TPMS: vendor psi = v/102 × 14.793.

## 5. No-data sentinels (forwarding them as numbers gives nonsense)

DTE 0xFFFF; odometer/trips 0xFFFFFF; coolant 0xFF (0xFC "E", 0xFE hide); oil temp, oil pressure, battery and trans
0xFF; outside 0xFE (0xFC "E"); lpk/avg/time 0xFFFF; TPMS 0xFFF none, 0xFFFD learning, 0xFFFE keep last value and
flash; driver mode 0xFF; compass 0xF; trailer brake 0x1F none. Example failure: coolant 0xFF shown as 491 °F, TPMS
0xFFF shown as 594 psi. (sim_server.py:338-360; REVIEW.md:97; memory cluster-plugin-facts.md:13-21)

## 6. Steering-wheel buttons on the cluster

Vendor codes (Global.qml:2112-2118): None 0, Back 1, Up 2, Down 3, Enter 4, Left 5, Right 6; replica extras Modes 26,
SingleUp 29; state 0 release, 1 press, 2 hold. Which code each Silverado button sends, and the hold/repeat pattern,
are unverified ("still to verify", memory cluster-plugin-facts.md:42).

## 7. Planned split between the cluster box and the head unit

The cluster's XCI box should cover most everyday signals, but not engine-detail PIDs, DTCs, steering angle, 4WD,
SOC or trailer state. To be confirmed per signal with a day-one capture (memory corlink-rev2.md:30-35).
