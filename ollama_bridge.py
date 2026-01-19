#!/usr/bin/env python3
"""
Ollama <-> HomeMCPBridge Bridge

This script lets Ollama control your HomeKit devices through HomeMCPBridge.
It handles the tool calling logic that MCP normally provides.

Usage:
    python ollama_bridge.py "turn on the office light"
    python ollama_bridge.py  # interactive mode
"""

import subprocess
import json
import sys
import requests

# Configuration
OLLAMA_URL = "http://localhost:11434"
OLLAMA_MODEL = "llama3.1"  # or qwen2.5, mistral, etc. - needs function calling support
MCP_PATH = "/Volumes/X10 Pro/Dev Apps/homeMCP/HomeMCPBridge.app/Contents/MacOS/HomeMCPBridge"

# HomeKit tools definition for Ollama
HOMEKIT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_devices",
            "description": "List all HomeKit devices in all homes with their names, rooms, types, and reachability status. Call this first to see what devices are available.",
            "parameters": {
                "type": "object",
                "properties": {},
                "required": []
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "list_rooms",
            "description": "List all rooms in all HomeKit homes.",
            "parameters": {
                "type": "object",
                "properties": {},
                "required": []
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "get_device_state",
            "description": "Get the current state of a HomeKit device (on/off, brightness, color, etc.).",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "The exact name of the device as shown in HomeKit"
                    }
                },
                "required": ["name"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "control_device",
            "description": "Control a HomeKit device. Use this to turn devices on/off, set brightness, change colors, lock/unlock, or open/close.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "The exact name of the device as shown in HomeKit"
                    },
                    "action": {
                        "type": "string",
                        "enum": ["on", "off", "toggle", "brightness", "color", "lock", "unlock", "open", "close"],
                        "description": "The action to perform"
                    },
                    "value": {
                        "description": "Value for the action: brightness (0-100), or color ({hue: 0-360, saturation: 0-100})"
                    }
                },
                "required": ["name", "action"]
            }
        }
    }
]

class MCPClient:
    """Communicates with HomeMCPBridge via stdin/stdout"""

    def __init__(self, mcp_path):
        self.proc = subprocess.Popen(
            [mcp_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        self.request_id = 0
        self._initialize()

    def _send(self, method, params=None):
        self.request_id += 1
        request = {
            "jsonrpc": "2.0",
            "id": self.request_id,
            "method": method
        }
        if params:
            request["params"] = params

        line = json.dumps(request) + "\n"
        self.proc.stdin.write(line.encode())
        self.proc.stdin.flush()

        response_line = self.proc.stdout.readline()
        if response_line:
            return json.loads(response_line)
        return None

    def _initialize(self):
        """Initialize MCP connection"""
        self._send("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "ollama-bridge", "version": "1.0.0"}
        })
        self._send("notifications/initialized")

    def call_tool(self, name, arguments=None):
        """Call an MCP tool and return the result"""
        response = self._send("tools/call", {
            "name": name,
            "arguments": arguments or {}
        })

        if response and "result" in response:
            content = response["result"].get("content", [])
            if content and len(content) > 0:
                text = content[0].get("text", "{}")
                return json.loads(text)
        return {"error": "No response from MCP"}

    def close(self):
        self.proc.terminate()


def chat_with_ollama(messages, tools=None):
    """Send a chat request to Ollama with optional tools"""
    payload = {
        "model": OLLAMA_MODEL,
        "messages": messages,
        "stream": False
    }
    if tools:
        payload["tools"] = tools

    response = requests.post(f"{OLLAMA_URL}/api/chat", json=payload)
    return response.json()


def process_command(user_input, mcp_client):
    """Process a user command through Ollama and execute any tool calls"""

    messages = [
        {
            "role": "system",
            "content": """You are a helpful smart home assistant. You can control HomeKit devices.

When the user asks about devices or wants to control them:
1. If you don't know what devices exist, call list_devices first
2. Use the exact device name from the list when calling control_device
3. Be concise in your responses

Available actions for control_device:
- on, off, toggle: for lights, switches, outlets
- brightness: set brightness 0-100 (requires value parameter)
- color: set color (requires value with hue 0-360 and saturation 0-100)
- lock, unlock: for locks
- open, close: for garage doors"""
        },
        {
            "role": "user",
            "content": user_input
        }
    ]

    # First call to Ollama - may request tool use
    response = chat_with_ollama(messages, HOMEKIT_TOOLS)

    if "message" not in response:
        return "Error communicating with Ollama"

    assistant_message = response["message"]

    # Check if the model wants to use tools
    if "tool_calls" in assistant_message and assistant_message["tool_calls"]:
        # Add assistant's response to messages
        messages.append(assistant_message)

        # Process each tool call
        for tool_call in assistant_message["tool_calls"]:
            function = tool_call["function"]
            tool_name = function["name"]
            tool_args = function.get("arguments", {})

            # Handle arguments that might be a string
            if isinstance(tool_args, str):
                try:
                    tool_args = json.loads(tool_args)
                except:
                    tool_args = {}

            print(f"  [Calling {tool_name}({tool_args})]")

            # Call the MCP tool
            result = mcp_client.call_tool(tool_name, tool_args)

            # Add tool result to messages
            messages.append({
                "role": "tool",
                "content": json.dumps(result, indent=2)
            })

        # Get final response from Ollama
        final_response = chat_with_ollama(messages)
        if "message" in final_response:
            return final_response["message"].get("content", "Done.")
        return "Done."

    # No tool calls, just return the response
    return assistant_message.get("content", "I'm not sure how to help with that.")


def main():
    print("Connecting to HomeMCPBridge...")

    try:
        mcp_client = MCPClient(MCP_PATH)
    except Exception as e:
        print(f"Error connecting to MCP: {e}")
        print(f"Make sure HomeMCPBridge is at: {MCP_PATH}")
        sys.exit(1)

    print("Connected! Ready for commands.\n")

    # Check if command was passed as argument
    if len(sys.argv) > 1:
        command = " ".join(sys.argv[1:])
        print(f"You: {command}")
        response = process_command(command, mcp_client)
        print(f"Jarvis: {response}")
        mcp_client.close()
        return

    # Interactive mode
    print("Type 'quit' to exit.\n")

    try:
        while True:
            user_input = input("You: ").strip()
            if not user_input:
                continue
            if user_input.lower() in ["quit", "exit", "q"]:
                break

            response = process_command(user_input, mcp_client)
            print(f"Jarvis: {response}\n")

    except KeyboardInterrupt:
        print("\nGoodbye!")
    finally:
        mcp_client.close()


if __name__ == "__main__":
    main()
