# Platform pipeline: macOS Electron, Windows on CI

The earlier React Native/Expo spike, Tauri fallback and Windows-first rollout
are superseded by [ADR 0010](../adr/0010-macos-typescript-electron.md), accepted
on 2026-10-06. ADR 0002 is already assigned to provider marks and must remain
unchanged.

## Current direction

Port the macOS app and schema-1 JSON CLI to TypeScript, Electron and React with
pnpm, Vite+, Tailwind, Vitest and electron-builder. Keep existing provider
marks, measured burn, pacing/alerts, multiple accounts, JSON/history formats
and verified prebuilt installation. The retained Swift app is the compatibility
oracle and rollback path.

Windows work resumed on 2026-11-01 under [ADR 0038](../adr/0038-windows-ci-test-machine.md),
by maintainer direction. A GitHub Actions `windows-latest` runner is the test
machine; there is still no physical Windows PC. Windows support claims are
limited to what that job records. Portable shared source alone does not
establish Windows behavior.

## Windows stages

1. Platform foundation and a CI job that packages and smoke-tests the unsigned
   build. Implemented.
2. Windows updater: installer asset, GitHub SHA-256 digest verification and the
   existing automatic-install deferral. Implemented under
   [ADR 0039](../adr/0039-windows-updater.md); CI checks the installer flags and relaunch.
3. Windows desktop account connections (DPAPI, read-only `node:sqlite`, Windows
   paths) with synthetic fixtures; marked unverified against real accounts.
   Implemented under [ADR 0040](../adr/0040-windows-desktop-connections.md).
4. Unsigned GitHub pre-release and user docs, after the CI smoke run passes.
   GitHub's `latest` stays on the stable release. Published as
   [0.3.0-beta.13](https://github.com/tilorahdotco/meterusage/releases/tag/v0.3.0-beta.13) on 2026-11-01.

CI proves typecheck, Windows-safe tests, a production build, packaging and a
packaged smoke run (headless JSON, a demo GUI that stays up, screenshots). It
does not prove real accounts, installers or upgrades, SmartScreen, login items,
notifications, display layouts or user input. See ADR 0038 for the full list.

## Migration gates

1. Source parity: synthetic provider/calculation/account/history/schema tests,
   TypeScript checks, production build and independent source review.
2. Native parity: separate macOS candidate with identity/digest/signature,
   headless JSON, native launch and user-path proof, including two
   different-height notch captures. Record package size, idle RSS and scan
   timing. Missing proof leaves this gate open.
3. Repository delivery: exact-base/head independent review, required forge
   gates and guarded merge. Source-only draft delivery may record open native
   gates; it does not authorize cutover or release.

The original [ambient ETA](../mockups/01-time-to-empty.md),
[burn attribution](../mockups/02-burn-attribution.md) and
[pace-alert](../mockups/03-pace-alerts.md) concepts remain design history.
They do not create a new feature wave or version schedule for this migration.

See [the migration plan](macos-electron-migration-plan.md),
[provider marks](../adr/0002-provider-marks-stay.md) and
[privacy](../PRIVACY.md).
