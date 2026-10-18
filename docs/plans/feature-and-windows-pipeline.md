# Platform pipeline: macOS Electron and Windows candidate

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

Windows has an unsigned x64 source candidate. Its `package:win` command
configures NSIS and portable executables, and `.github/workflows/windows.yml`
defines typecheck, focused tests, packaging and isolated demo/single-instance
smoke steps. This workflow has not yet been confirmed green. The candidate
supports local CLI data, Codex browser sign-in through the installed CLI,
OpenRouter, one-time OpenAI/Anthropic API billing keys, the tray and side notch.
Claude Desktop, Antigravity Desktop and Grok Bot Desktop account connections are
unavailable. Preferences, history and sanitized billing snapshots use
`%APPDATA%\MeterUsage`, defaulting to the user's `AppData\Roaming` location.

Do not claim Windows release support from source or workflow configuration.
Native GUI/provider behavior, installer acceptance and signing remain unproven.
See [ADR 0033](../adr/0033-windows-desktop-candidate.md) for the scope and
release evidence required.

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
4. Windows candidate: confirm the workflow on the exact candidate revision,
   then record native Windows startup, settings, provider/offline, persistence,
   tray/notch and PNG-sharing checks, plus installer install/uninstall evidence.
   Signing and publication are separate gates. An unsigned package or passing
   workflow alone does not close this stage.

The original [ambient ETA](../mockups/01-time-to-empty.md),
[burn attribution](../mockups/02-burn-attribution.md) and
[pace-alert](../mockups/03-pace-alerts.md) concepts remain design history.
They do not create a new feature wave or version schedule for this migration.

See [the migration plan](macos-electron-migration-plan.md),
[provider marks](../adr/0002-provider-marks-stay.md) and
[privacy](../PRIVACY.md).
