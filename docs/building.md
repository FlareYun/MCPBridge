# Building and packaging

## Requirements

- macOS or Linux for the CLI
- macOS 13 or later for the desktop app and macOS packaging script
- Swift 6.2 or later (the supplied version was tested with Swift 6.3)
- Network access on the first build to resolve Swift package dependencies
- Python 3 for the packaging script

## Build and verify

Run from the repository root:

```sh
swift build
```

Linux builds include the CLI and shared core without the GUI target.

To build a release binary and package a local distribution:

```sh
swift build -c release
python3 scripts/package.py --skip-build --destination ./dist
```

The packaging script creates the macOS app bundle, standalone CLI, source archive, and third-party notices. The included local app is ad-hoc signed. Public distribution outside a development machine requires a Developer ID certificate and Apple's notarization process. The current macOS package targets Apple Silicon.
