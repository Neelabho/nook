# Contributing to Nook

Thanks for helping. Bug reports, ideas, docs fixes and code are all welcome.

## Before you start

- **Bugs**: open an issue using the bug template. Include your macOS version, Mac model and the output of `Nook --self-test` if you can.
- **Features**: open an issue first so we can agree on the approach before you spend time on it. Nook deliberately stays small, private and dependency-free.
- **Security problems**: follow [SECURITY.md](SECURITY.md), not a public issue.

## Development setup

```bash
scripts/test.sh                 # unit + integration tests (Xcode or Command Line Tools)
scripts/stage.sh                # build and launch "Nook Staging" with its own bundle id and data
scripts/probe.sh                # dump a running staging build's live state as JSON
scripts/measure.sh 60 5         # CPU / wake-ups / memory of a running Nook
```

The staging build uses the bundle id `dev.local.nook.staging`, so it never touches the data of your everyday Nook. Run only one of them at a time; both draw a notch panel and compete for ⌥⌘N.

## Project layout

- `Sources/NookCore`: pure logic with no AppKit (Shelf transactions, the notch state machine, the Ollama client, settings, Spotify parsing). **New logic belongs here, with tests.**
- `Sources/Nook`: the AppKit/SwiftUI app shell.
- `Tests/NookCoreTests`: Swift Testing suites.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design and the reasons behind it.

## Pull requests

1. Branch from `main` and keep each PR focused on one change.
2. `scripts/test.sh` must pass. Add tests for new logic in `NookCore`.
3. For UI changes, run the relevant items of the manual checklist in [docs/TESTING.md](docs/TESTING.md) and include a screenshot or short recording.
4. Keep the project's guarantees intact: no third-party dependencies, no telemetry, no new network destinations, no new entitlements without discussion.
5. **Never commit secrets** (Client IDs from your own Spotify app, tokens, signing certificates, `.env` files). CI scans every PR for them.

## Code style

Follow the style of the surrounding code: Swift 6 strict concurrency, small types, comments that explain *why*. Keep user-facing text short and plain.

## Code of conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
