#!/usr/bin/env python3
"""
Scrypted Bridge - Connects to Scrypted via Socket.IO and provides REST-like access.

This script acts as a bridge between the Swift HomeMCPBridge and Scrypted's
Socket.IO-based API. It connects to Scrypted, maintains state, and exposes
simple JSON endpoints via a local HTTP server.

Usage:
    python3 scrypted_bridge.py --host https://mac-mini.local:10443 --username USER --password PASS

Endpoints:
    GET /devices - List all devices
    GET /cameras - List cameras only
    GET /device/{id}/state - Get device state
    GET /device/{id}/snapshot - Get camera snapshot (returns JPEG)
"""

import argparse
import asyncio
import json
import ssl
import sys
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import urllib.request
import urllib.error

# Try to import socketio, fall back to requests-only mode
try:
    import socketio
    HAS_SOCKETIO = True
except ImportError:
    HAS_SOCKETIO = False
    print("Warning: python-socketio not installed. Using REST-only mode.", file=sys.stderr)

# Global state
scrypted_state = {
    "devices": {},
    "connected": False,
    "token": None,
    "host": None,
    "last_update": 0
}


def get_ssl_context():
    """Create SSL context that accepts self-signed certs."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def login_to_scrypted(host: str, username: str, password: str) -> dict:
    """Login to Scrypted and get auth token."""
    url = f"{host}/login"
    data = f"username={username}&password={password}".encode('utf-8')

    req = urllib.request.Request(url, data=data, method='POST')
    req.add_header('Content-Type', 'application/x-www-form-urlencoded')

    try:
        with urllib.request.urlopen(req, context=get_ssl_context(), timeout=30) as response:
            result = json.loads(response.read().decode('utf-8'))
            if 'error' in result:
                raise Exception(result['error'])
            return result
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8')
        try:
            error_json = json.loads(body)
            raise Exception(error_json.get('error', f'HTTP {e.code}'))
        except json.JSONDecodeError:
            raise Exception(f'HTTP {e.code}: {body}')


def fetch_with_cookie(url: str, cookie: str) -> bytes:
    """Fetch URL with cookie authentication."""
    req = urllib.request.Request(url)
    req.add_header('Cookie', cookie)

    with urllib.request.urlopen(req, context=get_ssl_context(), timeout=30) as response:
        return response.read()


class ScryptedBridgeHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the bridge."""

    def log_message(self, format, *args):
        """Suppress default logging."""
        pass

    def send_json(self, data: dict, status: int = 200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def send_binary(self, data: bytes, content_type: str = 'image/jpeg'):
        """Send binary response."""
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', len(data))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        """Handle GET requests."""
        parsed = urlparse(self.path)
        path = parsed.path

        if path == '/status':
            self.send_json({
                "connected": scrypted_state["connected"],
                "device_count": len(scrypted_state["devices"]),
                "last_update": scrypted_state["last_update"]
            })

        elif path == '/devices':
            devices = list(scrypted_state["devices"].values())
            self.send_json({
                "devices": devices,
                "count": len(devices)
            })

        elif path == '/cameras':
            cameras = [
                d for d in scrypted_state["devices"].values()
                if 'Camera' in d.get('interfaces', []) or 'VideoCamera' in d.get('interfaces', [])
            ]
            self.send_json({
                "cameras": cameras,
                "count": len(cameras)
            })

        elif path.startswith('/device/') and path.endswith('/state'):
            device_id = path.split('/')[2]
            device = scrypted_state["devices"].get(device_id)
            if device:
                self.send_json(device)
            else:
                self.send_json({"error": "Device not found"}, 404)

        elif path.startswith('/device/') and path.endswith('/snapshot'):
            device_id = path.split('/')[2]
            device = scrypted_state["devices"].get(device_id)
            if not device:
                self.send_json({"error": "Device not found"}, 404)
                return

            # Try to fetch snapshot from Scrypted
            # The snapshot URL pattern depends on Scrypted's configuration
            host = scrypted_state["host"]
            token = scrypted_state["token"]

            # Try multiple snapshot URL patterns
            snapshot_urls = [
                f"{host}/endpoint/@scrypted/core/api/{token}/device/{device_id}/Camera.getSnapshot",
                f"{host}/endpoint/@scrypted/snapshot/public/{device_id}",
            ]

            for url in snapshot_urls:
                try:
                    data = fetch_with_cookie(url, f"login_user_token={token}")
                    if data and len(data) > 100:  # Likely an image
                        self.send_binary(data)
                        return
                except Exception:
                    continue

            self.send_json({"error": "Could not fetch snapshot"}, 500)

        else:
            self.send_json({"error": "Unknown endpoint"}, 404)


async def connect_socketio(host: str, username: str, password: str):
    """Connect to Scrypted via Socket.IO and maintain state."""
    global scrypted_state

    # Login first
    print(f"Logging in to {host}...", file=sys.stderr)
    try:
        login_result = login_to_scrypted(host, username, password)
        token = login_result.get('authorization', '').replace('Bearer ', '')
        scrypted_state["token"] = token
        scrypted_state["host"] = host
        print(f"Login successful, got token", file=sys.stderr)
    except Exception as e:
        print(f"Login failed: {e}", file=sys.stderr)
        return

    if not HAS_SOCKETIO:
        print("Socket.IO not available, running in limited mode", file=sys.stderr)
        scrypted_state["connected"] = True
        return

    # Connect via Socket.IO
    sio = socketio.AsyncClient(ssl_verify=False)

    @sio.event
    async def connect():
        print("Socket.IO connected", file=sys.stderr)
        scrypted_state["connected"] = True

    @sio.event
    async def disconnect():
        print("Socket.IO disconnected", file=sys.stderr)
        scrypted_state["connected"] = False

    @sio.on('systemState')
    async def on_system_state(data):
        """Handle system state updates."""
        if isinstance(data, dict):
            for device_id, device_info in data.items():
                if isinstance(device_info, dict):
                    device_info['id'] = device_id
                    scrypted_state["devices"][device_id] = device_info
            scrypted_state["last_update"] = time.time()
            print(f"Updated {len(data)} devices", file=sys.stderr)

    @sio.on('stateChange')
    async def on_state_change(device_id, property_name, value):
        """Handle individual state changes."""
        if device_id in scrypted_state["devices"]:
            scrypted_state["devices"][device_id][property_name] = value

    try:
        # The engine.io endpoint
        endpoint = f"{host}/endpoint/@scrypted/core/engine.io/api/"
        print(f"Connecting to {endpoint}...", file=sys.stderr)

        await sio.connect(
            endpoint,
            transports=['websocket', 'polling'],
            auth={'token': token}
        )

        # Request initial state
        await sio.emit('getSystemState')

        # Keep connection alive
        while True:
            await asyncio.sleep(30)
            if sio.connected:
                await sio.emit('ping')

    except Exception as e:
        print(f"Socket.IO error: {e}", file=sys.stderr)


def run_http_server(port: int):
    """Run the HTTP server."""
    server = HTTPServer(('127.0.0.1', port), ScryptedBridgeHandler)
    print(f"HTTP server listening on http://127.0.0.1:{port}", file=sys.stderr)
    server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description='Scrypted Bridge')
    parser.add_argument('--host', required=True, help='Scrypted server URL')
    parser.add_argument('--username', required=True, help='Scrypted username')
    parser.add_argument('--password', required=True, help='Scrypted password')
    parser.add_argument('--port', type=int, default=18765, help='HTTP server port')
    parser.add_argument('--mode', choices=['full', 'test'], default='full', help='Run mode')
    args = parser.parse_args()

    if args.mode == 'test':
        # Just test the login
        try:
            result = login_to_scrypted(args.host, args.username, args.password)
            print(json.dumps(result, indent=2))
        except Exception as e:
            print(json.dumps({"error": str(e)}))
            sys.exit(1)
        return

    # Start HTTP server in a thread
    http_thread = threading.Thread(target=run_http_server, args=(args.port,), daemon=True)
    http_thread.start()

    # Run Socket.IO connection
    asyncio.run(connect_socketio(args.host, args.username, args.password))


if __name__ == '__main__':
    main()
