#!/usr/bin/env python3
"""Minimal MCP server exposing the file Neovim currently has in focus.

Neovim writes that file's path, language and cursor line to a small context file
on BufEnter; Claude calls get_current_file to read it, so "explain this file"
works in the chat panel with nothing appearing in the UI.

Registered by lua/claude_cli.lua, which passes this script to `claude` via
--mcp-config on the panel's own invocation. It is deliberately not a `claude mcp
add` entry: that is per-machine state this repo cannot carry, and the integration
spent its whole life silently dead for exactly that reason.

Kept hand-rolled rather than pulling in the `mcp` package: one tool over
newline-delimited JSON-RPC on stdio is a few dozen lines, and a dependency that
has to be pip-installed on every machine would reintroduce the failure mode above.
"""

import json
import os
import sys

# Passed by claude_cli.lua so there is one definition of where the file lives.
# The fallback is only for running this script by hand; nvim always sets it, and
# it deliberately does NOT match the old world-writable /tmp/nvim-claude-ctx —
# that path is shared by every user on the machine.
CTX_FILE = os.environ.get("NVIM_CLAUDE_CTX") or os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or os.path.expanduser("~/.cache/nvim"),
    "nvim-claude-ctx",
)

TOOL = "get_current_file"

TOOL_SPEC = {
    "name": TOOL,
    "description": (
        "Returns the file currently open and in focus in Neovim, "
        "including its relative path, language, and cursor line. "
        "Call this automatically at the start of each response "
        "when the user refers to 'this file', 'current file', "
        "'open file', or any file without naming it explicitly."
    ),
    "inputSchema": {"type": "object", "properties": {}, "required": []},
}


def send(obj):
    print(json.dumps(obj), flush=True)


def reply(id_, result):
    send({"jsonrpc": "2.0", "id": id_, "result": result})


def fail(id_, code, message):
    # A request must get *an* answer, or the client waits on that id forever. The
    # previous version answered every unknown method with an empty success, which
    # is a schema violation for anything whose result has required fields
    # (resources/list needs a `resources` array) — so a client that probed for
    # resources got a malformed reply rather than an honest "no such method".
    send({"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}})


NO_CONTEXT = "No Neovim file context available yet."


def read_context():
    try:
        with open(CTX_FILE) as f:
            content = f.read().strip()
    except OSError:
        # Nothing has been written yet: nvim only starts writing once the chat
        # panel has been opened. Say so plainly rather than erroring, so Claude
        # asks which file you mean instead of reporting a broken tool.
        return NO_CONTEXT
    # An empty file is the same situation as a missing one, and used to come back
    # as an empty text block with isError false — a successful answer that said
    # nothing, which Claude has no way to interpret. nvim now writes via a
    # temp-file rename so a torn read cannot produce this, but a zero-length file
    # left by an older version or an interrupted write still can.
    return content or NO_CONTEXT


def handle(msg):
    method = msg.get("method")
    id_ = msg.get("id")

    if method == "initialize":
        # Echo the client's protocol version when it names one: the spec asks the
        # server to agree or propose, and this server's surface — one tool, no
        # resources, no prompts — is unchanged across every revision so far.
        requested = (msg.get("params") or {}).get("protocolVersion")
        reply(id_, {
            "protocolVersion": requested or "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "nvim-context", "version": "1.1.0"},
        })

    elif method == "tools/list":
        reply(id_, {"tools": [TOOL_SPEC]})

    elif method == "tools/call":
        name = (msg.get("params") or {}).get("name")
        if name != TOOL:
            # It used to answer any name at all with the context, which meant it
            # claimed to implement tools it never advertised — masking a client's
            # typo or a stale tool list as a working call.
            fail(id_, -32602, "Unknown tool: %r" % (name,))
        else:
            reply(id_, {
                "content": [{"type": "text", "text": read_context()}],
                "isError": False,
            })

    elif method == "ping":
        reply(id_, {})

    elif id_ is None:
        pass  # a notification (notifications/initialized, cancellation): no reply

    else:
        fail(id_, -32601, "Method not found: %s" % (method,))


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            # No id to answer with, so a parse error is the one case where
            # staying quiet is right. Report it on stderr, which the client logs.
            print("nvim-context: could not parse: %r" % (line[:200],), file=sys.stderr)
            continue
        try:
            handle(msg)
        except Exception as exc:  # noqa: BLE001 — one bad request must not end the server
            id_ = msg.get("id") if isinstance(msg, dict) else None
            if id_ is not None:
                fail(id_, -32603, "Internal error: %s" % (exc,))
            else:
                print("nvim-context: %s" % (exc,), file=sys.stderr)


if __name__ == "__main__":
    main()
