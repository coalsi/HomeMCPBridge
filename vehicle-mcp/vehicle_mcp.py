#!/usr/bin/env python3
"""
Vehicle MCP Bridge  (READ-ONLY)

Exposes a vehicle's OBD-II and CAN bus data to any MCP client (e.g. a Claude
client running inside the mycarplay launcher on an Android head unit).

Two data sources, both read-only:
  * OBD-II  -- via an ELM327-compatible adapter (e.g. OBDLink MX+) using python-OBD
  * CAN bus -- via SocketCAN (direct wired tap) using python-can

DESIGN CONTRACT -- READ ONLY:
  This server intentionally exposes NO tool that writes to the vehicle bus.
  There is no "clear DTC", no OBD mode-08 actuation, and the CAN bus object is
  never sent to (`bus.send` is not called anywhere). This is a deliberate safety
  boundary: an AI must be able to *observe* the car, never *command* it.
  Please keep it that way.

Configuration (all via environment variables, all optional):
  OBD_PORT        Serial/BT port for the OBD adapter (e.g. /dev/rfcomm0).
                  If unset, python-OBD attempts auto-detection.
  OBD_BAUDRATE    Adapter baud rate (int). Auto-negotiated if unset.
  OBD_TIMEOUT     Per-query timeout in seconds (default 1.0).
  CAN_CHANNEL     SocketCAN interface name (default: can0).
  CAN_INTERFACE   python-can interface backend (default: socketcan).
  CAN_DBC         Optional path to a .dbc file for decoding CAN frames.

Run:
  python vehicle_mcp.py            # start the MCP server on stdio
  python vehicle_mcp.py selftest   # check deps + hardware, no MCP
"""

import os
import sys
import time

# ---------------------------------------------------------------------------
# Optional dependencies are imported lazily so the server still starts (and
# reports a helpful message) on a head unit where a library or adapter is not
# yet present.
# ---------------------------------------------------------------------------
try:
    import obd  # python-OBD
    _OBD_IMPORT_ERROR = None
except Exception as e:  # pragma: no cover - env dependent
    obd = None
    _OBD_IMPORT_ERROR = repr(e)

try:
    import can  # python-can
    _CAN_IMPORT_ERROR = None
except Exception as e:  # pragma: no cover - env dependent
    can = None
    _CAN_IMPORT_ERROR = repr(e)

try:
    import cantools  # optional, only for DBC decoding
    _CANTOOLS_IMPORT_ERROR = None
except Exception as e:  # pragma: no cover - env dependent
    cantools = None
    _CANTOOLS_IMPORT_ERROR = repr(e)

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("vehicle-mcp")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
OBD_PORT = os.environ.get("OBD_PORT") or None
OBD_BAUDRATE = os.environ.get("OBD_BAUDRATE")
OBD_BAUDRATE = int(OBD_BAUDRATE) if OBD_BAUDRATE else None
OBD_TIMEOUT = float(os.environ.get("OBD_TIMEOUT", "1.0"))

CAN_CHANNEL = os.environ.get("CAN_CHANNEL", "can0")
CAN_INTERFACE = os.environ.get("CAN_INTERFACE", "socketcan")
CAN_DBC = os.environ.get("CAN_DBC") or None

# A curated set of common, broadly-supported live PIDs used by obd_snapshot.
# Only the ones the connected vehicle actually reports are queried.
_SNAPSHOT_PIDS = [
    "RPM", "SPEED", "ENGINE_LOAD", "COOLANT_TEMP", "THROTTLE_POS",
    "INTAKE_TEMP", "MAF", "FUEL_LEVEL", "CONTROL_MODULE_VOLTAGE",
    "AMBIANT_AIR_TEMP", "FUEL_RATE", "RUN_TIME", "DISTANCE_W_MIL",
    "BAROMETRIC_PRESSURE", "INTAKE_PRESSURE", "TIMING_ADVANCE",
]

# ---------------------------------------------------------------------------
# OBD connection management (lazily connected, cached)
# ---------------------------------------------------------------------------
_obd_conn = None


def _obd_connection():
    """Return a live python-OBD connection, connecting on first use.

    Raises RuntimeError with an actionable message if python-OBD is missing or
    the adapter cannot be reached.
    """
    global _obd_conn
    if obd is None:
        raise RuntimeError(
            "python-OBD is not installed. Install with: pip install obd "
            f"(import error: {_OBD_IMPORT_ERROR})"
        )
    if _obd_conn is not None and _obd_conn.is_connected():
        return _obd_conn

    kwargs = {"fast": False, "timeout": OBD_TIMEOUT}
    if OBD_PORT:
        kwargs["portstr"] = OBD_PORT
    if OBD_BAUDRATE:
        kwargs["baudrate"] = OBD_BAUDRATE

    _obd_conn = obd.OBD(**kwargs)
    if not _obd_conn.is_connected():
        status = _obd_conn.status()
        raise RuntimeError(
            f"Could not connect to OBD adapter (status: {status}). "
            f"Checked port: {OBD_PORT or 'auto-detect'}. "
            "Verify the OBDLink MX+ is paired/bound (e.g. /dev/rfcomm0) and the "
            "ignition is on."
        )
    return _obd_conn


