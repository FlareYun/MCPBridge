# Architecture

The project is split into three Swift targets:

- `BridgeCore` owns profile validation, MCP transport, tool discovery, calls, catalog storage, and shared-session IPC.
- `BridgeCLI` is the `mcp-bridge` executable used by agents and shell scripts.
- `BridgeApp` is the macOS interface for editing profiles, managing credentials, inspecting tools, and keeping selected connections open.

Both executable targets depend on `BridgeCore`, so they share the same profile and protocol behavior.

## Connection routes

For a direct operation, the CLI resolves the configured server and connects over stdio or Streamable HTTP. For a shared operation, the CLI sends an operation request to the open app through a Unix-domain socket. The app checks the profile path, server ID, and configuration fingerprint before it uses its existing session.

The app's socket is scoped to the local user, stored in a private directory, and uses peer UID checks. It is not an authentication boundary between mutually trusted processes running as the same user. A server must be explicitly enabled and kept connected before shared calls can use it.

The bridge does not start a TCP listener, launch agent, or background daemon. The configured upstream server may of course make its own network connections.

## Catalogs

After successful nonempty discovery, tool metadata can be saved beside the profile. A fingerprint ties a catalog to the server configuration and credential reference names. The resolved credential values and tool call inputs/results are not written to the catalog. Because the fingerprint cannot see changes behind a credential reference or inside a server binary, cached data can become stale.

## Source map

```text
Sources/BridgeApp/       macOS app
Sources/BridgeCLI/       command-line interface
Sources/BridgeCore/      shared behavior and transport
Tests/                   unit and fixture-based integration coverage
examples/                sample profiles and local demo setup
scripts/                 app packaging and verification helpers
```
