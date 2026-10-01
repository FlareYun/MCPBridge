#!/usr/bin/env python3
"""Create a relocatable demo profile referencing the bundled controlled fixture."""
import json
from pathlib import Path
import sys

here = Path(__file__).resolve().parent
fixture = here / "demo-server.py"
if not fixture.exists():
    fixture = here.parent / "Tests/Fixtures/server.py"
destination = Path(sys.argv[1] if len(sys.argv) > 1 else "demo.profile.json").resolve()
profile = {"version": 1, "servers": [{"id": "demo-tools", "transport": "stdio", "enabled": True,
           "command": sys.executable, "arguments": [str(fixture)], "timeout": 60}]}
destination.write_text(json.dumps(profile, indent=2) + "\n")
destination.chmod(0o600)
print(destination)