def _fmt_value(v):
    """Format a python-OBD response value (often a Pint quantity) for JSON."""
    if v is None:
        return None
    # Pint Quantity has magnitude + units
    magnitude = getattr(v, "magnitude", None)
    units = getattr(v, "units", None)
    if magnitude is not None and units is not None:
        return {"value": _safe_number(magnitude), "unit": str(units)}
    # DTC lists, strings, bytearrays, etc.
    if isinstance(v, (bytes, bytearray)):
        return v.hex()
    return {"value": _coerce(v)}


def _safe_number(m):
    try:
        f = float(m)
        return int(f) if f.is_integer() else round(f, 4)
    except (TypeError, ValueError):
        return str(m)


def _coerce(v):
    if isinstance(v, (list, tuple)):
        return [_coerce(x) for x in v]
    if isinstance(v, (str, int, float, bool)) or v is None:
        return v
    return str(v)


def _command_by_name(name):
    """Look up an OBDCommand by name, or None if this build/vehicle lacks it."""
    try:
        return obd.commands[name]
    except Exception:
        return getattr(obd.commands, name, None)


# ---------------------------------------------------------------------------
# OBD-II tools (read-only)
# ---------------------------------------------------------------------------
@mcp.tool()
def obd_status() -> dict:
    """Report OBD-II adapter connection status, port, and negotiated protocol.

    Call this first to confirm the OBDLink MX+ (or other ELM327 adapter) is
    reachable before reading data. Does not require the engine to be running,
    only the ignition/accessory power on so the ECU responds.
    """
    if obd is None:
        return {
            "connected": False,
            "error": "python-OBD not installed",
            "hint": "pip install obd",
            "import_error": _OBD_IMPORT_ERROR,
        }
    try:
        conn = _obd_connection()
    except RuntimeError as e:
        return {"connected": False, "error": str(e)}
    return {
        "connected": conn.is_connected(),
        "status": str(conn.status()),
        "port": conn.port_name(),
        "protocol_id": conn.protocol_id(),
        "protocol_name": conn.protocol_name(),
        "supported_command_count": len(conn.supported_commands),
    }


@mcp.tool()
def obd_list_supported() -> dict:
    """List every OBD-II command the connected vehicle reports as supported.

    Returns each command's name (usable with obd_read), human description, mode,
    and PID. Use this to discover exactly what live data this specific vehicle
    exposes before calling obd_read.
    """
    conn = _obd_connection()
    cmds = []
    for c in sorted(conn.supported_commands, key=lambda x: (x.mode, x.pid or 0)):
        cmds.append({
            "name": c.name,
            "description": c.desc,
            "mode": c.mode,
            "pid": c.pid,
        })
    return {"count": len(cmds), "commands": cmds}


@mcp.tool()
def obd_read(pids: list[str]) -> dict:
    """Read one or more OBD-II PIDs by name and return their current values.

    Args:
        pids: PID names to read, e.g. ["RPM", "SPEED", "COOLANT_TEMP"].
              Use obd_list_supported to see valid names for this vehicle.

    Returns a mapping of PID name -> {value, unit} (or an error/null note when a
    PID is unsupported or the ECU returned no data). Read-only.
    """
    conn = _obd_connection()
    out = {}
    for name in pids:
        cmd = _command_by_name(name)
        if cmd is None:
            out[name] = {"error": "unknown PID name for this python-OBD build"}
            continue
        if cmd not in conn.supported_commands:
            out[name] = {"error": "not supported by this vehicle"}
            continue
        resp = conn.query(cmd)
        if resp.is_null():
            out[name] = {"value": None, "note": "no data returned by ECU"}
        else:
            out[name] = _fmt_value(resp.value)
    return out


@mcp.tool()
def obd_snapshot() -> dict:
    """Read a curated set of common live engine/vehicle values in one call.

    Queries only the PIDs this vehicle supports out of a standard set (RPM,
    speed, load, temperatures, throttle, fuel level, module voltage, etc.).
    Convenient for a quick "what is the car doing right now" readout. Read-only.
    """
    conn = _obd_connection()
    supported = conn.supported_commands
    out = {}
    for name in _SNAPSHOT_PIDS:
        cmd = _command_by_name(name)
        if cmd is None or cmd not in supported:
            continue
        resp = conn.query(cmd)
        out[name] = None if resp.is_null() else _fmt_value(resp.value)
    return {"read_pids": list(out.keys()), "values": out}


