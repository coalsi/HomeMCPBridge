# GM body bus (single-wire CAN) and HS-CAN knowledge

Supporting file for `../DEVICE-FACTS.md` section 6. Everything here is read only through the OBDLink MX+; the head
unit's own decoder never passes these signals on. Code at myCarplay HEAD `4a4ef50`.

Important caveat: the raw capture logs and memory notes behind the "verified on truck" claims below
(`obd-elm327-live`, `gmlan-opendbc-map`, `headunit-canbus`) are **not on this Mac**. The verification status rests
on code comments and commit messages. [FROM FILES we hold]

## 1. Access

- OBDLink MX+ (STN2255) on Bluetooth Classic SPP. Init: `ATZ ATE0 ATL0 ATS0 ATH0 ATSP6` (ISO 15765-4, 11-bit,
  500 kbit/s, for the ECM), then `STI` to detect an STN chip. (BluetoothObdSource.kt:233-251)
- Body-bus streaming: `ATH1 ATS1 ATCAF0`, then `STP 61` (GM single-wire CAN, 33.3 kbit/s, OBD pin 1),
  `STCSWM 3`, `STPO`, `STMA`. HS-CAN must be restored afterwards. A bare ELM327 clone cannot read the body bus.
  (BluetoothObdSource.kt:362-372,417-429)
- Default loop: stream SW-CAN for 30 s, publishing a decode every 150 ms, then a short HS-CAN PID excursion. Each
  excursion freezes body values for ~1.5-2.5 s, and PIDs really refresh only about every 30 s.
  (BluetoothObdSource.kt:423-473,734-740)

## 2. Header encoding

The app logs 29-bit headers. They decompose as `priority(3) | message id(13) | source node(13)`:
`hdr = (prio << 26) | (msg << 13) | src`. Example: `102CC040` = priority 4, msg 0x166, source 0x040.
[INFERRED] from arithmetic on every id in SwCanBody.kt and SwCanSignals.kt (script:
`/private/tmp/claude-501/-Users-coreysilvia-Documents-head-unit/274afb41-430d-4d50-a853-96932615387d/scratchpad/devfacts/gmlan_ids.py`).

- CARPLAY_APP_HANDOFF.md:93 writes the rule as "DBC id | 0x10000000 | 0x40", which is not literally right; the
  arithmetic above wins.
- Most frames come from source 0x040. Climate frames 0x39A / 0x40A come from 0x099, 0x192 from 0x058, 0x1EB from
  0x060.
- The Data page labels (data/DataCatalog.kt:244-312) mostly show `(hdr >> 12) & 0xFFF`, which is twice the message
  id (gear "0x2CC" = msg 0x166). Trailer "0x132" and pitch "0x400" are true message ids. Steering is labelled 0x124
  but decodes 10240040 (msg 0x120); SOC is labelled 0x148 but decodes 10248040 (msg 0x124). Labels only; decoding is
  unaffected. [INFERRED]

## 3. Frame table

Layouts are borrowed from comma.ai opendbc `gm_global_a_lowspeed` (GM Global A low-speed). Bit fields are
Motorola / big-endian, start bit = MSB, then length. (SwCanSignals.kt:5-12)

