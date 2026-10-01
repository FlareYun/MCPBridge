# Building and packaging

## Requirements

- macOS 13 or later
- Swift 6.2 or later (the supplied version was tested with Swift 6.3)
- Network access on the first build to resolve Swift package dependencies
- Python 3 for the integration helpers and packaging scripts

## Build and verify

Run from the repository root:

```sh
swift build
swift test
python3 Tests/integration.py
python3 Tests/persistent.py
```

The fixture integration test uses a temporary local server. Persistent-session coverage launches the app and needs a graphical login session and Unix-domain socket support.

To build a release binary and package a local distribution:

```sh
swift build -c release
python3 scripts/package.py --skip-build --destination ./dist
```

The packaging script creates the app bundle, standalone CLI, examples, source archive, and third-party notices. The included local app is ad-hoc signed. Public distribution outside a development machine requires a Developer ID certificate and Apple's notarization process. The current package targets Apple Silicon.

## UI verification helper

`scripts/verify-ui.py` runs an isolated verification harness against the debug app build. It checks discovery and execution, responsiveness during a slow call, and cancellation. It renders the app window for inspection; it is not a full mouse-and-keyboard automation suite.
