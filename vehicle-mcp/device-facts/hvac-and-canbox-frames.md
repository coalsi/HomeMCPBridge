# HVAC decode, air keys and the other CAN-box frames

Supporting file for `../DEVICE-FACTS.md` sections 4-6. Code at myCarplay HEAD `4a4ef50`. HVAC read and write
are owner-confirmed and **owner-locked**: this file documents them, nothing here asks for changes. Any frame in
this file that goes *to* the truck writes to the vehicle bus and needs the owner's OK before it is ever sent.

## 1. HVAC state (read): MCU cmd 0x03, plus cmd 0x13

Source: `com.choiceway.eventcenter.EventUtils.MCU_MSG_CAN_ALL_INFO`, extra `EventUtils.CAR_AIR_DATA`. The 7 air
bytes are `payload[0..6]`; a7 comes from cmd 0x13 `payload[0]`. Decoded like the vendor's
`refreshBuickAirInfor`, not `refreshCarAirInfor` (hvac/HvacManager.kt:12-29,107-173). The vendor also fires
`com.choiceway.canbus.carairstruct`.

| Byte | Bits | Meaning | Status |
|---|---|---|---|
| a0 | b7 | on | [FROM FILES we hold] |
| a0 | b6 | A/C | [OBSERVED on device] (ground truth "AC on") |
| a0 | b5 | recirculation | [FROM FILES we hold] |
| a0 | b4 | rear defrost | decode exists; truck test pending (Hvac.kt:27-37) |
| a0 | b3 | AQS | [FROM FILES we hold] |
| a0 | b2..0 | fan, low 3 bits | [OBSERVED on device] (ground truth "fan 8" needs the high bit too) |
| a1 | b5 | DUAL (independent zones); SYNC = bit clear | [OBSERVED on device] live-captured |
| a1 | b4 | fan high bit (+8) | [OBSERVED on device] |
| a1 | b3..0 | airflow nibble: 5 Face, 3 Feet, 4 Face+Feet, 7 Windshield, 8 Windshield+Feet, 2 max defrost; 6 and 9 inferred | 5/3/4/7/8 [OBSERVED on device] by cycling every detent; differs from the vendor's generic table |
| a2 / a3 | — | driver / passenger temp: 0 = LO, 30 = HI, 255 = blank, otherwise the raw value in the unit from a6 b2 | [OBSERVED on device] (ground truth "LO/LO") |
| a4 | nibbles | driver / passenger seat heat 0..3 | always 0: this truck has no heated seats (owner) |
| a6 | b2 | °F unit | [OBSERVED on device] |
| a6 | b0 | AUTO | [OBSERVED on device] (the AUTO button toggles it) |
| a7 | nibbles | driver / passenger seat cool | all-zero: no cooled seats (owner; commit 35b64db) |

Overall ground truth recorded in HvacManager.kt:20: "AC on, fan 8, temps LO/LO, defrost off". Known quirk: in AUTO,
the fan byte is the stale manual request (commit 68e092d).

Capabilities (Hvac.kt:27-37; owner, 2026-10-11 chat for rear-seat temp) [OBSERVED on device]: no heated seats, no
cooled seats, no ECO mode, no rear-seat temperature, heated wheel not readable (toggling it 5 times changed zero
CAN bytes).

## 2. HVAC control (write): air keys

Frame (inside `0D 08`): `2E E0 02 <key> <state> <crc>`, `crc = ((0xE0 + 0x02 + key + state) XOR 0xFF) & 0xFF`,
state 1 = down, 0 = up. Sent with a raw binder `transact(48)` (`IEventService.sendCanbusData`) on
`com.szchoiceway.eventcenter/.EventService`. Each press is key-down, a ~45 ms hold, key-up, and nothing after
(hvac/HvacController.kt:58-64,72-130). The GT7A console's `MainActivity.sendBuickAirkey` builds exactly
`[2E, E0, 02, key, state, crc]` (console.txt:1011775-1011811). [FROM FILES we hold]

