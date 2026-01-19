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

## Available MCP Tools

| Tool | Description |
|------|-------------|
| `list_devices` | List all HomeKit devices with names, rooms, types, and status |
| `list_rooms` | List all rooms in all homes |
| `list_homes` | List all configured HomeKit homes |
| `get_device_state` | Get current state of a device (on/off, brightness, color, etc.) |
| `control_device` | Control a device (on, off, toggle, brightness, color, lock, unlock, open, close) |

## Supported Device Types

- **Lights** - On/off, brightness, color (hue/saturation)
- **Switches** - On/off
- **Outlets** - On/off
- **Fans** - On/off
- **Locks** - Lock/unlock
- **Garage Doors** - Open/close
- **Thermostats** - Read temperature (control coming soon)
- **Sensors** - Read values

---

## Plugin System

HomeMCPBridge v2.0 introduces a plugin architecture that allows integration with third-party smart home platforms beyond Apple HomeKit.

### Built-in Plugins

| Plugin | Authentication | Description |
|--------|----------------|-------------|
| **Apple HomeKit** | Native (always enabled) | Direct access to HomeKit devices via Apple's framework |
| **Govee** | API Key | Control Govee smart lights and appliances |
| **Aqara** | OAuth 2.0 | Control Aqara sensors, switches, and smart home devices |

### Configuring Plugins

1. Open HomeMCPBridge
2. Go to the **Plugins** tab
3. Tap on a plugin to configure credentials
4. Toggle the switch to enable/disable the plugin

### Govee Setup

1. Open the Govee Home app on your phone
2. Go to **Settings > About Us > Apply for API Key**
3. Wait for approval (usually within a few days)
4. Once approved, copy your API key
5. In HomeMCPBridge, go to **Plugins > Govee** and enter your API key
6. Enable the Govee plugin

### Aqara Setup

1. Register as a developer at [developer.aqara.com](https://developer.aqara.com)
2. Create an application to get your Client ID and Client Secret
3. In HomeMCPBridge, go to **Plugins > Aqara**
4. Enter your Client ID, Client Secret, and region (us, eu, or cn)
5. Complete the OAuth authorization flow
6. Enable the Aqara plugin

### Devices Tab

The new **Devices** tab shows all devices from all enabled plugins, organized by source:
- See device names, types, rooms, and reachability status
- Pull-to-refresh to update the device list
- Devices are grouped by HomeKit, Govee, Aqara, etc.

---

## Plugin Development Guide

Want to add support for another smart home platform? Here's how to create a custom plugin.

### Plugin Protocol

All plugins must conform to the `DevicePlugin` protocol:

```swift
protocol DevicePlugin: AnyObject {
    var identifier: String { get }        // Unique ID (e.g., "myplatform")
    var displayName: String { get }       // UI display name
    var isEnabled: Bool { get set }       // Whether plugin is active
    var isConfigured: Bool { get }        // Whether credentials are set
    var configurationFields: [PluginConfigField] { get }  // UI config fields

    func initialize() async throws        // Called when enabled
    func shutdown() async                 // Called when disabled
    func listDevices() async throws -> [UnifiedDevice]
    func getDeviceState(deviceId: String) async throws -> [String: Any]
    func controlDevice(deviceId: String, action: String, value: Any?) async throws -> ControlResult
    func configure(with credentials: [String: String]) async throws
    func clearCredentials()
}
```

### Example Plugin Structure

```swift
class MyPlatformPlugin: DevicePlugin {
    let identifier = "myplatform"
    let displayName = "My Platform"
    var isEnabled = false

    var isConfigured: Bool {
        CredentialManager.shared.retrieve(key: "apiKey", plugin: identifier) != nil
    }

    var configurationFields: [PluginConfigField] {
        [PluginConfigField(
            key: "apiKey",
            label: "API Key",
            placeholder: "Enter your API key",
            isSecure: true,
            helpText: "Get your API key from myplatform.com"
        )]
    }

    func initialize() async throws {
        guard isConfigured else { throw PluginError.notConfigured }
        // Validate credentials and cache device list
    }

    func listDevices() async throws -> [UnifiedDevice] {
        // Fetch devices from your platform's API
        // Return as UnifiedDevice objects
    }

    // Implement remaining methods...
}
```

### Registering Your Plugin

Add your plugin to the AppDelegate:

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions...) {
    // ...
    PluginManager.shared.register(MyPlatformPlugin())
    // ...
}
```

### UnifiedDevice Model

All plugins return devices using a common format:

```swift
struct UnifiedDevice {
    let id: String           // Unique device identifier
    let name: String         // Display name
    let room: String?        // Room location (optional)
    let type: String         // Device type: light, switch, outlet, fan, lock, etc.
    let source: DeviceSource // Which plugin owns this device
    let isReachable: Bool    // Is device online?
    let manufacturer: String?
    let model: String?
}
```

### Secure Credential Storage

Use `CredentialManager` for secure Keychain storage:

```swift
// Store a credential
CredentialManager.shared.store(key: "apiKey", value: "secret123", plugin: "myplatform")

// Retrieve a credential
let key = CredentialManager.shared.retrieve(key: "apiKey", plugin: "myplatform")

// Delete a credential
CredentialManager.shared.delete(key: "apiKey", plugin: "myplatform")
```

## Privacy

HomeMCPBridge:
- Runs entirely on your Mac
- Communicates directly with your HomeKit devices via Apple's framework
- Does not send any data to external servers
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

## Contributing

Contributions welcome! Feel free to open issues or submit PRs.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- Built with Apple's HomeKit framework
- Uses the [Model Context Protocol](https://modelcontextprotocol.io/) by Anthropic