| msg (header) | src | opendbc name | Field → decode | Code | Verified on the truck? |
|---|---|---|---|---|---|
| 0x166 (102CC040) | 040 | Engine_2 | byte2 PRNDL: CF P, CE R, CD N, C1 D/L/M. Also torque 51/12 ×0.5−848 N·m, fan 31/8 ×0.392 %, DFM 15/2 | SwCanBody.kt:215,247-254; SwCanSignals.kt:73-74,137-138 | Gear: YES, "verified stable across repeated controlled captures" (SwCanBody.kt:211) [OBSERVED on device]. Use the newest sample in each window (oldest-sample bug made P→R show P for 150-900 ms). Others: no |
| 0x115 (1022A040) | 040 | — | byte2: 00 released, A0 set | SwCanBody.kt:216,256-261 | PARTLY: live-diffed toggle 2026-07-19; steady engaged value still needs a clean capture (commit a28c26d). The old byte4 bit6 decode lit a phantom brake lamp |
| 0x110 (10220040) | 040 | ACC_YawRate | byte6 bit0 = turn lamp flashing (~1.3 Hz). Also yaw 35/12 signed ×0.0625 °/s, cruise set 3/12 ×0.0625 km/h, ACC active bit 6, FCA bit 23 | SwCanBody.kt:217,263-265; SwCanSignals.kt:58-62 | Turn: yes (original live work). Cruise/yaw: no ("contradicts old no-cruise note; verify live") |
| 0x132 (10264040) | 040 | Indications_Fast | byte6 high nibble: 00 2H, 10 4H, 20 4L. Also trailer connected bit14, wiring fault bit7, brake gain 31/8, brake force 23/8, fuel rate 51/12 ×0.025 L/h | SwCanBody.kt:9,218,267-273; SwCanSignals.kt:66-71 | Drivetrain: yes (2026-07-05 live work) [OBSERVED on device]. Trailer etc.: no |
| 0x168 (102D0040) | 040 | Engine_Information_4_LS | byte4 oil life ×100/255; tank capacity 19/12 ×0.125 L | SwCanBody.kt:219-220,275-276; SwCanSignals.kt:99 | Oil life: "dash-validated" [OBSERVED on device] |
| 0x360 (106C0040) | 040 | Vehicle_Odo_LS | bytes0-3 BE ×0.015625 km (divide by exactly 1.609344; ×0.621371 read a mile low) | SwCanBody.kt:221,277-285 | "validated exact vs the truck dash" [OBSERVED on device] |
| 0x3C0 (10780040) | 040 | HS_Indications_Slow_LS | byte6[6:0] ×0.703125−45 = roll; 4WD enum 42/3 (2WD/Auto/4H/4L); lamps: TPMS 2, brake fluid 7, pads 13, HDC 47, oil starvation 5 | SwCanBody.kt:222,286-287; SwCanSignals.kt:108-113,133-134 | Roll: "verified". Rest: no |
| 0x400 (0C800040 vs 10800040) | 040 | Fuel_Information | pitch 30/7 ×0.703125−45; fuel % 15/8 ×0.392157 | SwCanSignals.kt:124-126; SwCanBody.kt:110,223 | NO. Header conflict: the table reads priority-3 `0C800040`; SwCanBody declares an unused priority-4 `10800040`, and the handoff rule also gives 10800040. If the truck sends 10800040, body fuel % and pitch never decode |
| 0x106 (1020C040) | 040 | Lighting_Status_LS | b0 bits6-5 stalk (1 L, 2 R); b0 bit2 hazards; b3 nibbles lamp L/R; b2 bit1 reverse lamp; b1 bit7 brake lamp; b1 bit5 high beam | SwCanBody.kt:98,224,310-319 | "VALIDATED against our blinker captures": the turn fields only |
| 0x1EA (103D4040) | 040 | Tire_Pressure_Sensors_LS | LF b2, LR b3, RF b4, RR b5; psi = raw×0.5802 (kPa = raw×4); 0 = no reading; only while rolling | SwCanBody.kt:105,225,321-326,375-376 | Not recorded as complete (still behind a debug dump "for verifying TPMS/steering/gear") |
| 0x1DA (103B4040) | 040 | Man_Prk_Brk_LS | b0 bit0 rear locker, bit1 front | SwCanBody.kt:226,329-331 | NO |
| 0x318 / 0x17B / 0x17C / 0x17D / 0x394 (10630040 / 102F6040 / 102F8040 / 102FA040 / 10728040) | 040 | door / hood | b0 bit0 ajar: driver, passenger, rear-left, rear-right, hood | SwCanBody.kt:227-231,332-338 | NO (decoded, never shown) |
| 0x170 (102E0040) | 040 | Analog_Values_Slow | coolant 63/8−40; oil 47/8−40; trans 31/8−40; intake 55/8−40; OAT estimate 39/8 ×0.5−40; baro 23/8 ×0.5 kPa; oil pressure 15/8 ×4 kPa | SwCanSignals.kt:44-51 | Coolant: YES, 210 °F matched OBD (SwCanSignals.kt:7-8). Rest: no |
| 0x120 (10240040) | 040 | Vehicle_Stability | steering 39/16 signed ×0.0625°; lat accel 51/12 signed ×0.015625; long accel 1/10 signed ×0.03; TC bit3; ESC bit5 | SwCanSignals.kt:52-57 | NO |
| 0x224 (10448040) | 040 | Fuel_Level_Status | DTE 8/17 ×0.015625 km; low fuel bit0 | SwCanSignals.kt:63-65 | NO |
| 0x165 (102CA040) | 040 | Engine_1 | rpm 23/16 ×0.25; throttle 39/8; pedal 47/8 | SwCanSignals.kt:75-78 | NO |
| 0x124 (10248040) | 040 | Battery | volts 23/8 ×0.1+3; SOC 31/8 ×0.392; current 47/8 signed ×0.5 A | SwCanSignals.kt:79-82 | NO |
| 0x128 (10250040) | 040 | — | brake pedal 15/8 ×0.392 | SwCanSignals.kt:83-84 | NO |
| 0x167 (102CE040) | 040 | Engine_3 | rear e-locker torque 47/8 ×10; A/C pressure 23/8 ×14 kPa | SwCanSignals.kt:85-87 | NO |
| 0x39A (10734099) / 0x40A (10814099) | 099 | Climate | set temp 17/10 ×0.1−10 °C; blower 15/8 %; A/C bit5; defrost bit6 | SwCanSignals.kt:88-92 | NO (the verified HVAC path is the head unit's MCU cmd 0x03) |
| 0x35C (106B8040) | 040 | wheel speeds | LF 5/14, LR 21/14, RF 37/14, RR 53/14 ×0.03125 km/h | SwCanSignals.kt:93-97 | NO |
| 0x212 / 0x21D / 0x1EB (src 060) / 0x3C4 / 0x192 (src 058) | — | displayed OAT / efficiency + auto-hold / trip A,B / slow warning lamps / passenger occupancy | see code | SwCanSignals.kt:100-123 | NO |
| 0x121 (10242040) | 040 | ignition | bits 1..0: Off / Acc / Run / Crank | SwCanSignals.kt:130-131 | NO |

## 4. HS-CAN (ECM) PIDs

ISO 15765-4, 11-bit, 500 kbit/s; request 7DF/7E0, reply 7E8. PIDs polled: 01 04 05 06 07 0C 0D 0E 0F 10 11 1F 2F
33 3C 42 43 46 (standard J1979), plus modes 03 / 07 / 0A / 04 / 09 02. GM mode-22 DIDs (ECM 7E0 / TCM 7E2: 1940,
1154, 1470, 1951, 1920, …) are untested candidates from community lists. MIL/DTC framing is "pending truck
verification of the exact GM CAN framing" (BluetoothObdSource.kt:90-120,603-604; ~/cor-sim/elm.py:54-55,133-134;
~/acx-sim/docs/CORLINK-1.1-DRAFT.md:492-493). [FROM FILES we hold]

## 5. Simulator assumptions (not truck facts)

`~/cor-sim/elm.py` emulates this bus with exactly myCarplay's header ids and offsets (elm.py:237-258, builders
:269-450). Its frame periods are modelling choices, not measurements: 100 ms gear / engine / lighting / turn /
stability / wheels / drivetrain; 500 ms park brake / ignition / battery / analog; 1 s oil / roll / fuel-pitch /
range / OAT / odo / trip / locker / doors; 2 s TPMS; 5 s slow warnings. Other sim assumptions: 24 gal tank
(cluster-app's comment says 26 gal; neither is from the truck), 10L80 10-speed, 3.23 axle, 31.5 in tires, 4LO 2.72,
5,380 lb, 38 psi placard, reply strings `STN2255 v5.6.19` / `OBDLink MX+ r2.1`. Only the 5.3 L V8 matches recorded
truck facts. (~/cor-sim/README.md:95-97; elm.py:37-39,234-263,453-481) [FROM FILES we hold]
