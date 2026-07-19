# Vehicle MCP Bridge (read-only)

Exposes your vehicle's **OBD-II** and **CAN bus** data to any MCP client — for
example a Claude client running inside the `mycarplay` launcher on an Android
head unit. It is the bridge between the car's data buses and the AI: the AI can
**observe** the vehicle, and by design **cannot command it**.

```
   OBDLink MX+ (Bluetooth ELM327) ─┐
                                    ├─►  vehicle_mcp.py  ──(MCP/stdio)──►  Claude / any MCP client
   Direct CAN tap (SocketCAN can0) ─┘        (read-only)
```

## Why it's structured this way

You installed a Claude client *on the head unit*, but an LLM has no native way to
read a CAN frame. MCP is the standard glue: a small local **server** reads the
buses and publishes **tools**; the AI **client** calls those tools. This repo is
the server. It runs on the head unit (or any Linux device wired to the bus), not
in the cloud.

## Safety boundary — read only

This server exposes **no** tool that writes to the vehicle bus:

- No "clear DTC", no OBD actuation (mode 08), no arbitrary CAN transmit.
- The CAN bus object is only ever `recv`'d from, never `send`'d to.

That is intentional. Reading diagnostic data is safe; sending frames to a moving
car is not. Keep it read-only.

## Tools

| Tool | What it returns |
|------|-----------------|
| `obd_status` | Adapter connection, port, negotiated OBD protocol |
| `obd_list_supported` | Every PID this specific vehicle reports as supported |
| `obd_read` | Current value of one or more named PIDs |
| `obd_snapshot` | Curated live readout (RPM, speed, temps, load, fuel, voltage…) |
| `obd_dtcs` | Stored / current diagnostic trouble codes (read only) |
| `obd_freeze_frame_dtcs` | DTCs captured in freeze-frame data |
| `obd_vehicle_info` | VIN, ECU name, fuel type (OBD mode 09) |
| `can_status` | Whether `can0` opens; DBC decoding availability |
| `can_capture` | Passively capture CAN frames for a short window |
| `can_list_ids` | Survey which CAN IDs are active and how often |

## Install (Termux on the Android head unit)

```bash
pkg update && pkg install python
pip install -r requirements.txt
```

Then verify dependencies and hardware without starting MCP:

```bash
python vehicle_mcp.py selftest
```

### OBDLink MX+ (Bluetooth)

python-OBD talks to the adapter over a serial port. On Linux you bind the paired
adapter to an rfcomm port:

```bash
# find the adapter's MAC, then:
sudo rfcomm bind /dev/rfcomm0 <OBDLINK_MAC> 1
export OBD_PORT=/dev/rfcomm0
```

On Android, Bluetooth-serial access is restricted; a rooted head unit or a
USB/serial OBD path is the reliable route. If you leave `OBD_PORT` unset,
python-OBD will try to auto-detect a serial adapter.

### Direct CAN tap (SocketCAN)

Bring the interface up at the vehicle's bus speed (commonly 500 kbit/s) before
starting the server. This needs a Linux layer with SocketCAN and root:

```bash
sudo ip link set can0 up type can bitrate 500000
export CAN_CHANNEL=can0
```

Optionally point `CAN_DBC` at a `.dbc` file to get decoded signal names instead
of raw bytes:

```bash
export CAN_DBC=/path/to/your_vehicle.dbc
```

## Connect an MCP client

Copy a server block from `mcp.json.example` into your MCP client's config,
adjusting the path and env vars. For a client that launches the server itself,
stdio (the default) is all you need. For a networked client, start the server
with an HTTP transport instead by editing the last line of `vehicle_mcp.py`
(`mcp.run(transport="streamable-http")`) — see the MCP SDK docs.

## Configuration reference

| Env var | Default | Meaning |
|---------|---------|---------|
| `OBD_PORT` | auto-detect | Serial/BT port of the OBD adapter (e.g. `/dev/rfcomm0`) |
| `OBD_BAUDRATE` | auto | Adapter baud rate |
| `OBD_TIMEOUT` | `1.0` | Per-query timeout, seconds |
| `CAN_CHANNEL` | `can0` | SocketCAN interface name |
| `CAN_INTERFACE` | `socketcan` | python-can backend |
| `CAN_DBC` | *(none)* | Optional `.dbc` file for decoding CAN frames |

## Scope note

This covers the two buses you have (OBDLink MX+ over OBD-II, plus the direct CAN
tap). It does **not** touch Android system data the launcher itself sees (GPS,
media, phone) — that would be a separate MCP server against Android APIs, and is
a good next step if you want it.
