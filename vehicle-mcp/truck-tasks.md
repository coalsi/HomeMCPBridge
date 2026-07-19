# In-truck discovery checklist

Physical actions to run through with `can_discovery.py`. The tool prompts you
for each one — this sheet is so you know what's coming and can stage the truck
safely. Everything here is **read-only**; nothing is ever sent to the bus.

## Before you start (safety)

- [ ] Transmission in **Park**, **parking brake set** (except during the parking-brake test), wheels straight.
- [ ] Do this **stationary** — never while driving. Blinker/horn/brake tests are fine parked.
- [ ] Engine running (or ignition in RUN) so all modules are broadcasting. Some
      body signals only appear with ignition on.
- [ ] Bring the CAN interface up first (on the head unit):
      `sudo ip link set can0 up type can bitrate 500000`
      (If you see 0 frames in the baseline, try `250000`, or you may be on the
      wrong bus — many trucks have a separate low-speed body bus.)

## Run the tool

```bash
python can_discovery.py --rounds 3 --window 2.5
# or a focused subset:
python can_discovery.py --only door_driver left_blinker parking_brake
```

It does each event **3 times** (OFF then ON) and keeps only bits that flip
consistently. More rounds = higher confidence but longer.

## The action list (event keys in parentheses)

For each, the tool asks you to set the OFF state, then the ON state, a few times.

1. **Driver door** (`door_driver`) — close fully / open
2. **Passenger door** (`door_passenger`) — close fully / open
3. **Left turn signal** (`left_blinker`) — off / on and *let it keep flashing*
4. **Right turn signal** (`right_blinker`) — off / on, let it flash
5. **Hazards** (`hazards`) — off / on, let them flash
6. **Parking brake** (`parking_brake`) — released / set  *(chock wheels if unsure)*
7. **Brake pedal** (`brake_pedal`) — foot off / press and hold
8. **Headlights** (`headlights`) — off / low beam on
9. **High beams** (`high_beam`) — off / on
10. **Driver seatbelt** (`driver_seatbelt`) — unbuckled / buckled
11. **Ignition ACC vs RUN** (`ignition_acc`) — accessory / run
12. **Horn** (`horn`) — quiet / brief taps (repeat the taps during the ON window)

Tips:
- For flashing items (blinkers, hazards, horn), keep the action going through the
  whole ON capture window so the tool sees the "activity" pattern.
- If a signal comes back with no result, re-run just that one with more rounds:
  `python can_discovery.py --only left_blinker --rounds 5 --window 3.5`

## After

The tool writes `findings.json` (+ `findings.md`) after **every** event, so an
early stop still saves progress. Hand `findings.json` to the Mac APK-builder
agent, or paste `findings.md` back into chat and I'll turn it into decode logic
for mycarplay.
