# ADR 0045: Move the Swift app to legacy/swift and out of CI

- Status: Accepted
- Date: 2026-11-03
- Amends: [ADR 0024](0024-electron-primary-swift-retirement.md) (source
  location and CI), [ADR 0009](0009-prebuilt-bundle-default.md) and
  [ADR 0034](0034-electron-beta-default.md) (`--build-from-source`)

## Context

Electron is the only offered app and the only feature target (ADRs 0024 and
0034). The Swift package still sat at the repository root, CI still built and
tested it on macOS for every change, and `Scripts/make-app.sh` still carried a
Swift compile mode. Contributors and agents kept treating `swift build` and
`swift test` as required checks for Electron work. The root `Tests/` folder also
collided with Electron's `tests/` on case-insensitive macOS file systems.

## Decision

Move the whole Swift app build under `legacy/swift/`:

- `Package.swift`, `Sources/`, `Tests/MeterUsageTests/` and the app
  `Info.plist` (`legacy/swift/Resources/Info.plist`);
- the Swift-only scripts: `legacy/swift/Scripts/make-app.sh` (source bundle
  build, output in `legacy/swift/dist/`), `make-preview-app.sh` and
  `trace-codex.py`;
- the Swift guide and reporting notes, now `legacy/swift/README.md` and
  `legacy/swift/REPORTING.md`.

`Scripts/make-app.sh` only downloads and verifies the prebuilt app. Its
`--build-from-source` option exits with status 2 and names the legacy script.
CI drops the macOS `swift build`/`swift test` job and runs the installer script
tests (`tests/scripts/make-app-tests.sh`) in the Linux job instead.

Electron's shared inputs stay where they are: `Resources/` icons and provider
marks, `Scripts/electron/desktop-keychain.swift`,
`Scripts/electron/export-symbols.swift` and the icon generators. Electron tests
use their own copies of the three provider fixtures they read
(`tests/fixtures/providers/`), so nothing outside `legacy/` depends on it.

## Consequences

- Only changes inside `legacy/swift/` need the legacy checks:
  `swift build --package-path legacy/swift` and
  `swift test --package-path legacy/swift`, run on macOS 13 or later. Nothing
  enforces them, so the legacy tree can stop building without notice.
- The legacy source and the published Swift 0.2.41 release stay retrievable,
  which satisfies the archive part of ADR 0024's retirement conditions. Deleting
  `legacy/swift/` remains a separate change under those conditions.
- The legacy Swift test of the installer script was removed. The shell test
  covers the same cases and now runs in CI.
- Historical ADRs, plans and changelog entries keep the old root paths as
  written.
