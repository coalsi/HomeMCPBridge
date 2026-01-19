# HomeMCPBridge

Native macOS HomeKit integration for AI assistants via the Model Context Protocol (MCP).

## Important Notes

**This is an MCP-only interface.** HomeMCPBridge exposes HomeKit data and controls as MCP tools - it does NOT contain automation logic. The AI (Jarvis, Claude, etc.) handles all decision-making.

## Architecture

- Single Swift file: `HomeMCPBridge/main.swift`
- Mac Catalyst app (runs on macOS)
- MCP server communicates via stdin/stdout
- Plugin system for third-party integrations (Govee, Scrypted, etc.)

## MCP Tools

### Device Control
- `list_devices` - List all devices from HomeKit and plugins
- `get_device_state` - Get current state of a device
- `control_device` - Control a device (on/off, brightness, color, etc.)
- `list_rooms` - List all rooms
- `list_homes` - List all homes

### Cameras
- `list_cameras` - List all HomeKit cameras
- `capture_snapshot` - Capture image from camera (returns base64)

### Motion & Events
- `list_motion_sensors` - List motion sensors, occupancy sensors, doorbells
- `get_motion_state` - Get current motion detection state
- `subscribe_events` - Enable motion and contact event buffering
- `get_pending_events` - Poll for buffered motion/doorbell/contact events

## MCPPost (Event Broadcasting)

HomeMCPBridge includes an MCPPost feature that broadcasts real-time sensor events to a custom HTTP endpoint. This enables AI systems like Jarvis to receive push notifications when motion is detected, doors open/close, doorbells ring, etc.

### Configuration
1. Open HomeMCPBridge app
2. Go to the **MCPPost** tab
3. Enter your endpoint URL (e.g., `http://localhost:8000/api/events`)
4. Enable event broadcasting with the toggle
5. Click "Test Endpoint" to verify connectivity

### Supported Events
- **Motion sensors** - Motion detected/cleared
- **Occupancy sensors** - Room occupancy changes
- **Doorbells** - Doorbell ring events
- **Contact sensors** - Door/window open/close

### Event Payload Format
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
    "detected": true,      // for motion/occupancy
    "state": "open",       // for contact sensors
    "isOpen": true         // for contact sensors
  }
}
```

### Integration with Jarvis
When MCPPost is configured, your AI system receives real-time events and can:
- Use MCP tools to capture camera snapshots when motion is detected
- Turn on lights in response to occupancy
- Send alerts when doors open unexpectedly
- React to doorbell rings with camera views

### Scrypted NVR (requires configuration)
- `scrypted_list_cameras` - List all Scrypted cameras with capabilities
- `scrypted_capture_snapshot` - Capture snapshot from Scrypted camera (by ID or name)
- `scrypted_get_camera_state` - Get camera state including motion detection
- `scrypted_set_webhook_token` - Configure webhook token for a camera (required for snapshots)

## Building

1. Open `HomeMCPBridge.xcodeproj` in Xcode
2. Select "My Mac (Mac Catalyst)" as target
3. Build and run (Cmd+R)

## Configuration

Add to MCP config (`.mcp.json` or Claude Desktop config):
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

## Plugins

### Govee
Configure with `configure_plugin` tool:
- `apiKey` - Govee API key (get from Govee app)

### Scrypted NVR
Configure with `configure_plugin` tool:
- `host` - Scrypted server URL (e.g., `https://mac-mini.local:10443`)
- `username` - Scrypted admin username
- `password` - Scrypted admin password

The Scrypted plugin supports:
- Listing all cameras with their capabilities (motion detection, audio)
- Capturing snapshots from any camera (requires Webhook plugin)
- Getting camera state including motion detection status
- Accepts self-signed SSL certificates (common for local Scrypted installs)

**Scrypted Webhook Setup (required for snapshots):**
1. Install the `@scrypted/webhook` plugin in Scrypted
2. For each camera, go to Settings > Webhook > Create Webhook > Select "Camera"
3. Note the webhook token from the generated URL (the random string after the device ID)
4. Use `scrypted_set_webhook_token` to configure each camera:
   - Example URL: `https://host/endpoint/@scrypted/webhook/public/45/11e64f2c7b7027ef/takePicture`
   - device_id: `45`, token: `11e64f2c7b7027ef`

## Key Files

- `HomeMCPBridge/main.swift` - All application code (single file)
- `HomeMCPBridge/HomeMCPBridge.entitlements` - HomeKit and Keychain entitlements
- `HomeMCPBridge/Info.plist` - App configuration
