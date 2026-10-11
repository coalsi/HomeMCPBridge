#!/usr/bin/env python3
"""
CAN Signal Discovery (READ-ONLY)

Interactive reverse-engineering helper that runs ON THE HEAD UNIT (Termux),
directly on the truck's CAN bus via SocketCAN. It guides you through physical
actions (open driver door, left blinker, parking brake, ...), captures the bus
in each state, correlates across repeats to reject noise, and writes a structured
findings file you can hand to the app builder (the Mac APK agent) or paste back
into a chat for interpretation.

Method (why it's trustworthy):
  For each signal we capture the bus in an OFF state and an ON state, several
  times. A candidate bit must behave CONSISTENTLY across every repeat:
    * steady   : constant=X in OFF, constant=Y in ON, X != Y   (e.g. door ajar)
    * activity : constant in one state, toggling in the other  (e.g. blinker flash)
    * presence : a CAN ID that only broadcasts in one state
  Bits that don't hold the pattern across repeats (engine values, clocks,
  counters) are discarded. Confidence = fraction of repeats that agreed.

SAFETY / READ-ONLY:
  This script only ever calls bus.recv(). It NEVER transmits on the bus. Perform
  all actions with the truck safely parked (transmission in Park, parking brake
  set when not the item under test, engine running or ignition on as needed).

Usage:
  python can_discovery.py                      # full default action set
  python can_discovery.py --only door_driver left_blinker parking_brake
  python can_discovery.py --rounds 4 --window 3.0 --channel can0
  python can_discovery.py --out findings.json  # default: findings.json (+ .md)
"""

import argparse
import json
import os
import sys
import time

try:
    import can  # python-can
except Exception as e:  # pragma: no cover
    print("python-can is required. Install with: pip install python-can\n"
          f"(import error: {e!r})", file=sys.stderr)
    sys.exit(1)

from frame_diff import analyze_event, write_findings  # shared analyzer (stdlib)

# ---------------------------------------------------------------------------
# Default catalog of actions to characterize. Each has an OFF state and an ON
# state, phrased as things you physically do in the truck. Edit freely, or pass
# --only to select a subset.
# ---------------------------------------------------------------------------
DEFAULT_EVENTS = [
    {"key": "door_driver",    "name": "Driver door",
     "off": "CLOSE the driver door fully",   "on": "OPEN the driver door"},
    {"key": "door_passenger", "name": "Passenger door",
     "off": "CLOSE the passenger door fully","on": "OPEN the passenger door"},
    {"key": "left_blinker",   "name": "Left turn signal",
     "off": "Turn signals OFF (stalk centered)", "on": "LEFT turn signal ON (let it flash)",
     "activity_expected": True},
    {"key": "right_blinker",  "name": "Right turn signal",
     "off": "Turn signals OFF (stalk centered)", "on": "RIGHT turn signal ON (let it flash)",
     "activity_expected": True},
    {"key": "hazards",        "name": "Hazard flashers",
     "off": "Hazards OFF", "on": "HAZARD flashers ON (let them flash)",
     "activity_expected": True},
    {"key": "parking_brake",  "name": "Parking brake",
     "off": "Parking brake RELEASED", "on": "Parking brake SET/ENGAGED"},
    {"key": "brake_pedal",    "name": "Brake pedal",
     "off": "Foot OFF the brake pedal", "on": "PRESS and HOLD the brake pedal"},
    {"key": "headlights",     "name": "Headlights",
     "off": "Headlights OFF", "on": "Headlights ON (low beam)"},
    {"key": "high_beam",      "name": "High beams",
     "off": "High beams OFF", "on": "HIGH beams ON"},
    {"key": "driver_seatbelt","name": "Driver seatbelt",
     "off": "Driver seatbelt UNBUCKLED", "on": "Driver seatbelt BUCKLED"},
    {"key": "ignition_acc",   "name": "Ignition ACC vs RUN",
     "off": "Key/ignition in ACCESSORY", "on": "Ignition in RUN (engine may be on)"},
    {"key": "horn",           "name": "Horn",
     "off": "Horn not pressed", "on": "PRESS the horn briefly (repeat the taps)",
     "activity_expected": True},
]


