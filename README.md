# MCP Bridge

MCP Bridge is a command-line client for macOS and Linux, with an optional native macOS app. It discovers and calls tools exposed by Model Context Protocol (MCP) servers. The CLI and app use the same Swift core.

The app can keep a server session open and let the CLI use that session over a private Unix-domain socket. The CLI can also connect directly when asked. This keeps the choice of execution environment visible: shared calls run in the app's environment, while direct calls run in the CLI's environment.

## What it supports

- CLI: macOS or Linux
- Native desktop app: macOS 13 or later
- MCP servers over stdio and Streamable HTTP
- Tool discovery, schema inspection, and tool calls
- Optional saved tool catalogs for offline inspection
- Named credentials from macOS Keychain or environment variables (environment references work on Linux)
- App-owned persistent sessions, with explicit direct and shared-session CLI modes

Resources, prompts, subscriptions, legacy SSE, OAuth login, and automatic updates are outside the current scope. The bridge does not sandbox upstream server programs.

## Build from source

You need Swift 6.2 or later. The first build resolves the pinned Swift package dependencies and needs network access. On Linux, SwiftPM builds the CLI and shared core; the SwiftUI desktop app is included only in macOS builds.

```sh
swift build
swift test
python3 Tests/integration.py
```

The persistent desktop-session checks are macOS-only:

```sh
python3 Tests/persistent.py
```

To create a local app bundle and CLI distribution:

```sh
swift build -c release
python3 scripts/package.py --skip-build --destination ./dist
```

The packaging script creates a macOS app distribution and requires macOS. On Linux, run `swift build` to produce the CLI. Public macOS distribution requires your own Developer ID signing and notarization setup. See [Building and packaging](docs/building.md).

## Try the CLI

The CLI uses a version 1 JSON profile. Example profiles are in [`examples/`](examples/); the demo-profile script makes a local profile for the fixture server.

```sh
./.build/debug/mcp-bridge --config ./examples/local.profile.json servers list
./.build/debug/mcp-bridge --config ./examples/local.profile.json tools list demo
./.build/debug/mcp-bridge --config ./examples/local.profile.json tools describe demo echo
printf '%s' '{"message":"hello"}' | \
  ./.build/debug/mcp-bridge --config ./examples/local.profile.json \
  call demo echo --stdin
```

Use `mcp-bridge --help` for the full command syntax. Calls accept one JSON object from `--stdin` or `--args-file`. Operational output is one JSON document on stdout; diagnostics go to stderr.

## Sessions and safety

The first app launch has no servers configured and connects to nothing. A server must be added and enabled by the user. Shared sessions close when the app quits. `--session` requires an open app session; `--direct` explicitly requests a separate connection. The CLI does not silently switch routes after a failure, and the bridge never retries tool calls automatically.

Profiles store credential references, not resolved secret values. On Linux, use environment references; Keychain storage and the app's shared sessions are macOS-only. Avoid putting secrets in command arguments or URL query strings: these are ordinary configuration and can appear in profile exports. Upstream server programs are trusted executables; only configure servers you trust. Read [Security notes](docs/security.md) before using shared sessions or remote endpoints.

Windows is not supported yet. The CLI currently relies on POSIX process and Unix-socket APIs.

## Project notes

- [CLI and profile guide](docs/usage.md)
- [Architecture](docs/architecture.md)
- [Building and packaging](docs/building.md)
- [Contributing](CONTRIBUTING.md)
- [Third-party licenses](THIRD_PARTY_NOTICES.txt)

This repository does not currently include a project license. Until one is added, no open-source reuse terms are granted for MCP Bridge itself. Third-party dependencies remain under their own licenses, listed in `THIRD_PARTY_NOTICES.txt`.
