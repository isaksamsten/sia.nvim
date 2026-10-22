"""Deterministic, network-free MCP stdio fixture."""
import json
import os
import sys
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
initialized = False


def send(value):
    data = json.dumps(value) + "\n"
    # Exercise fragmented reads, including escaped newlines inside strings.
    for offset in range(0, len(data), 17):
        sys.stdout.write(data[offset:offset + 17])
        sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "notifications/initialized":
        initialized = True
    if "id" not in message or not method:
        continue
    request_id = message["id"]
    if mode == "malformed":
        print("server logging on stdout", flush=True)
        continue
    if mode == "oversized":
        print("x" * (1024 * 1024 + 1), flush=True)
        continue
    if method == "initialize":
        result = {"protocolVersion": "bad" if mode == "version" else "2025-06-18",
                  "capabilities": {"tools": {"listChanged": True}},
                  "serverInfo": {"name": "fixture", "version": "1"}}
    elif method == "tools/list":
        assert initialized
        if not message.get("params", {}).get("cursor"):
            result = {"tools": [{"name": "search", "description": "Search documents",
                                 "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}},
                                                 "required": ["query"], "additionalProperties": False},
                                 "annotations": {"readOnlyHint": True}}], "nextCursor": "page2"}
        else:
            result = {"tools": [{"name": "hidden", "inputSchema": {"type": "object"}}]}
    elif method == "tools/call":
        args = message["params"]["arguments"]
        if args.get("query") == "changed":
            send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        if args.get("query") == "requests":
            send({"jsonrpc": "2.0", "id": "ping", "method": "ping"})
            send({"jsonrpc": "2.0", "id": "sampling", "method": "sampling/createMessage"})
            pong = json.loads(sys.stdin.readline())
            denied = json.loads(sys.stdin.readline())
            assert pong["id"] == "ping" and pong["result"] == {}
            assert denied["error"]["code"] == -32601
        if args.get("query") == "exit":
            os._exit(2)
        if args.get("query") == "slow":
            time.sleep(0.25)
        if args.get("query") == "protocol_error":
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "bad args"}})
            continue
        result = {"content": [{"type": "text", "text": "page 3\nEvidence"}],
                  "isError": args.get("query") == "error"}
    else:
        result = {}
    send({"jsonrpc": "2.0", "id": request_id, "result": result})

