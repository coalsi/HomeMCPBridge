# Recorded misbehaviours, and stale docs to distrust

Supporting file for `../DEVICE-FACTS.md` section 4. Sources: myCarplay commit messages and code at HEAD `4a4ef50`,
memory notes, the iCloud truck folder. Each item says how we know it.

## 1. Misbehaviours on record

| What happened | How we know | Status |
|---|---|---|
| Speed/rpm latched forever: a parked truck showed "SPEED 45 / 1,850 RPM" and hid the OBD fallback | [OBSERVED on device], commit 2b72697 | Fixed (3 s watchdog) |
| The CAN link showed green "Streaming" before any frame arrived | [FROM FILES we hold], commit 2b72697 | Fixed |
| Gear showed P for 150-900 ms after P→R (the oldest sample in the window was decoded) | [FROM FILES we hold], commit 90859eb | Fixed |
| Gear and drivetrain lagged up to ~8 s under the old dip scheduler | [FROM FILES we hold], commit 8a4f5c8 | Improved; the current design still freezes ~1.5-2.5 s every ~30 s during HS-CAN excursions (BluetoothObdSource.kt:734-739) |
| A red parking-brake lamp lit with the brake released (wrong body byte, byte4 bit6) | [OBSERVED on device], commit a28c26d | Fixed; the steady "set" value is still unconfirmed |
| An MCU door state outranked fresher body/cluster sources forever | [FROM FILES we hold], commit 91e5ac3 | Fixed |
| A restored SOC snapshot counted as live and could fire a CRITICAL battery alert | [FROM FILES we hold], commit 91e5ac3 | Fixed |
| Latched rpm disarmed Battery Guard | [FROM FILES we hold], commit 2b72697 | Fixed |
| Every HVAC press was followed by a bogus "commit" key 16 (= SYNC), toggling Sync and snapping the passenger temp to the driver's | [OBSERVED on device], commit fe7d9b3 | Fixed |
| Odometer read 1 mile low (inexact km→mi factor) | [FROM FILES we hold], SwCanBody.kt:282-283 | Fixed |
| The vendor's own carddesk fails on Action_DashboardInfo: "consumed 544 bytes, but 640 expected" | [OBSERVED on device], DashboardInfo.java:12-15 | Vendor bug; shows the Parcel layout differs between vendor apps |
| The vendor `ACCORD_DOOR_INFO` broadcast never arrives, although the MCU reports doors | [OBSERVED on device], McuFrameDecoder.kt:10-12; Gt7EventBusSource.kt:257-260 | Worked around (MCU cmd 0x24) |
| ACC standby force-stops myCarplay and cycles Wi-Fi (which restarts adbd and used to move the adb port) | [OBSERVED on device], incident-2026-07-27-app-restart.md; HANDOFF.md | Vendor behaviour; app returns as HOME ~9 s later; adb port now fixed by a persist property |
| CarPlay audio was silent until the MCU 3F flag was added | [OBSERVED on device], HANDOFF.md "Settled"; commit 61c3e4e | Fixed 2026-07-26 (build 109) |
| Factory touch was ignored: the generic FF 55 sender is accepted but ignored on this truck | [OBSERVED on device], memory factory-touch-gm-variant.md | Fixed 2026-07-26 (build 111) |
| Taps during the intro reached the invisible UI and CarPlay | [FROM FILES we hold], commit 90859eb | Fixed |
| Unmapped navigation maneuver ids rendered as "straight" | [FROM FILES we hold], commit 2b72697 | Fixed |
| Vendor launcher won the race after cold boots (myCarplay was not direct-boot aware) | [OBSERVED on device], memory audit; commit 22ef542 | Fixed 2026-09-26 (0.1.127) |
| Outside-temp header went blank offline; "58° °" double degree sign | [FROM FILES we hold], commits 983146f, 91e5ac3 | Fixed |

Searched and **not found**: any record of "-255" values, lagging doors (other than the MCU edge-trigger blank at app
start) or a stuck blinker (other than an inferred ≤ 5 s hold through an HS-CAN excursion).

## 2. Stale or wrong statements in the repo (do not cite as facts)

| Statement | Where | What is true instead |
|---|---|---|
| The GT6-CAR is "in the truck"; the GT7A is "going into the truck now" | README.md:28-33; CLAUDE.md:18-24 (HEAD) | Every live record since 2026-07-26 is the GT7A Pro-CAR |
| "Buick/GMOld profile, car type 84" | HvacState.kt:5; ChoicewayCanSource.kt:15-16; commit 5ee8d96 | EventCenter reports car type 16 / logo type 349 (log, 2026-07-27). 84 is unexplained (see DEVICE-FACTS.md §5) |
| The GT7 dash feed is "captured and logged only"; "until then the OBDLink MX+ still supplies those fields" | README "Known gaps" (HEAD README.md:244-246) | Partly stale. The sentence is about the raw `setDashBoardCallback` frame, which really is only logged. But the separate `Action_DashboardInfo` broadcast is decoded into the chain for coolant, oil temp, trans temp and oil pressure, so the MX+ is not needed for those |
| The 0x36 own-decode replaced DashboardInfo | commit b992b6d | At HEAD the 0x36 decode is unused |
| Gear, drivetrain, fuel and voltage are left out of the default cards | CardSlotsStore.kt:53-54 comment | DEFAULT includes them |
| Steering GMLAN id "0x124", SOC "0x148" | DataCatalog.kt labels | Frames decoded are 10240040 (msg 0x120) and 10248040 (msg 0x124) |
| Air keys need ~95 ms holds plus COMMIT_KEY(16) | CARPLAY_APP_HANDOFF.md:125 | 45 ms hold, no trailing key (16 is SYNC) |
| "live id = DBC id \| 0x10000000 \| 0x40" | CARPLAY_APP_HANDOFF.md:93 | `hdr = (prio << 26) \| (msg << 13) \| src` |
| GPS: "nothing is wired in either direction" | iCloud HANDOFF.md "Open" (2026-07-27) | HEAD uses LocationManager for heading and GPS speed |
| FORCE_STOP_PACKAGES comes only from the shared UID | memory head-unit-vendor-stack-audit.md | EventCenter's own manifest requests it (aapt) |
