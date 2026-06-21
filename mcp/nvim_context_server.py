#!/usr/bin/env python3
"""
Minimal MCP server that exposes the current Neovim buffer as a tool.
Neovim writes context to /tmp/nvim-claude-ctx on every BufEnter.
Claude calls get_current_file() to read it silently — nothing in the UI.
"""

import json
import sys
import os

CTX_FILE = "/tmp/nvim-claude-ctx"


def send(obj):
    print(json.dumps(obj), flush=True)


def handle(msg):
    method = msg.get("method")
    id_ = msg.get("id")

    if method == "initialize":
        send({
            "jsonrpc": "2.0",
            "id": id_,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "nvim-context", "version": "1.0.0"},
            },
        })

    elif method == "notifications/initialized":
        pass  # no response needed

    elif method == "tools/list":
        send({
            "jsonrpc": "2.0",
            "id": id_,
            "result": {
                "tools": [
                    {
                        "name": "get_current_file",
                        "description": (
                            "Returns the file currently open and in focus in Neovim, "
                            "including its relative path, language, and cursor line. "
                            "Call this automatically at the start of each response "
                            "when the user refers to 'this file', 'current file', "
                            "'open file', or any file without naming it explicitly."
                        ),
                        "inputSchema": {
                            "type": "object",
                            "properties": {},
                            "required": [],
                        },
                    }
                ]
            },
        })

    elif method == "tools/call":
        if os.path.exists(CTX_FILE):
            with open(CTX_FILE) as f:
                content = f.read().strip()
        else:
            content = "No Neovim file context available yet."

        send({
            "jsonrpc": "2.0",
            "id": id_,
            "result": {
                "content": [{"type": "text", "text": content}],
                "isError": False,
            },
        })

    elif id_ is not None:
        # Unknown request — send empty success so Claude doesn't hang
        send({"jsonrpc": "2.0", "id": id_, "result": {}})


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        handle(json.loads(line))
    except Exception:
        pass
