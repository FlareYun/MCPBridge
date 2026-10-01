# Contributing

Thanks for taking a look at MCP Bridge. Keep changes focused and describe user-visible behavior in plain language.

Before opening a change, build and run the relevant checks from [Building and packaging](docs/building.md). For changes to profile handling, transport behavior, or sessions, include coverage that exercises both the expected result and the failure case where practical.

Please avoid including real profiles, credentials, service data, or personal verification captures in commits. Example profiles should use local fixtures or placeholder endpoints and must not contain secrets.

When changing third-party dependencies, update `Package.resolved` and keep the applicable license notices in `THIRD_PARTY_NOTICES.txt` current.

There is no contribution agreement or project license in this repository yet. If you want to submit a substantial change, open an issue or discussion first so its direction and licensing can be settled.