def open_bus(channel, interface):
    try:
        return can.Bus(channel=channel, interface=interface)
    except Exception as e:
        print(f"\nCould not open CAN interface '{channel}' via '{interface}': {e!r}\n"
              "Bring the bus up first, e.g.:\n"
              "  sudo ip link set can0 up type can bitrate 500000\n"
              "(500000 is common; some trucks use 250000 or a second bus.)",
              file=sys.stderr)
        sys.exit(2)


def capture(bus, window):
    """Listen for `window` seconds. Return {arb_id: [bytes,...frames]}."""
    frames = {}
    deadline = time.time() + window
    while time.time() < deadline:
        remaining = deadline - time.time()
        msg = bus.recv(timeout=max(0.0, min(remaining, 0.5)))
        if msg is None:
            continue
        frames.setdefault(msg.arbitration_id, []).append(bytes(msg.data))
    return frames





def prompt(msg):
    try:
        input(f"\n>>> {msg}\n    Press ENTER when ready (Ctrl-C to stop)... ")
    except (EOFError, KeyboardInterrupt):
        print("\nStopping. Findings written so far are saved.")
        raise SystemExit(0)



def main():
    ap = argparse.ArgumentParser(description="Read-only CAN signal discovery")
    ap.add_argument("--channel", default=os.environ.get("CAN_CHANNEL", "can0"))
    ap.add_argument("--interface", default=os.environ.get("CAN_INTERFACE", "socketcan"))
    ap.add_argument("--rounds", type=int, default=3, help="repeats per event (>=2)")
    ap.add_argument("--window", type=float, default=2.5, help="capture seconds per state")
    ap.add_argument("--only", nargs="*", help="event keys to run (default: all)")
    ap.add_argument("--out", default="findings.json")
    args = ap.parse_args()

    rounds = max(2, args.rounds)
    events = DEFAULT_EVENTS
    if args.only:
        wanted = set(args.only)
        events = [e for e in DEFAULT_EVENTS if e["key"] in wanted]
        missing = wanted - {e["key"] for e in events}
        if missing:
            print(f"Unknown event keys: {sorted(missing)}", file=sys.stderr)
            print(f"Available: {[e['key'] for e in DEFAULT_EVENTS]}", file=sys.stderr)
            sys.exit(2)

    bus = open_bus(args.channel, args.interface)
    meta = {"channel": args.channel, "interface": args.interface,
            "rounds": rounds, "window": args.window,
            "note": "Read-only differential CAN discovery. Bit 0 = LSB."}
    results = []

    print("=" * 64)
    print("CAN SIGNAL DISCOVERY — read-only")
    print("Keep the truck safely PARKED. This only listens; it never sends.")
    print(f"Bus: {args.channel} | {rounds} rounds/event | {args.window}s window")
    print("=" * 64)

    # Optional baseline survey so you can see the bus is alive.
    prompt("Leave everything at rest. We'll sample the resting bus first.")
    base = capture(bus, args.window)
    print(f"    Baseline: {len(base)} active CAN IDs, "
          f"{sum(len(v) for v in base.values())} frames.")
    if not base:
        print("    WARNING: no frames seen. Wrong channel or bitrate? "
              "Check `ip -details link show` and try 250000/500000.")

    try:
        for ev in events:
            print("\n" + "-" * 64)
            print(f"EVENT: {ev['name']}")
            off_rounds, on_rounds = [], []
            for k in range(rounds):
                prompt(f"[{ev['name']}] Round {k+1}/{rounds}: {ev['off']}")
                off_rounds.append(capture(bus, args.window))
                prompt(f"[{ev['name']}] Round {k+1}/{rounds}: {ev['on']}")
                on_rounds.append(capture(bus, args.window))
            cands = analyze_event(off_rounds, on_rounds)
            results.append({"key": ev["key"], "name": ev["name"],
                            "candidates": cands})
            top = cands[0] if cands else None
            if top:
                loc = top.get("location", top.get("id_hex"))
                print(f"    -> best candidate: {loc}  "
                      f"(type={top['type']}, conf={top['confidence']})")
            else:
                print("    -> no consistent signal found this pass.")
            # Save after every event so nothing is lost.
            md = write_findings(args.out, meta, results)
    finally:
        bus.shutdown()

    print("\n" + "=" * 64)
    print(f"Done. Wrote {args.out} and {os.path.splitext(args.out)[0]}.md")
    print("Hand either file to the APK builder agent, or paste it back to the AI"
          "\nfor interpretation and app-decode logic.")
    print("=" * 64)


if __name__ == "__main__":
    main()
