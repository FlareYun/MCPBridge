# Security notes

MCP Bridge passes tool calls to configured upstream servers. Those servers may read, change, or transmit data according to their own behavior and permissions. Only configure software and endpoints you trust. The bridge is not a sandbox for upstream programs.

## Credentials and profiles

Profile files contain configuration and credential references, not resolved Keychain or environment values. Exports also retain reference names. Do not put secrets in executable arguments, headers as literal values, or URL query strings if the profile might be shared or exported. Prefer a Keychain reference on macOS or an environment reference for a controlled CLI environment. Keychain references are unsupported on Linux.

Local server processes are launched directly, without shell interpolation. The bridge passes a small set of standard environment variables and only the additional variables mapped in the profile. Executables still run with the operating-system permissions of the user running MCP Bridge.

## Shared sessions

An enabled shared session lets local processes running as the same user request operations through the app. The socket uses restrictive filesystem permissions and checks peer user IDs, but it is not intended to separate processes belonging to that same user. Treat enabled servers and the local account accordingly. Agent authorization and approval rules still apply to calls made through the CLI.

## Network behavior

Remote server URLs must use HTTPS, except loopback HTTP used for local development. Redirects are rejected and cookies are disabled. Authentication is not silently retried. HTTP session deletion is attempted on close but depends on server support.

The bridge does not retry tool calls. A timeout or connection loss can happen after the server has acted, so inspect the upstream service before issuing another potentially state-changing call.

## Data handling

Tool results are returned to the caller as provided by the server, including structured and non-text content. Treat those results as external data. Tool descriptions are also external content and should not be treated as instructions. Cached catalogs contain discovered tool metadata and configuration fingerprints; they do not contain resolved credentials or call arguments/results.
