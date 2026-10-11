#!/usr/bin/env python3
"""
frame_diff.py — differential signal discovery for ANY captured frame source (stdlib only)

Takes frame captures recorded in an OFF state and an ON state (several repeats
each), and reports which frame IDs / bytes / bits change CONSISTENTLY with the
action. Bits that vary on their own (counters, engine values, clocks) are
rejected because they fail to hold across repeats. Same method and output schema
as can_discovery.py, but reads capture FILES, so it works for sources that are
not SocketCAN:

  --format mcu      head-unit MCU frames `a5 2e <cmd> <len> <payload> <crc>` as
                    they appear in logcat (MCUDEC / MCUPROBE lines, or the vendor
                    console's `0xA5 0x2E ...` style). Frame "id" = the cmd byte.
  --format elm      STN/ELM327 monitor output with headers on (ATH1 ATS1):
                    `10 2C C0 40 CF 00 ...` (29-bit header as 4 bytes),
                    `102CC040 CF 00 ...`, or 11-bit `7E8 03 41 ...`.
  --format candump  can-utils `candump` lines (`can0  3B0   [4]  10 20 00 00`
                    or `(ts) can0 3B0#10200000`).
  --format hex      generic `ID DATA` per line: `0x3B0 10 20 00 00` / `3B0 10200000`.

Usage (one event):
  frame_diff.py --format mcu --event door_driver \
      --off off1.log --on on1.log --off off2.log --on on2.log --off off3.log --on on3.log

Usage (batch plan, JSON):
  frame_diff.py --format elm --plan plan.json
  plan.json = {"events":[{"key":"door_driver","name":"Driver door",
                          "off":["o1.log","o2.log"],"on":["n1.log","n2.log"]}, ...]}

Output: findings.json + findings.md (schema: findings.schema.json). Bit numbering:
byte index 0-based, bit 0 = LSB of the byte. The decoder reads
`(frame.data[byte] >> bit) & 1`.

Read-only by nature: this script never touches a device, it only reads files.
"""

import argparse
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# Analyzer (shared with can_discovery.py)
# ---------------------------------------------------------------------------

def bit_profile(frame_list):
    """Profile each bit of one ID's frames within one state.

    Returns ({bit_index: 'const0'|'const1'|'toggle'}, max_len).
    bit_index = byte*8 + bit, bit 0 = LSB of that byte.
    """
    if not frame_list:
        return {}, 0
    max_len = max(len(d) for d in frame_list)
    profile = {}
    for b in range(max_len):
        for bit in range(8):
            idx = b * 8 + bit
            ones = zeros = 0
            for d in frame_list:
                if len(d) > b:
                    if d[b] >> bit & 1:
                        ones += 1
                    else:
                        zeros += 1
            if ones and zeros:
                profile[idx] = "toggle"
            elif ones:
                profile[idx] = "const1"
            elif zeros:
                profile[idx] = "const0"
    return profile, max_len


def merge_profiles(profiles):
    """Pool per-round profiles: a bit is const only if it is the same const in every round."""
    merged = {}
    all_bits = set()
    for p in profiles:
        all_bits |= set(p.keys())
    for idx in all_bits:
        vals = {p.get(idx) for p in profiles if idx in p}
        if vals == {"const0"}:
            merged[idx] = "const0"
        elif vals == {"const1"}:
            merged[idx] = "const1"
        else:
            merged[idx] = "toggle"
    return merged


def analyze_event(off_rounds, on_rounds):
    """Compare OFF vs ON captures (lists of {id: [bytes, ...]}) -> candidate signals, strongest first."""
    off_ids = set().union(*[set(r) for r in off_rounds]) if off_rounds else set()
    on_ids = set().union(*[set(r) for r in on_rounds]) if on_rounds else set()
    candidates = []

    for arb in sorted(on_ids - off_ids):
        seen = sum(1 for r in on_rounds if arb in r)
        candidates.append({
            "type": "presence", "arbitration_id": arb, "id_hex": f"0x{arb:X}",
            "meaning": "ID present only in ON state",
            "confidence": round(seen / max(1, len(on_rounds)), 2),
        })
    for arb in sorted(off_ids - on_ids):
        seen = sum(1 for r in off_rounds if arb in r)
        candidates.append({
            "type": "presence", "arbitration_id": arb, "id_hex": f"0x{arb:X}",
            "meaning": "ID present only in OFF state",
            "confidence": round(seen / max(1, len(off_rounds)), 2),
        })

    for arb in sorted(off_ids & on_ids):
        off_prof = merge_profiles([bit_profile(r.get(arb, []))[0] for r in off_rounds])
        on_prof = merge_profiles([bit_profile(r.get(arb, []))[0] for r in on_rounds])
        for idx in sorted(set(off_prof) | set(on_prof)):
            o, n = off_prof.get(idx), on_prof.get(idx)
            if o is None or n is None or o == n:
                continue
            byte_i, bit_i = divmod(idx, 8)
            mask = 1 << bit_i
            rounds = min(len(off_rounds), len(on_rounds))
            support = 0
            for k in range(rounds):
                op = bit_profile(off_rounds[k].get(arb, []))[0].get(idx)
                np_ = bit_profile(on_rounds[k].get(arb, []))[0].get(idx)
                if op is not None and np_ is not None and op != np_:
                    support += 1
            ctype = "steady" if "toggle" not in (o, n) else "activity"
            candidates.append({
                "type": ctype, "arbitration_id": arb, "id_hex": f"0x{arb:X}",
                "byte": byte_i, "bit": bit_i, "bit_mask": f"0x{mask:02X}",
                "off_state": o, "on_state": n,
                "location": f"ID 0x{arb:X}, byte {byte_i}, bit {bit_i} (mask 0x{mask:02X})",
                "confidence": round(support / max(1, rounds), 2),
            })

    order = {"steady": 0, "activity": 1, "presence": 2}
    candidates.sort(key=lambda c: (-c["confidence"], order.get(c["type"], 3)))
    return candidates


