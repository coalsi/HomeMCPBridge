# HomeMCPBridge

Native macOS HomeKit integration for AI assistants via the Model Context Protocol (MCP).

**Control your entire smart home with natural language** - no Homebridge, no Home Assistant, no cloud services. Just direct HomeKit access.

## What is this?

HomeMCPBridge is a macOS app that lets AI assistants (Claude, and others that support MCP) control your HomeKit devices directly. Ask your AI to "turn off the living room lights" or "set the bedroom to 50% brightness" and it just works.

## Features

- **Native HomeKit** - Direct access to Apple's HomeKit framework, no bridges or hacks
- **MCP Protocol** - Works with Claude Code, Claude Desktop, and any MCP-compatible AI
- **All Device Types** - Lights, switches, outlets, fans, locks, garage doors, thermostats
- **Full Control** - On/off, brightness, color (hue/saturation), lock/unlock, open/close
- **Menu Bar App** - Runs quietly in the background with a status window
- **Plugin System** - Extend with Govee, Scrypted NVR, and more
- **Device Linking** - Link HomeKit devices with plugin counterparts to avoid duplicates
- **MCPPost** - Broadcast real-time sensor events to your AI system
- **Camera Snapshots** - Capture images from HomeKit and Scrypted cameras
- **Motion Events** - Monitor motion sensors, doorbells, and contact sensors

## Requirements

- macOS 14.0 (Sonoma) or later
- HomeKit-enabled devices configured in the Apple Home app
- An MCP-compatible AI assistant (Claude Code, Claude Desktop, etc.)

## Installation

### Option 1: Download Release
Download the latest `.dmg` from the [Releases](https://github.com/coalsi/HomeMCPBridge/releases) page.

### Option 2: Build from Source

1. Clone this repo:
   ```bash
   git clone https://github.com/coalsi/HomeMCPBridge.git
   cd HomeMCPBridge
   ```

2. Open in Xcode:
   ```bash
   open HomeMCPBridge.xcodeproj
   ```

3. Select your development team in Signing & Capabilities

4. Build and run (Cmd+R) - select "My Mac (Mac Catalyst)"

5. Grant HomeKit access when prompted

## Configuration

Add this to your MCP configuration file:

**For Claude Code** (`.mcp.json` in your project or `~/.claude/mcp.json`):
```json
{
  "mcpServers": {
    "homekit": {
      "command": "/Applications/HomeMCPBridge.app/Contents/MacOS/HomeMCPBridge",
      "args": []
    }
  }
}
```

**For Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "homekit": {
      "command": "/Applications/HomeMCPBridge.app/Contents/MacOS/HomeMCPBridge",
      "args": []
    }
  }
}
```

## Usage

Once configured, you can ask your AI things like:

- "List all my HomeKit devices"
- "Turn on the kitchen lights"
- "Set the living room lamp to 50% brightness"
- "What's the temperature in the garage?"
- "Turn off all the backyard lights"
- "Lock the front door"
- "Is the garage door open?"
- "Capture a snapshot from the front door camera"
- "Is there motion in the backyard?"

## Available MCP Tools

### Device Control
| Tool | Description |
|------|-------------|
| `list_devices` | List all devices from HomeKit and plugins |
| `list_rooms` | List all rooms in all homes |
| `list_homes` | List all configured HomeKit homes |
| `get_device_state` | Get current state of a device |
| `control_device` | Control a device (on, off, toggle, brightness, color, lock, unlock, open, close) |

### Cameras
| Tool | Description |
|------|-------------|
| `list_cameras` | List all HomeKit cameras |
| `capture_snapshot` | Capture image from camera (returns base64) |

### Motion & Events
| Tool | Description |
|------|-------------|
| `list_motion_sensors` | List motion sensors, occupancy sensors, doorbells |
| `get_motion_state` | Get current motion detection state |
| `subscribe_events` | Enable motion and contact event buffering |
| `get_pending_events` | Poll for buffered motion/doorbell/contact events |

### Scrypted NVR (requires configuration)
| Tool | Description |
|------|-------------|
| `scrypted_list_cameras` | List all Scrypted cameras with capabilities |
| `scrypted_capture_snapshot` | Capture snapshot from Scrypted camera |
| `scrypted_get_camera_state` | Get camera state including motion detection |
| `scrypted_set_webhook_token` | Configure webhook token for a camera |

## Supported Device Types

- **Lights** - On/off, brightness, color (hue/saturation)
- **Switches** - On/off
- **Outlets** - On/off
- **Fans** - On/off
- **Locks** - Lock/unlock
- **Garage Doors** - Open/close
- **Thermostats** - Read temperature (control coming soon)
- **Sensors** - Read values
- **Cameras** - Capture snapshots
- **Motion Sensors** - Detect motion/occupancy
- **Contact Sensors** - Door/window open/close

---

## App Tabs

### Status
Overview of your smart home setup:
- Apple HomeKit device count
- Plugin status and device counts
- Device link count
- App settings (menu bar, dock icon)

### Devices
Browse all devices organized by room:
- Tap (i) to link/unlink devices
- Shows device source (HomeKit, Govee, etc.)
- Indicates linked devices

### Plugins
Configure third-party integrations:
- Govee - Smart lights and appliances
- Scrypted NVR - Network video recorder cameras

### MCPPost
Broadcast real-time sensor events to your AI:
- Configure webhook endpoint URL
- Enable/disable event broadcasting
- View recent events and their status
- Test endpoint connectivity

### Setup
Complete setup guide with:
- MCP configuration snippets
- Plugin setup instructions (Govee, Scrypted)
- MCPPost configuration
- Device linking guide

### Log
Full activity log for debugging:
- All MCP tool calls
- Plugin activity
- Event notifications
- Clear and scroll controls

---

## Device Linking

When you have the same device in both HomeKit and a plugin (like Govee), you can link them so they're treated as one device:

1. Go to the **Devices** tab
2. Tap the **(i)** button on any device
3. Select **"Link Device..."**
4. Choose the corresponding device from another source

Linked devices use the most capable source automatically (plugins usually have more features than HomeKit).

---

## MCPPost (Event Broadcasting)

MCPPost broadcasts real-time sensor events to a custom HTTP endpoint, enabling your AI system (like Jarvis) to receive push notifications.

### Configuration
1. Open HomeMCPBridge
2. Go to the **MCPPost** tab
3. Enter your endpoint URL (e.g., `http://localhost:8000/api/events`)
4. Enable broadcasting with the toggle
5. Click "Test Endpoint" to verify

