#!/usr/bin/env python3
"""Controlled MCP fixture. No third-party dependencies or external services."""
import argparse
import json
import os
import signal
import sys
import time
import threading

PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3XcAAAAASUVORK5CYII="


def tool(name):
    return {"name": name, "description": "Fixture " + name,
            "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "additionalProperties": True}}


def response(request):
    method = request.get("method")
    if "id" not in request:
        return None
    result = {}
    params = request.get("params", {})
    if method == "initialize":
        result = {"protocolVersion": "2025-11-25", "serverInfo": {"name": "bridge-fixture", "version": "1.0"},
                  "capabilities": {"tools": {}}}
    elif method == "tools/list":
        if params.get("cursor") == "page-2":
            result = {"tools": [tool(n) for n in ["image", "fail", "slow", "malformed", "exit", "environment"]]}
        else:
            result = {"tools": [tool("echo"), tool("structured")], "nextCursor": "page-2"}
    elif method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments", {})
        if name == "slow":
            time.sleep(arguments.get("seconds", 5))
        if name == "exit":
            os._exit(17)
        if name == "malformed":
            return "NOT JSON"
        if name == "image":
            result = {"content": [{"type": "image", "data": PNG, "mimeType": "image/png"}]}
        elif name == "fail":
            result = {"content": [{"type": "text", "text": "Expected fixture failure"}], "isError": True}
        elif name == "structured":
            result = {"content": [{"type": "text", "text": "structured result"}],
                      "structuredContent": {"echo": arguments, "nested": [True, None, 7]}, "_meta": {"fixture": True}, "isError": False}
        elif name == "environment":
            result = {"content": [{"type": "text", "text": os.environ.get("BRIDGE_FIXTURE_VALUE", "unset")}], "isError": False}
        else:
            result = {"content": [{"type": "text", "text": json.dumps(arguments, ensure_ascii=False)}], "isError": False}
    elif method != "ping":
        return {"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Method not found"}}
    return {"jsonrpc": "2.0", "id": request["id"], "result": result}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid-file")
    parser.add_argument("--ignore-term", action="store_true")
    parser.add_argument("--counter-file")
    parser.add_argument("--tools-ready-after", type=float)
    parser.add_argument("--no-list-notification", action="store_true")
    args = parser.parse_args()
    if args.ignore_term:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if args.pid_file:
        with open(args.pid_file, "w") as file:
            json.dump({"pid": os.getpid(), "pgid": os.getpgrp()}, file)
    print("Fixture stderr: should never corrupt bridge stdout", file=sys.stderr, flush=True)
    ready_at = float("inf")
    output_lock = threading.Lock()
    def emit(value):
        with output_lock:
            print(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False), flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        if method == "notifications/initialized" and args.tools_ready_after is not None:
            ready_at = time.monotonic() + args.tools_ready_after
            if not args.no_list_notification:
                timer = threading.Timer(args.tools_ready_after, lambda: emit({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}))
                timer.daemon = True
                timer.start()
        if args.counter_file and request.get("method") == "tools/call":
            with open(args.counter_file, "a") as file:
                file.write("call\n")
        reply = response(request)
        if args.tools_ready_after is not None and isinstance(reply, dict):
            if method == "initialize":
                reply["result"]["capabilities"]["tools"]["listChanged"] = True
            elif method == "tools/list" and time.monotonic() < ready_at:
                reply["result"] = {"tools": []}
            elif method == "tools/call" and time.monotonic() < ready_at:
                reply["result"] = {"content": [{"type": "text", "text": "Fixture not ready"}], "isError": True}
        if reply is not None:
            emit(reply)


if __name__ == "__main__":
    main()
