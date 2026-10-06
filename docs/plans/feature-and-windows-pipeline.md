# Platform pipeline: macOS Electron, Windows paused

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

Windows implementation, installers, CI, testing and releases are paused until
a test machine is available. There is no Windows support claim or release
schedule. Portable shared source does not establish Windows behavior.

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
