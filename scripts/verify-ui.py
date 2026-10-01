#!/usr/bin/env python3
"""Launch the DEBUG app with a disposable fixture profile and collect its own renders."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--destination", default=str(ROOT / ".build/ui-verification"))
args = parser.parse_args()
directory = Path(args.destination).resolve()
directory.mkdir(parents=True, exist_ok=True)
profile = directory / "fixture.profile.json"
profile.write_text(json.dumps({"version": 1, "servers": [{"id": "demo-tools", "transport": "stdio", "command": sys.executable,
                    "arguments": [str(ROOT / "Tests/Fixtures/server.py")]}]}))
subprocess.run([str(ROOT / ".build/debug/MCPBridgeApp"), "--config", str(profile), "--verify-ui", str(directory)], check=True, timeout=30)
report = json.loads((directory / "report.json").read_text())
print(json.dumps(report, indent=2))
if report["status"] != "passed":
    sys.exit(1)