| Key | Code | Key | Code |
|---|---|---|---|
| POWER | 1 | SYNC | 16 |
| DRIVER_TEMP_DOWN / UP | 2 / 3 | FRONT_DEFROST | 18 |
| PASSENGER_TEMP_DOWN / UP | 4 / 5 | MAX_FRONT_DEFROST | 19 |
| FAN_DOWN / UP | 9 / 10 | REAR_DEFROST | 20 (not yet tested on the truck) |
| DRIVER_SEAT_HEAT / COOL | 11 / 12 | AUTO | 21 |
| PASSENGER_SEAT_HEAT / COOL | 13 / 14 | AC / AC_MAX | 23 / 24 |
| | | RECIRC | 25 |
| | | AIRFLOW_PREV / NEXT | 32 / 33 (33 verified only in the demo; HvacController.kt:136-137 says the airflow cycle emits no frame on this profile) |

(HvacController.kt:139-161; commits fe7d9b3, 00d94c0.)

**Superseded advice (do not follow):** CARPLAY_APP_HANDOFF.md:125 says presses need ~95 ms holds plus a
COMMIT_KEY(16) after each. 16 is SYNC: the extra press toggled Sync after every button and snapped the passenger
temperature back to the driver's (commit fe7d9b3, checked against the console's `MainActivity$BuickClickEvent`).
The code (45 ms, no trailing key) wins.

Owner-confirmed: CLAUDE.md:49-53 (HEAD); README attributes the original confirmation to the GT6; the memory note
`hvac-ios27-restyle.md` (2026-10-11) says Max A/C "works on the truck". Transaction 48 is the same in the GT7A
EventCenter Stub (ec.txt:1115960), so the write path carries over. [FROM FILES we hold]

## 3. Factory radio touch (GM/"Buick" variant)

`2E E3 05 <pressed> <xLo> <xHi> <yLo> <yHi> <chk>`, little-endian coordinates in an 800x480 space,
`chk = 0xFF − (sum(bytes 1..7) & 0xFF)` (the leading 0x2E is excluded). Sent as the `MCU_CMD_DATA` of
`com.szchoiceway.eventcenter.EventUtils.ACTION_MCU_CMD_EVENT` after the `0D 08` wrapper; EventService adds
`0d 0a <len> <payload> <outerChk> 00`. Proven against 778 real frames (x 15..702, y 17..457) captured while the
owner drove the vendor console by hand; confirmed on the truck 2026-07-26 (build 111, commit dd1843b).
[OBSERVED on device] (memory factory-touch-gm-variant.md; StereoFeedController.kt:170-192)

The console has twelve touch senders and picks one by `mAirSupplierID` / `mCanType` (plus isChTDLandRover,
isHorizontal, mUINumber). The generic `sendTouchPos` (FF 55, big-endian, 1024x1024) is accepted and silently
ignored on this truck. The value of `mAirSupplierID` on this unit was never recorded.

## 4. Other outbound frames

| Frame | Wrapper | Purpose | Status |
|---|---|---|---|
| `2E E1 02 <key> <state> <crc>` | `0D 08` | car keys (`sendBuickCarKey`) | not used by myCarplay |
| `3F 00 01` + `0A 00`, every 2 s | none (direct MCU) | "ARM audio active" + unmute: wakes the amplifier for CarPlay audio | [OBSERVED on device] working since build 109 (2026-07-26) |
| `49 14 01` | none | RequestCar8836LVDS: switch the LVDS input to the factory radio | [OBSERVED on device] |
| `01 0B` (source claim) | none | **never send**: cuts the FM radio | [FROM FILES we hold] HANDOFF.md |

On the instrument cluster's XCI box the same 0x2E framing is used, but **0xE1-0xE5 there are MCU-flash commands**
and must never be sent (acx-sim REVIEW.md:89,107). Same framing, different command set.

## 5. Checksum examples captured from the truck

- MCU → Android: `14 02 03 25 -> c1`, `24 03 00 04 80 -> 54`, `26 02 02 1a -> bb`, `03 07 … -> d6`
  (McuFrameDecoder.kt:66-72; commit 35b64db). [OBSERVED on device]
- Vendor console sniffer line (2026-07-29): `0xA5 0x2E 0x0B 0x02 0x06 0xC0 0x2C 0x25…` (CRC valid for cmd 0x0B).
  [OBSERVED on device] (audit memory)
