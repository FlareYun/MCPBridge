# CLI and profile guide

MCP Bridge profiles are JSON files in the bridge's own version 1 format. They are not drop-in Codex or other client's MCP configuration files. The macOS app and CLI use `~/Library/Application Support/MCP Bridge/profile.json`; Linux uses `$XDG_CONFIG_HOME/mcp-bridge/profile.json` (or `~/.config/mcp-bridge/profile.json`); Windows uses `%APPDATA%\MCP Bridge\profile.json`. Pass `--config /path/to/profile.json` to use another profile.

## Manage server configurations

Configuration commands work on macOS, Linux, and Windows:

```sh
mcp-bridge --config ./profile.json server add SERVER_ID --server-file ./server.json
mcp-bridge --config ./profile.json server show SERVER_ID
mcp-bridge --config ./profile.json server update SERVER_ID --server-file ./changes.json
mcp-bridge --config ./profile.json server remove SERVER_ID
```

`add` and `update` accept exactly one of `--server-file` or `--stdin`. Input is a single server object, not a complete profile, no larger than 16 MiB. The command supplies the ID; an optional `id` in the input must match it. Unknown fields and invalid types are rejected. These commands accept `--config`, without connection, timeout, catalog, or tool-argument flags.

For a local server, provide `transport: "stdio"`, `command` as the executable path or command name, and `arguments` as an array of strings. For a remote server, provide `transport: "http"` and `url` as the Streamable HTTP endpoint. Remote endpoints require HTTPS; loopback endpoints may use HTTP. Use `environment`, `headers`, and `bearerToken` for credential references rather than secret values.

`add` creates a missing profile and its parent directories. It refuses duplicate IDs. `update` requires an existing entry and changes only supplied fields. Objects such as `environment` and `headers`, and the `arguments` array, are replaced as a whole when supplied. Use `null` to clear `command`, `url`, `workingDirectory`, or `bearerToken`; other fields cannot be null. IDs cannot be renamed through `update`.

Optional fields are `enabled` (default true), `arguments` (empty array), `workingDirectory` (absolute path), `environment` and `headers` (empty objects), `bearerToken`, `timeout` (60 seconds), `discoveryWait` (10 seconds), and `keepConnected` (false). Timeouts must be greater than zero and no more than 86400 seconds; discovery wait allows zero through 86400. Server IDs start with a letter or digit, contain only letters, digits, dots, underscores or hyphens, and are at most 100 characters.

`show` also works for disabled entries and returns the configuration, including credential reference names, under `configuration`. It does not resolve credentials. `remove` deletes only the profile entry; it does not uninstall server software or remove credentials and saved catalogs.

All configuration commands operate locally without launching a server or making a connection. They do not create MCP server implementations. After adding a server, use `server test` and tool discovery to verify the connection separately.

Writes validate the complete profile, take a short exclusive lock, and replace the file atomically. An invalid update leaves the original file unchanged. A busy lock fails promptly; repeat the configuration operation after the other writer finishes. If a process crashes while saving, a `PROFILE_PATH.lock` directory may remain: remove it only after confirming no writer is still running. On macOS/Linux the saved profile has user-only read/write permissions; on Windows it inherits the destination folder's access controls, so choose a private folder.

The updated macOS app reloads external changes while idle. It closes sessions whose saved configuration changed or was removed; reconnect changed servers explicitly in the app. New entries are not automatically connected. Unsaved edits are preserved, and conflicting saves are rejected. An older app does not coordinate with CLI writes: quit it before managing its profile with the new CLI.

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

The Windows CLI always discovers tools live; it does not support `--cached` or `--live` catalog options. It also requires direct connections and does not support `--session`.

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

Use the app's Credentials screen to create Keychain entries on macOS. On Linux and Windows, use environment references. GUI apps opened from Finder may not inherit shell environment variables. See [Security notes](security.md) before putting credentials or remote services in a profile.