@mcp.tool()
def obd_dtcs() -> dict:
    """Read stored Diagnostic Trouble Codes (check-engine codes) from the ECU.

    Returns confirmed/stored DTCs as {code, description} pairs. This is a read
    operation only -- it never clears codes. Use obd_freeze_frame_dtcs for the
    codes captured in freeze-frame data.
    """
    conn = _obd_connection()
    result = {}
    for cmd_name, key in (("GET_DTC", "stored"), ("GET_CURRENT_DTC", "current")):
        cmd = _command_by_name(cmd_name)
        if cmd is None or cmd not in conn.supported_commands:
            continue
        resp = conn.query(cmd)
        if resp.is_null():
            result[key] = []
        else:
            result[key] = [
                {"code": code, "description": desc} for code, desc in resp.value
            ]
    return result or {"stored": [], "note": "no DTC command supported/returned"}


@mcp.tool()
def obd_freeze_frame_dtcs() -> dict:
    """Read the DTC(s) associated with freeze-frame data, if the vehicle stores any."""
    conn = _obd_connection()
    cmd = _command_by_name("GET_FREEZE_DTC")
    if cmd is None or cmd not in conn.supported_commands:
        return {"freeze_frame_dtcs": [], "note": "not supported by this vehicle"}
    resp = conn.query(cmd)
    if resp.is_null():
        return {"freeze_frame_dtcs": []}
    return {
        "freeze_frame_dtcs": [
            {"code": code, "description": desc} for code, desc in resp.value
        ]
    }


@mcp.tool()
def obd_vehicle_info() -> dict:
    """Read static vehicle info: VIN, ECU name, and fuel type where available (OBD mode 09)."""
    conn = _obd_connection()
    info = {}
    for name in ("VIN", "ECU_NAME", "FUEL_TYPE"):
        cmd = _command_by_name(name)
        if cmd is None or cmd not in conn.supported_commands:
            continue
        resp = conn.query(cmd)
        info[name] = None if resp.is_null() else _coerce(_unwrap(resp.value))
    return info or {"note": "no mode-09 info commands supported by this vehicle"}


def _unwrap(v):
    magnitude = getattr(v, "magnitude", None)
    if magnitude is not None:
        return _safe_number(magnitude)
    if isinstance(v, (bytes, bytearray)):
        try:
            return v.decode("ascii", "ignore").strip()
        except Exception:
            return v.hex()
    return v


# ---------------------------------------------------------------------------
# CAN bus tools (read-only, SocketCAN)
# ---------------------------------------------------------------------------
_dbc_db = None
_dbc_error = None


def _load_dbc():
    global _dbc_db, _dbc_error
    if _dbc_db is not None or _dbc_error is not None:
        return _dbc_db
    if not CAN_DBC:
        return None
    if cantools is None:
        _dbc_error = f"cantools not installed ({_CANTOOLS_IMPORT_ERROR})"
        return None
    try:
        _dbc_db = cantools.database.load_file(CAN_DBC)
    except Exception as e:
        _dbc_error = f"failed to load DBC {CAN_DBC}: {e!r}"
    return _dbc_db


def _open_can_bus():
    if can is None:
        raise RuntimeError(
            "python-can is not installed. Install with: pip install python-can "
            f"(import error: {_CAN_IMPORT_ERROR})"
        )
    try:
        return can.Bus(channel=CAN_CHANNEL, interface=CAN_INTERFACE)
    except Exception as e:
        raise RuntimeError(
            f"Could not open CAN interface '{CAN_CHANNEL}' via '{CAN_INTERFACE}': {e!r}. "
            "On Linux, bring the interface up first, e.g.: "
            "sudo ip link set can0 up type can bitrate 500000"
        )


def _decode_frame(arb_id, data):
    db = _load_dbc()
    if db is None:
        return None
    try:
        return _coerce(db.decode_message(arb_id, bytes(data)))
    except Exception:
        return None


@mcp.tool()
def can_status() -> dict:
    """Report whether the SocketCAN interface can be opened and DBC decoding availability.

    Confirms the direct-wired CAN tap (default interface: can0) is up and
    readable before capturing frames. Read-only.
    """
    if can is None:
        return {
            "available": False,
            "error": "python-can not installed",
            "hint": "pip install python-can",
            "import_error": _CAN_IMPORT_ERROR,
        }
    status = {
        "channel": CAN_CHANNEL,
        "interface": CAN_INTERFACE,
        "dbc_configured": bool(CAN_DBC),
    }
    try:
        bus = _open_can_bus()
        bus.shutdown()
        status["available"] = True
    except RuntimeError as e:
        status["available"] = False
        status["error"] = str(e)
    if CAN_DBC:
        db = _load_dbc()
        status["dbc_loaded"] = db is not None
        if _dbc_error:
            status["dbc_error"] = _dbc_error
        elif db is not None:
            status["dbc_message_count"] = len(db.messages)
    return status


