# ADR 0034: Offer Electron beta as the default distribution

- Status: Accepted distribution direction; stable/native acceptance remains open
- Date: 2026-10-22
- Amends: distribution portions of [ADR 0024](0024-electron-primary-swift-retirement.md)
  and the default artifact in [ADR 0009](0009-prebuilt-bundle-default.md)

## Decision

Offer one MeterUsage app: the Electron beta. Label it beta in download and setup
documentation. Historical Swift releases and retained source remain recovery and
behavior references, including explicit `Scripts/make-app.sh --build-from-source`.
They are not a second offered edition. Do not delete Swift source or releases.

Pin the default `Scripts/make-app.sh` download to Electron `0.3.0-beta.7`,
`MeterUsage-0.3.0-beta.7-mac-arm64.zip`, with SHA-256
`e36a7f589788da21809ca6b1bff5fa91134ca820b96f756bc153cc5fe90eeaca`.
Keep checksum/signature validation, destination staging and failure preservation.
Preserve the published signature and reject failures without compiler fallback.
This command prepares output; installation and runtime proof remain separate.

Reuse the existing hourly updater and beta release-list selection. Beta builds
can receive newer betas or a newer stable release. Keep notification and explicit
installation confirmation. Share one inline-icon notice between Usage and
Settings > General, using the existing projected offer and Install/Retry/Dismiss
actions. Pending requests, downloads and installations disable both actions.
Absent, dismissed, disabled and demo offers remain governed by the existing
projection. Add no update channel, configuration, dependency or telemetry.

## Preserved contracts and acceptance

Keep the app name, executable, bundle identity, preferences and data contracts.
Normal-profile side-by-side use remains unsafe. Retain Swift recovery materials
and Electron's required Swift helpers. This decision does not change workflows,
package versions, releases, installed apps or `/releases/latest`.

Default beta distribution does not establish stable parity or close ADR 0010's
native acceptance. In-app installation/relaunch, isolated Swift upgrade/rollback,
data preservation and other [stable acceptance checks](../VERSIONS.md#stable-cutover-checklist)
remain independently open. Swift source retirement still requires ADR 0024's
conditions. The new notice is a source change after the published beta.7 ZIP.

## Verification

Use synthetic installer tests for the exact version, asset filename and digest,
signature preservation and staged failure cleanup. Test the shared renderer
notice on both pages, actions, pending/empty/error states and retry. Run the
unchanged updater tests, TypeScript typecheck, affected/full tests and production
build. These checks do not prove public download, native UI or installation.