### Supported Events
- **Motion sensors** - Motion detected/cleared
- **Occupancy sensors** - Room occupancy changes
- **Doorbells** - Ring events
- **Contact sensors** - Door/window open/close

### Event Payload
```json
{
  "event_id": "uuid",
  "event_type": "motion|occupancy|doorbell|contact",
  "source": "HomeKit",
  "timestamp": "2024-01-18T21:00:00Z",
  "sensor": {
    "name": "Front Door Motion",
    "id": "sensor-uuid",
    "room": "Hallway",
    "home": "Home"
  },
  "data": {
    "detected": true,
    "state": "open",
    "isOpen": true
  }
}
```

---

## Plugin System

### Built-in Plugins

| Plugin | Authentication | Description |
|--------|----------------|-------------|
| **Apple HomeKit** | Native (always enabled) | Direct access to HomeKit devices |
| **Govee** | API Key | Control Govee smart lights and appliances |
| **Scrypted NVR** | Username/Password | Access Scrypted cameras and motion detection |

### Govee Setup

1. Open the Govee Home app on your phone
2. Go to **Settings > About Us > Apply for API Key**
3. Wait for approval (usually within a few days)
4. Copy your API key from the email
5. In HomeMCPBridge, go to **Plugins > Govee** and enter your API key
6. Enable the Govee plugin

### Scrypted NVR Setup

1. Install and configure Scrypted on your network
2. Note your Scrypted server URL (e.g., `https://mac-mini.local:10443`)
3. Install the `@scrypted/webhook` plugin in Scrypted
4. For each camera, create a Camera webhook and note the token
5. In HomeMCPBridge, go to **Plugins > Scrypted** and enter credentials
6. Use `scrypted_set_webhook_token` tool to configure each camera's token

---

## Plugin Development Guide

Want to add support for another smart home platform? Here's how to create a custom plugin.

### Plugin Protocol

```swift
protocol DevicePlugin: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var isEnabled: Bool { get set }
    var isConfigured: Bool { get }
    var configurationFields: [PluginConfigField] { get }

    func initialize() async throws
    func shutdown() async
    func listDevices() async throws -> [UnifiedDevice]
    func getDeviceState(deviceId: String) async throws -> [String: Any]
    func controlDevice(deviceId: String, action: String, value: Any?) async throws -> ControlResult
    func configure(with credentials: [String: String]) async throws
    func clearCredentials()
}
```

### Registering Your Plugin

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions...) {
    PluginManager.shared.register(MyPlatformPlugin())
}
```

---

## Privacy

HomeMCPBridge:
- Runs entirely on your Mac
- Communicates directly with your HomeKit devices via Apple's framework
- Does not send any data to external servers (except MCPPost, which you configure)
- Does not require an internet connection for local device control

## Troubleshooting

**"No devices found"**
- Make sure you have devices set up in the Apple Home app
- Grant HomeKit permission when the app first launches
- Try restarting the app

**"Device not reachable"**
- Check that the device is powered on and connected to your network
- Verify it shows as reachable in the Apple Home app

**MCP not connecting**
- Ensure the app is running (check the menu bar)
- Verify the path in your MCP config matches where you installed the app
- Restart your AI assistant after changing the config

**Scrypted snapshots not working**
- Ensure the @scrypted/webhook plugin is installed
- Create a Camera webhook for each camera in Scrypted
- Use `scrypted_set_webhook_token` to configure the tokens

## Contributing

Contributions welcome! Feel free to open issues or submit PRs.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- Built with Apple's HomeKit framework
- Uses the [Model Context Protocol](https://modelcontextprotocol.io/) by Anthropic
