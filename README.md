# MCP Bridge

MCP Bridge is a command-line client for macOS, Linux, and Windows, with an optional native macOS app. It discovers and calls tools exposed by Model Context Protocol (MCP) servers. The macOS and Linux CLI use the Swift core; Windows uses the official MCP TypeScript client.

The app can keep a server session open and let the CLI use that session over a private Unix-domain socket. The CLI can also connect directly when asked. This keeps the choice of execution environment visible: shared calls run in the app's environment, while direct calls run in the CLI's environment.

## What it supports

- CLI: macOS, Linux, or Windows
- Native desktop app: macOS 13 or later
- MCP servers over stdio and Streamable HTTP
- Tool discovery, schema inspection, and tool calls
- Optional saved tool catalogs for offline inspection on macOS and Linux
- Named credentials from macOS Keychain or environment variables
- App-owned persistent sessions on macOS

Resources, prompts, subscriptions, legacy SSE, OAuth login, and automatic updates are outside the current scope. The bridge does not sandbox upstream server programs.

## Build from source

You need Swift 6.2 or later for the Swift CLI on macOS/Linux. The first build resolves pinned dependencies and needs network access. On Windows, install Node.js 20 or later and use the TypeScript SDK CLI described below.

```sh
swift build
```

To create a local app bundle and CLI distribution:

```sh
swift build -c release
python3 scripts/package.py --skip-build --destination ./dist
```

The packaging script creates a macOS app distribution and requires macOS. On Linux, run `swift build` to produce the CLI. Public macOS distribution requires your own Developer ID signing and notarization setup. See [Building and packaging](docs/building.md).

### Windows CLI

From the repository root, run these commands in PowerShell:

```powershell
npm install
node .\windows\mcp-bridge.mjs --help
```

To put `mcp-bridge` on your PATH for this checkout, run `npm link` from the repository root. The Windows CLI uses direct server connections and environment-variable credentials. It does not use the macOS app session, Keychain, or saved tool catalogs.

## Try the CLI

The CLI uses a version 1 JSON profile. Add servers in the app or create a profile following the format described in the [CLI and profile guide](docs/usage.md).

```sh
./.build/debug/mcp-bridge servers list
./.build/debug/mcp-bridge tools list SERVER_ID
./.build/debug/mcp-bridge tools describe SERVER_ID TOOL_NAME
./.build/debug/mcp-bridge call SERVER_ID TOOL_NAME --args-file ./arguments.json
```

Use `mcp-bridge --help` for the full command syntax. Calls accept one JSON object from `--stdin` or `--args-file`. Operational output is one JSON document on stdout; diagnostics go to stderr.

## Sessions and safety

The first app launch has no servers configured and connects to nothing. A server must be added and enabled by the user. Shared sessions close when the app quits. `--session` requires an open app session; `--direct` explicitly requests a separate connection. The CLI does not silently switch routes after a failure, and the bridge never retries tool calls automatically.

Profiles store credential references, not resolved secret values. On Linux and Windows, use environment references; Keychain storage and the app's shared sessions are macOS-only. Avoid putting secrets in command arguments or URL query strings: these are ordinary configuration and can appear in profile exports. Upstream server programs are trusted executables; only configure servers you trust. Read [Security notes](docs/security.md) before using shared sessions or remote endpoints.

## Project notes

- [CLI and profile guide](docs/usage.md)
- [Architecture](docs/architecture.md)
- [Building and packaging](docs/building.md)
- [Contributing](CONTRIBUTING.md)
- [Third-party licenses](THIRD_PARTY_NOTICES.txt)

This repository does not currently include a project license. Until one is added, no open-source reuse terms are granted for MCP Bridge itself. Third-party dependencies remain under their own licenses, listed in `THIRD_PARTY_NOTICES.txt`.