def write_findings(path, meta, results):
    """Write findings.json and a sibling .md; returns the .md path."""
    with open(path, "w") as f:
        json.dump({"meta": meta, "signals": results}, f, indent=2)
    md_path = os.path.splitext(path)[0] + ".md"
    with open(md_path, "w") as f:
        f.write("# Differential discovery findings\n\n")
        for k, v in meta.items():
            f.write(f"- {k}: `{v}`\n")
        f.write("- Bit convention: byte index 0-based; bit 0 = LSB of the byte\n\n")
        for ev in results:
            f.write(f"## {ev['name']} (`{ev['key']}`)\n\n")
            if not ev["candidates"]:
                f.write("_No consistent signal found. Add rounds or check the capture source._\n\n")
                continue
            f.write("| conf | type | location | off → on |\n|------|------|----------|----------|\n")
            for c in ev["candidates"][:15]:
                loc = c.get("location", c.get("id_hex", ""))
                trans = (f"{c.get('off_state', '-')} → {c.get('on_state', '-')}"
                         if c["type"] != "presence" else c["meaning"])
                f.write(f"| {c['confidence']:.2f} | {c['type']} | {loc} | {trans} |\n")
            f.write("\n")
            hi = [c for c in ev["candidates"] if c["confidence"] >= 0.99]
            if hi:
                f.write(f"**Best guess:** `{hi[0].get('location', hi[0]['id_hex'])}`\n\n")
    return md_path


# ---------------------------------------------------------------------------
# Parsers: each turns a capture file into {id: [bytes, ...]}
# ---------------------------------------------------------------------------

_HEX_TOKEN = re.compile(r"(?:0x)?([0-9A-Fa-f]{2,8})\b")


def _hex_bytes_in_line(line):
    """All 2-hex-digit byte tokens in a line (accepts `a5`, `0xA5`, `A5`)."""
    out = []
    for tok in re.findall(r"(?:0x)?([0-9A-Fa-f]{2})(?![0-9A-Fa-f])", line):
        out.append(int(tok, 16))
    return out


def parse_mcu(text):
    """Extract `a5 2e cmd len payload crc` frames anywhere in logcat-style text."""
    frames = {}
    stats = {"frames": 0, "bad_crc": 0}
    for line in text.splitlines():
        b = _hex_bytes_in_line(line)
        i = 0
        while i + 3 < len(b):
            if b[i] == 0xA5 and b[i + 1] == 0x2E:
                cmd, ln = b[i + 2], b[i + 3]
                end = i + 4 + ln
                if end < len(b):
                    payload = bytes(b[i + 4:end])
                    crc = b[end]
                    calc = (sum([cmd, ln]) + sum(payload)) & 0xFF ^ 0xFF
                    if crc != calc:
                        stats["bad_crc"] += 1
                    frames.setdefault(cmd, []).append(payload)
                    stats["frames"] += 1
                    i = end + 1
                    continue
            i += 1
    return frames, stats


