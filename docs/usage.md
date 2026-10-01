# CLI and profile guide

MCP Bridge profiles are JSON files in the bridge's own version 1 format. They are not drop-in Codex or other client's MCP configuration files. The desktop app uses `~/Library/Application Support/MCP Bridge/profile.json` by default; pass `--config /path/to/profile.json` to use another profile.

## Common commands

```sh
mcp-bridge --config ./profile.json servers list
mcp-bridge --config ./profile.json server test SERVER_ID
mcp-bridge --config ./profile.json tools list SERVER_ID
mcp-bridge --config ./profile.json tools describe SERVER_ID TOOL_NAME
mcp-bridge --config ./profile.json call SERVER_ID TOOL_NAME --args-file ./arguments.json
cat ./arguments.json | mcp-bridge --config ./profile.json call SERVER_ID TOOL_NAME --stdin
```

Use exactly one input source for a call. The input must be a JSON object no larger than 16 MiB. Tool calls are never retried automatically. A timeout or lost connection does not prove that the remote operation had no effect; check the service before deciding what to do next.

The default operation timeout is 60 seconds, including connection setup. Set `--timeout` to override it; valid values are greater than zero and no more than 86400 seconds. Waiting for stdin is outside that deadline. SIGINT and SIGTERM cancel the current operation.

The CLI writes one JSON document to stdout for operational commands. Diagnostics go to stderr. Exit codes are 0 for success, 2 for invalid input/configuration, 3 for connection/protocol/permission failures or cancellation, 4 when the tool result reports `isError: true`, and 5 for timeout.

## Discovery and cached catalogs

`tools list` and `tools describe` use a matching saved catalog when available, otherwise they discover tools live. Add `--cached` to forbid a connection, or `--live` to explicitly contact the server and refresh the catalog after a nonempty result. These flags do not apply to `call`.

```sh
mcp-bridge --config ./profile.json tools list SERVER_ID --cached
mcp-bridge --config ./profile.json tools list SERVER_ID --live
```

Catalogs are metadata, not proof that a server is currently available or that a call is authorized. They do not expire automatically. Refresh after changing upstream tools, accounts, permissions, or credentials. Catalog files live in `tool-cache/` beside the profile and can be deleted to clear them.

Servers that advertise `tools.listChanged` may publish tools after initialization. Discovery waits up to `discoveryWait` seconds (10 by default). Set it to 0 to disable waiting. A successful initialization test only confirms the handshake; it does not guarantee that the server has published tools.

## Shared and direct sessions

When a profile entry has `keepConnected: true`, live CLI operations use the app's session by default. `--session` requires that route. `--direct` opens a separate connection and is mutually exclusive with `--session`. Cached catalog reads do not connect, regardless of route.

The app owns shared server processes and closes sessions when it quits. Calls to a shared server are serialized. Cancellation, timeout, or transport failure may close its session; reconnect it in the app before continuing. The bridge will not switch from a shared session to a direct connection on its own.

## Credential references

Profiles may point to named values stored in Keychain or environment variables. For example:

```json
{
  "version": 1,
  "servers": [{
    "id": "remote-demo",
    "transport": "http",
    "enabled": true,
    "url": "https://example.com/mcp",
    "bearerToken": {"source": "keychain", "name": "demo-token"},
    "headers": {
      "X-Project": {"source": "environment", "name": "PROJECT_ID"}
    }
  }]
}
```

Use the app's Credentials screen to create Keychain entries. Environment references can be useful for unattended CLI use. GUI apps opened from Finder may not inherit shell environment variables. See [Security notes](security.md) before putting credentials or remote services in a profile.
