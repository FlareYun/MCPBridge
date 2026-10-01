# Building and packaging

## Requirements

- macOS or Linux for the Swift CLI
- Windows with Node.js 20 or later for the Windows CLI
- macOS 13 or later for the desktop app and macOS packaging script
- Swift 6.2 or later (the supplied version was tested with Swift 6.3)
- Network access on the first build to resolve Swift package dependencies
- Python 3 for the packaging script

## Build and verify

Run from the repository root:

```sh
swift build
```

Linux builds include the Swift CLI and shared core without the GUI target. Windows uses the Node.js client in `windows/` because the Swift transport dependency does not currently build on Windows.

## Windows CLI

Run from the repository root in PowerShell:

```powershell
npm install
node .\windows\mcp-bridge.mjs --help
```

To put `mcp-bridge` on your PATH for this checkout, run `npm link` from the repository root. The CLI reads its default profile from `%APPDATA%\MCP Bridge\profile.json`; use `--config` to select another file. The Node package uses the official MCP TypeScript client, pinned in `package-lock.json`.

To build a release binary and package a local distribution:

```sh
swift build -c release
python3 scripts/package.py --skip-build --destination ./dist
```

The packaging script creates the macOS app bundle, standalone CLI, source archive, and third-party notices. The included local app is ad-hoc signed. Public distribution outside a development machine requires a Developer ID certificate and Apple's notarization process. The current macOS package targets Apple Silicon.