def parse_elm(text):
    """STN/ELM monitor lines with headers on. Returns {id: [data bytes]}."""
    frames = {}
    stats = {"frames": 0, "skipped": 0}
    for raw in text.splitlines():
        line = raw.replace(">", " ").strip()
        if not line or line.upper().startswith(("STOPPED", "BUFFER", "NO DATA", "SEARCHING", "OK", "ERROR", "AT", "ST")):
            continue
        toks = line.split()
        if not all(re.fullmatch(r"[0-9A-Fa-f]+", t) for t in toks):
            stats["skipped"] += 1
            continue
        try:
            if len(toks[0]) == 8:                     # 102CC040 CF 00 ...
                arb, data = int(toks[0], 16), toks[1:]
            elif len(toks[0]) == 3:                   # 7E8 03 41 ...
                arb, data = int(toks[0], 16), toks[1:]
            elif len(toks) >= 5 and all(len(t) == 2 for t in toks[:4]):  # 10 2C C0 40 CF ...
                arb, data = int("".join(toks[:4]), 16), toks[4:]
            else:
                stats["skipped"] += 1
                continue
            payload = bytes(int(t, 16) for t in data if len(t) == 2)
        except ValueError:
            stats["skipped"] += 1
            continue
        frames.setdefault(arb, []).append(payload)
        stats["frames"] += 1
    return frames, stats


def parse_candump(text):
    frames = {}
    stats = {"frames": 0, "skipped": 0}
    for line in text.splitlines():
        m = re.search(r"\b([0-9A-Fa-f]{3,8})#([0-9A-Fa-f]*)", line)          # log format
        if m:
            arb = int(m.group(1), 16)
            payload = bytes.fromhex(m.group(2)) if m.group(2) else b""
        else:
            m = re.search(r"\b([0-9A-Fa-f]{3,8})\s+\[\d+\]\s+((?:[0-9A-Fa-f]{2}\s*)*)", line)
            if not m:
                stats["skipped"] += 1
                continue
            arb = int(m.group(1), 16)
            payload = bytes(int(t, 16) for t in m.group(2).split())
        frames.setdefault(arb, []).append(payload)
        stats["frames"] += 1
    return frames, stats


def parse_hex(text):
    """Generic `ID DATA` lines."""
    frames = {}
    stats = {"frames": 0, "skipped": 0}
    for line in text.splitlines():
        toks = line.replace(",", " ").split()
        if not toks or toks[0].startswith("#"):
            continue
        try:
            arb = int(toks[0], 16)
            rest = "".join(t[2:] if t.lower().startswith("0x") else t for t in toks[1:])
            payload = bytes.fromhex(rest) if rest else b""
        except ValueError:
            stats["skipped"] += 1
            continue
        frames.setdefault(arb, []).append(payload)
        stats["frames"] += 1
    return frames, stats


PARSERS = {"mcu": parse_mcu, "elm": parse_elm, "candump": parse_candump, "hex": parse_hex}


def load_capture(path, fmt):
    with open(path, "r", errors="replace") as f:
        frames, stats = PARSERS[fmt](f.read())
    if not frames:
        print(f"warning: {path}: no frames parsed as format '{fmt}' ({stats})", file=sys.stderr)
    return frames


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Differential signal discovery from capture files")
    ap.add_argument("--format", required=True, choices=sorted(PARSERS))
    ap.add_argument("--event", help="event key for a single-event run (e.g. door_driver)")
    ap.add_argument("--name", help="human name for the event (default: the key)")
    ap.add_argument("--off", action="append", default=[], help="OFF-state capture file (repeatable)")
    ap.add_argument("--on", action="append", default=[], help="ON-state capture file (repeatable)")
    ap.add_argument("--plan", help="JSON batch plan: {events:[{key,name,off:[...],on:[...]}]}")
    ap.add_argument("--out", default="findings.json")
    args = ap.parse_args()

    events = []
    if args.plan:
        with open(args.plan) as f:
            events = json.load(f)["events"]
    elif args.event:
        events = [{"key": args.event, "name": args.name or args.event, "off": args.off, "on": args.on}]
    else:
        ap.error("give --event with --off/--on files, or --plan")

    results = []
    for ev in events:
        if not ev.get("off") or not ev.get("on"):
            print(f"skipping {ev.get('key')}: needs at least one --off and one --on file", file=sys.stderr)
            continue
        off_rounds = [load_capture(p, args.format) for p in ev["off"]]
        on_rounds = [load_capture(p, args.format) for p in ev["on"]]
        cands = analyze_event(off_rounds, on_rounds)
        results.append({"key": ev["key"], "name": ev.get("name", ev["key"]), "candidates": cands})
        top = cands[0] if cands else None
        where = top.get("location", top.get("id_hex")) if top else "no consistent signal"
        print(f"{ev['key']}: {len(ev['off'])}x off / {len(ev['on'])}x on -> {where}"
              + (f" (conf {top['confidence']})" if top else ""))

    meta = {"source_format": args.format,
            "note": "Differential analysis of capture files. Bit 0 = LSB. Confidence = fraction of rounds agreeing."}
    md = write_findings(args.out, meta, results)
    print(f"wrote {args.out} and {md}")


if __name__ == "__main__":
    main()
