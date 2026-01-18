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
