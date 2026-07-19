# Reliable truck data for mycarplay — discovery workflow

Goal: figure out **which CAN signals correspond to which truck states** (doors,
blinkers, parking brake, brakes, lights…) so the mycarplay app can read them
reliably, then hand a precise signal map to the Mac APK-builder agent.

## Who does what

The bus lives in the truck, on the Android head unit. So the live capture must
run **there**, not in a cloud AI session. The roles:

| Role | Who | How |
|------|-----|-----|
| Read the bus, correlate actions → candidate signals | `can_discovery.py` on the head unit | you run it in the truck |
| Perform the physical actions | you | `truck-tasks.md` |
| Interpret findings, write app decode logic | the AI / Mac APK agent | consumes `findings.json` |

An AI in the cloud **cannot** read your bus and must never guess signal
addresses — a fabricated map flashed into a real truck is unsafe. The tool
produces evidence-based candidates with confidence scores instead.

## Steps

1. **On the head unit (Termux):**
   ```bash
   pip install python-can            # (cantools optional, for DBC decode)
   sudo ip link set can0 up type can bitrate 500000
   python can_discovery.py --rounds 3 --window 2.5
   ```
2. **Follow the prompts** using `truck-tasks.md` (truck parked, ignition on).
3. The tool writes **`findings.json`** and **`findings.md`** after every event.
4. **Hand off:**
   - Give `findings.json` to the Mac APK-builder agent. Its shape is defined in
     `findings.schema.json` — each signal has candidate `arbitration_id` +
     `byte`/`bit` + `confidence`.
   - Or paste `findings.md` back into a chat with the AI to co-write the decode
     logic.

## How to read a candidate

A `steady` candidate like:

```json
{ "type": "steady", "arbitration_id": 944, "id_hex": "0x3B0",
  "byte": 2, "bit": 4, "bit_mask": "0x10",
  "off_state": "const0", "on_state": "const1", "confidence": 1.0 }
```

means: on CAN ID `0x3B0`, **byte 2, bit 4** reads 0 when the action is OFF and 1
when ON, and it held across every repeat. The app decodes it as:

```
is_active = (frame.data[2] >> 4) & 1        # for ID 0x3B0
```

- `activity` = the bit *flashes* in one state (turn signals) — decode as "toggling".
- `presence` = a whole CAN ID only broadcasts in one state.
- **confidence 1.0** = trust it. **< 1.0** = re-run that event with more `--rounds`.

## Reliability tips (the "some things are off" problem)

- **Wrong bitrate/bus** is the #1 cause of flaky reads. If baseline shows 0
  frames or garbage, try `250000`, or you're on the wrong bus — trucks often
  have separate powertrain (high-speed) and body (low/mid-speed) buses.
- **Confirm each signal twice** on different days/temperatures; some values
  drift. The confidence score is per-session — re-running builds trust.
- Prefer **steady** signals over multi-byte encoded values for on/off states;
  they're the most robust for an app to poll.