@mcp.tool()
def can_capture(duration_seconds: float = 2.0, max_frames: int = 200,
                arbitration_id: int | None = None, decode: bool = True) -> dict:
    """Passively capture CAN frames from the bus for a short window.

    Args:
        duration_seconds: How long to listen (capped at 15s to stay responsive).
        max_frames: Stop after this many frames (capped at 2000).
        arbitration_id: If set, only return frames with this CAN ID (int).
        decode: If a DBC file is configured (CAN_DBC), attach decoded signals.

    Returns captured frames as {id, id_hex, extended, dlc, data, timestamp,
    decoded?}. This only *listens* -- it never transmits onto the bus.
    """
    duration_seconds = max(0.1, min(float(duration_seconds), 15.0))
    max_frames = max(1, min(int(max_frames), 2000))
    bus = _open_can_bus()
    frames = []
    deadline = time.time() + duration_seconds
    try:
        while time.time() < deadline and len(frames) < max_frames:
            remaining = deadline - time.time()
            msg = bus.recv(timeout=max(0.0, min(remaining, 1.0)))
            if msg is None:
                continue
            if arbitration_id is not None and msg.arbitration_id != arbitration_id:
                continue
            frame = {
                "id": msg.arbitration_id,
                "id_hex": f"0x{msg.arbitration_id:X}",
                "extended": bool(msg.is_extended_id),
                "dlc": msg.dlc,
                "data": bytes(msg.data).hex(),
                "timestamp": msg.timestamp,
            }
            if decode:
                decoded = _decode_frame(msg.arbitration_id, msg.data)
                if decoded is not None:
                    frame["decoded"] = decoded
            frames.append(frame)
    finally:
        bus.shutdown()
    return {"count": len(frames), "duration_seconds": duration_seconds, "frames": frames}


@mcp.tool()
def can_list_ids(duration_seconds: float = 3.0) -> dict:
    """Survey which CAN arbitration IDs are active on the bus and how often they appear.

    Listens for a short window and returns each observed CAN ID with its frame
    count and last-seen payload -- a quick map of what traffic is present.
    Read-only.
    """
    duration_seconds = max(0.1, min(float(duration_seconds), 15.0))
    bus = _open_can_bus()
    seen = {}
    deadline = time.time() + duration_seconds
    try:
        while time.time() < deadline:
            remaining = deadline - time.time()
            msg = bus.recv(timeout=max(0.0, min(remaining, 1.0)))
            if msg is None:
                continue
            key = msg.arbitration_id
            entry = seen.get(key)
            if entry is None:
                seen[key] = {
                    "id": key,
                    "id_hex": f"0x{key:X}",
                    "extended": bool(msg.is_extended_id),
                    "count": 1,
                    "last_data": bytes(msg.data).hex(),
                }
            else:
                entry["count"] += 1
                entry["last_data"] = bytes(msg.data).hex()
    finally:
        bus.shutdown()
    ids = sorted(seen.values(), key=lambda e: -e["count"])
    return {"unique_ids": len(ids), "duration_seconds": duration_seconds, "ids": ids}


# ---------------------------------------------------------------------------
# Self-test (no MCP): quick dependency + hardware check for the head unit.
# ---------------------------------------------------------------------------
def _selftest():
    print("Vehicle MCP Bridge -- self test\n")
    print(f"python-OBD  installed: {obd is not None}"
          + ("" if obd else f"   ({_OBD_IMPORT_ERROR})"))
    print(f"python-can  installed: {can is not None}"
          + ("" if can else f"   ({_CAN_IMPORT_ERROR})"))
    print(f"cantools    installed: {cantools is not None}"
          + ("" if cantools else f"   ({_CANTOOLS_IMPORT_ERROR})"))
    print()
    print(f"OBD_PORT     = {OBD_PORT or 'auto-detect'}")
    print(f"CAN_CHANNEL  = {CAN_CHANNEL} (interface={CAN_INTERFACE})")
    print(f"CAN_DBC      = {CAN_DBC or '(none)'}")
    print()
    if obd is not None:
        try:
            print("OBD status:", obd_status())
        except Exception as e:
            print("OBD status error:", repr(e))
    if can is not None:
        try:
            print("CAN status:", can_status())
        except Exception as e:
            print("CAN status error:", repr(e))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        _selftest()
    else:
        mcp.run()
