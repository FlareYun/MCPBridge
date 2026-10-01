#!/usr/bin/env python3
"""End-to-end CLI tests using only disposable local fixture servers."""
import concurrent.futures
import http.server
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("MCP_BRIDGE_CLI", ROOT / ".build/debug/mcp-bridge")).resolve()
FIXTURE = ROOT / "Tests/Fixtures/server.py"
spec = importlib.util.spec_from_file_location("fixture", FIXTURE)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class Handler(http.server.BaseHTTPRequestHandler):
    calls = 0
    headers_seen = []
    deletes = 0
    redirected = 0
    dynamic_sessions = {}
    def log_message(self, *args):
        pass

    def do_POST(self):
        type(self).headers_seen.append(dict(self.headers))
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/redirect":
            self.send_response(307)
            self.send_header("Location", "/redirect-target")
            self.end_headers()
            return
        if self.path == "/redirect-target":
            type(self).redirected += 1
        if self.path == "/auth" and self.headers.get("Authorization") != "Bearer fixture-secret":
            self.send_response(401)
            self.end_headers()
            return
        request = json.loads(body)
        session_id = "fixture-session"
        ready = True
        if self.path == "/dynamic":
            session_id = self.headers.get("Mcp-Session-Id")
            if request.get("method") == "initialize":
                session_id = str(uuid.uuid4())
                type(self).dynamic_sessions[session_id] = time.monotonic() + 0.4
            ready = time.monotonic() >= type(self).dynamic_sessions.get(session_id, float("inf"))
        if request.get("method") == "tools/call":
            type(self).calls += 1
        reply = fixture.response(request)
        if self.path == "/dynamic" and isinstance(reply, dict):
            if request.get("method") == "initialize":
                reply["result"]["capabilities"]["tools"]["listChanged"] = True
            elif request.get("method") == "tools/list" and not ready:
                reply["result"] = {"tools": []}
            elif request.get("method") == "tools/call" and not ready:
                reply["result"] = {"content": [], "isError": True}
        if reply is None:
            self.send_response(202)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Mcp-Session-Id", session_id)
        if self.path == "/sse":
            self.send_header("Content-Type", "text/event-stream")
            encoded = ("event: message\ndata: " + json.dumps(reply) + "\n\n").encode()
        else:
            self.send_header("Content-Type", "application/json")
            encoded = json.dumps(reply).encode()
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except BrokenPipeError:
            pass

    def do_DELETE(self):
        type(self).deletes += 1
        self.send_response(204)
        self.end_headers()


class IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = "http://127.0.0.1:%d" % cls.http.server_port

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mcp-bridge-test-")
        self.directory = Path(self.temp.name)
        self.config = self.directory / "profile.json"
        self.pid_file = self.directory / "server-pid.json"
        self.counter = self.directory / "calls.txt"
        self.servers = [
            {"id": "local", "transport": "stdio", "command": sys.executable,
             "arguments": [str(FIXTURE), "--pid-file", str(self.pid_file), "--counter-file", str(self.counter)]},
            {"id": "http", "transport": "http", "url": self.url + "/mcp"},
            {"id": "sse", "transport": "http", "url": self.url + "/sse"},
            {"id": "auth", "transport": "http", "url": self.url + "/auth"},
            {"id": "missing", "transport": "stdio", "command": "/nonexistent/mcp-server"},
            {"id": "off", "transport": "stdio", "command": "/bin/cat", "enabled": False},
        ]
        self.write_profile()

    def tearDown(self):
        # On test failure, never leave our fixture running.
        if self.pid_file.exists():
            pid = json.loads(self.pid_file.read_text())["pid"]
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.temp.cleanup()

    def write_profile(self):
        self.config.write_text(json.dumps({"version": 1, "servers": self.servers}))

    def run_cli(self, *args, input=None, code=0, env=None):
        result = subprocess.run([str(CLI), "--config", str(self.config), *args], input=input,
                                capture_output=True, text=True, timeout=15, env=env)
        self.assertEqual(result.returncode, code, result.stderr + result.stdout)
        output = json.loads(result.stdout)
        self.assertNotIn("Fixture stderr", result.stdout)
        return output

    def call(self, tool, args=None, server="local", code=0, extra=(), env=None):
        return self.run_cli("call", server, tool, "--stdin", *extra,
                            input=json.dumps(args or {}, ensure_ascii=False), code=code, env=env)

    def assert_reaped(self):
        pid = json.loads(self.pid_file.read_text())["pid"]
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_catalog_discovery_and_description_do_not_launch(self):
        live = self.run_cli("tools", "list", "local", "--live")
        self.assertEqual(live["catalog"]["source"], "live")
        self.pid_file.unlink()
        for options in [(), ("--cached",)]:
            cached = self.run_cli("tools", "list", "local", *options)
            self.assertEqual(cached["catalog"]["source"], "cache")
            self.assertEqual(cached["result"], live["result"])
            self.assertTrue(cached["warnings"])
            self.assertEqual(self.run_cli("tools", "describe", "local", "image", *options)["result"]["name"], "image")
            self.assertFalse(self.pid_file.exists())
        self.call("echo", {"live": True})
        self.assertTrue(self.pid_file.exists())
        self.assertEqual(self.counter.read_text().splitlines(), ["call"])

    def test_catalog_missing_changed_corrupt_and_disabled(self):
        self.run_cli("tools", "list", "local", "--cached", code=2)
        self.assertFalse(self.pid_file.exists())
        live = self.run_cli("tools", "list", "local", "--live")
        self.pid_file.unlink()
        self.servers[0]["discoveryWait"] = 1
        self.write_profile()
        self.run_cli("tools", "list", "local", "--cached", code=2)
        self.assertFalse(self.pid_file.exists())
        self.servers[0]["discoveryWait"] = 10
        self.write_profile()
        self.assertEqual(self.run_cli("tools", "list", "local", "--cached")["catalog"]["source"], "cache")
        self.servers[0]["enabled"] = False
        self.write_profile()
        self.run_cli("tools", "list", "local", "--cached", code=2)
        self.assertFalse(self.pid_file.exists())
        self.servers[0]["enabled"] = True
        self.write_profile()
        Path(live["catalog"]["path"]).write_text("broken JSON")
        self.run_cli("tools", "list", "local", "--cached", code=2)
        self.assertFalse(self.pid_file.exists())
        refreshed = self.run_cli("tools", "list", "local")
        self.assertEqual(refreshed["catalog"]["source"], "live")
        self.assertTrue(refreshed["warnings"])

    def test_empty_or_failed_live_refresh_preserves_catalog(self):
        # Change the fixture's behavior without changing its configured identity.
        script = self.directory / "mutable-server.py"
        script.write_text(FIXTURE.read_text())
        self.servers[0]["arguments"][0] = str(script)
        self.write_profile()
        live = self.run_cli("tools", "list", "local", "--live")
        saved = Path(live["catalog"]["path"]).read_bytes()
        source = script.read_text()
        script.write_text(source.replace('        reply = response(request)', '        reply = response(request)\n        if method == "tools/list": reply["result"] = {"tools": []}'))
        empty = self.run_cli("tools", "list", "local", "--live")
        self.assertEqual(empty["result"]["tools"], [])
        self.assertIn("sandbox", " ".join(empty["warnings"]))
        self.assertEqual(Path(live["catalog"]["path"]).read_bytes(), saved)
        script.write_text("raise SystemExit(1)")
        self.run_cli("tools", "list", "local", "--live", code=3)
        self.assertEqual(Path(live["catalog"]["path"]).read_bytes(), saved)
        self.assertEqual(self.run_cli("tools", "list", "local", "--cached")["result"], live["result"])

    def test_catalog_flags_rejected_on_calls_before_reading_input(self):
        for options in [("--cached",), ("--live",), ("--cached", "--live")]:
            self.run_cli("call", "local", "echo", "--stdin", *options, input="{}", code=2)
        self.run_cli("tools", "list", "local", "--cached", "--live", code=2)
        self.assertFalse(self.pid_file.exists())

    def test_list_and_disabled_server(self):
        result = self.run_cli("servers", "list")
        self.assertEqual(len(result["servers"]), 6)
        self.run_cli("server", "test", "off", code=2)
        self.assertFalse(self.pid_file.exists())

    def dynamic_server(self, delay=0.4, wait=2, notify=True):
        self.servers[0]["arguments"] += ["--tools-ready-after", str(delay)]
        if not notify:
            self.servers[0]["arguments"] += ["--no-list-notification"]
        self.servers[0]["discoveryWait"] = wait
        self.write_profile()

    def test_dynamic_discovery_and_fresh_call(self):
        self.dynamic_server()
        self.assertEqual(len(self.run_cli("tools", "list", "local")["result"]["tools"]), 8)
        self.assert_reaped()
        self.assertEqual(self.run_cli("tools", "describe", "local", "structured")["result"]["name"], "structured")
        self.call("structured", {"text": "世界 🌉"})
        self.assertEqual(self.counter.read_text().splitlines(), ["call"])
        self.assert_reaped()

    def test_dynamic_discovery_without_notification(self):
        self.dynamic_server(notify=False)
        self.assertEqual(len(self.run_cli("tools", "list", "local")["result"]["tools"]), 8)
        self.assert_reaped()

    def test_dynamic_discovery_early_notification(self):
        self.dynamic_server(delay=0)
        self.assertEqual(len(self.run_cli("tools", "list", "local")["result"]["tools"]), 8)

    def test_dynamic_discovery_empty_and_no_call(self):
        self.dynamic_server(delay=60, wait=0.3)
        result = self.run_cli("tools", "list", "local")
        self.assertEqual(result["result"]["tools"], [])
        self.assertTrue(result["warnings"])
        self.call("structured", code=2)
        self.assertFalse(self.counter.exists())
        self.assert_reaped()

    def test_dynamic_discovery_timeout(self):
        self.dynamic_server(delay=60, wait=10)
        self.run_cli("tools", "list", "local", "--timeout", "0.2", code=5)
        self.assert_reaped()

    def test_dynamic_discovery_cancel(self):
        self.dynamic_server(delay=60, wait=10)
        process = subprocess.Popen([str(CLI), "--config", str(self.config), "tools", "list", "local"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(100):
                if self.pid_file.exists():
                    break
                time.sleep(0.01)
            self.assertTrue(self.pid_file.exists())
            time.sleep(0.1)
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=4)
            self.assertEqual(process.returncode, 3, stdout + stderr)
            self.assertIn("cancel", json.loads(stdout)["error"]["message"].lower())
            self.assert_reaped()
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    def test_dynamic_http_fresh_sessions(self):
        self.servers[1]["url"] = self.url + "/dynamic"
        self.write_profile()
        before = Handler.calls
        self.assertEqual(len(self.run_cli("tools", "list", "http")["result"]["tools"]), 8)
        self.call("structured", server="http")
        self.assertEqual(Handler.calls - before, 1)

    def test_connection_and_cleanup(self):
        result = self.run_cli("server", "test", "local")
        self.assertEqual(result["result"]["serverInfo"]["name"], "bridge-fixture")
        self.assert_reaped()

    def test_pagination_and_description(self):
        result = self.run_cli("tools", "list", "local")
        self.assertEqual(len(result["result"]["tools"]), 8)
        result = self.run_cli("tools", "describe", "local", "image")
        self.assertEqual(result["result"]["inputSchema"]["type"], "object")
        self.run_cli("tools", "describe", "local", "unknown", code=2)

    def test_unicode_and_structured_result(self):
        args = {"text": "Hello 世界 🌉", "nested": {"number": 1, "null": None}}
        result = self.call("echo", args)
        self.assertEqual(json.loads(result["result"]["content"][0]["text"]), args)
        result = self.call("structured", args)
        self.assertEqual(result["result"]["structuredContent"]["echo"], args)
        self.assertEqual(result["result"]["_meta"]["fixture"], True)

    def test_image_and_tool_error(self):
        result = self.call("image")
        self.assertEqual(result["result"]["content"][0]["data"], fixture.PNG)
        result = self.call("fail", code=4)
        self.assertFalse(result["ok"])
        self.assertTrue(result["result"]["isError"])

    def test_invalid_input_does_not_launch(self):
        self.run_cli("call", "local", "echo", "--stdin", input="[]", code=2)
        self.run_cli("call", "local", "echo", "--stdin", input="bad JSON", code=2)
        self.assertFalse(self.pid_file.exists())

    def test_argument_file_and_option_validation(self):
        path = self.directory / "arguments with spaces.json"
        path.write_text('{"text":"from file"}')
        result = self.run_cli("call", "local", "echo", "--args-file", str(path))
        self.assertIn("from file", result["result"]["content"][0]["text"])
        self.run_cli("call", "local", "echo", "--stdin", "--args-file", str(path), code=2)
        self.run_cli("tools", "list", "local", "--timeout", "nan", code=2)
        self.run_cli("tools", "list", "missing", code=2)
        self.run_cli("tools", "list", "unknown", code=2)

    def test_timeout_and_no_retry(self):
        start = time.monotonic()
        self.call("slow", {"seconds": 10}, extra=("--timeout", "0.4"), code=5)
        self.assertLess(time.monotonic() - start, 3)
        self.assertEqual(self.counter.read_text().splitlines(), ["call"])
        self.assert_reaped()

    def test_kill_uncooperative_child(self):
        self.servers[0]["arguments"].append("--ignore-term")
        self.write_profile()
        self.call("slow", {"seconds": 10}, extra=("--timeout", "0.4"), code=5)
        self.assert_reaped()

    def test_cancellation_and_no_listener(self):
        process = subprocess.Popen([str(CLI), "--config", str(self.config), "call", "local", "slow", "--stdin"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.stdin.write('{"seconds":10}')
            process.stdin.close()
            deadline = time.monotonic() + 5
            while not self.counter.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(self.counter.exists())
            lsof = shutil.which("lsof")
            if lsof:
                sockets = subprocess.run([lsof, "-nP", "-a", "-p", str(process.pid), "-iTCP", "-sTCP:LISTEN"], capture_output=True, text=True)
                self.assertEqual(sockets.returncode, 1, sockets.stdout + sockets.stderr)
            process.send_signal(signal.SIGINT)
            process.wait(timeout=4)
            stdout, stderr = process.stdout.read(), process.stderr.read()
            self.assertEqual(process.returncode, 3, stdout + stderr)
            result = json.loads(stdout)
            self.assertIn("cancel", result["error"]["message"].lower())
            self.assert_reaped()
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()
            process.stderr.close()

    def test_http_and_sse(self):
        before = Handler.deletes
        for server in ["http", "sse"]:
            self.run_cli("server", "test", server)
            result = self.run_cli("tools", "list", server)
            self.assertEqual(len(result["result"]["tools"]), 8)
            result = self.call("structured", {"via": server}, server=server)
            self.assertEqual(result["result"]["structuredContent"]["echo"], {"via": server})
        self.assertEqual(Handler.deletes - before, 6)

    def test_redirect_is_not_followed(self):
        self.servers[1]["url"] = self.url + "/redirect"
        self.write_profile()
        self.run_cli("server", "test", "http", code=3)
        self.assertEqual(Handler.redirected, 0)

    def test_http_timeout_override(self):
        self.servers[1]["timeout"] = 0.05
        self.write_profile()
        self.call("slow", {"seconds": 0.2}, server="http", extra=("--timeout", "2"))
        self.call("slow", {"seconds": 1}, server="http", extra=("--timeout", "0.1"), code=5)

    def test_unexpected_process_exit(self):
        start = time.monotonic()
        self.call("exit", code=3)
        self.assertLess(time.monotonic() - start, 3)
        self.assert_reaped()

    def test_fragmented_stdin_and_cancel_waiting_for_input(self):
        process = subprocess.Popen([str(CLI), "--config", str(self.config), "call", "local", "echo", "--stdin"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.stdin.write('{"text":')
            process.stdin.flush()
            time.sleep(0.1)
            process.stdin.write('"split input"}')
            process.stdin.close()
            process.wait(timeout=4)
            self.assertEqual(process.returncode, 0, process.stderr.read())
            result = json.loads(process.stdout.read())
            self.assertIn("split input", result["result"]["content"][0]["text"])
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()
            process.stderr.close()
        process = subprocess.Popen([str(CLI), "--config", str(self.config), "call", "local", "echo", "--stdin"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(0.1)
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=3)
            self.assertEqual(process.returncode, 3, process.stderr.read())
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def test_authentication_and_secret_exclusion(self):
        self.run_cli("server", "test", "auth", code=3)
        self.servers[3]["bearerToken"] = {"source": "environment", "name": "MCP_BRIDGE_TEST_TOKEN"}
        self.write_profile()
        self.run_cli("server", "test", "auth", code=2, env={"PATH": os.environ["PATH"]})
        env = dict(os.environ, MCP_BRIDGE_TEST_TOKEN="fixture-secret")
        result = self.run_cli("server", "test", "auth", env=env)
        self.assertTrue(result["ok"])
        listing = self.run_cli("servers", "list", env=env)
        self.assertNotIn("fixture-secret", json.dumps(listing))
        self.assertNotIn("fixture-secret", self.config.read_text())

    def test_explicit_environment_mapping(self):
        self.servers[0]["environment"] = {"BRIDGE_FIXTURE_VALUE": {"source": "environment", "name": "BRIDGE_VALUE_SOURCE"}}
        self.write_profile()
        result = self.call("environment", env=dict(os.environ, BRIDGE_VALUE_SOURCE="mapped-value"))
        self.assertEqual(result["result"]["content"][0]["text"], "mapped-value")

    def test_concurrent_invocations(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(lambda n: self.call("echo", {"n": n}, server="http"), range(8)))
        self.assertEqual([json.loads(r["result"]["content"][0]["text"])["n"] for r in results], list(range(8)))

    def test_malformed_response_is_bounded(self):
        result = subprocess.run([str(CLI), "--config", str(self.config), "call", "local", "malformed", "--stdin", "--timeout", "0.5"],
                                input="{}", capture_output=True, text=True, timeout=4)
        self.assertEqual(result.returncode, 3)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assert_reaped()
        self.call("malformed", server="http", code=3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
