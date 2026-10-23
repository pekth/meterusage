# ADR 0024: Develop Electron and retire the legacy Swift app in stages

- Status: Accepted development direction; distribution amended by ADR 0034; source retirement and stable cutover pending
- Date: 2026-10-14
- Amends: [ADR 0010](0010-macos-typescript-electron.md), for ongoing development and eventual Swift retirement only

## Distribution amendment (2026-10-22)

[ADR 0034](0034-electron-beta-default.md) supersedes this record's Swift-default
and optional-beta distribution statements. Electron beta is now the sole offered
app and default installer target; historical Swift source/releases remain
recovery/reference material. The original decision below records the earlier
direction. Source retirement and stable/native acceptance remain open. The beta
updater now uses the release list as documented in [versions](../VERSIONS.md#update-channels).

## Decision

Electron is the sole active target for new MeterUsage features. Freeze the
legacy Swift app as a behavior reference and rollback option. Limit Swift app
changes to critical fixes and compatibility work needed for the transition.
Do not maintain two feature roadmaps or require two permanent app editions.

Keep both source trees during migration. Remove the legacy app implementation
from the active branch only after the acceptance and cutover conditions below
pass. Preserve a retrievable source revision and its matching release artifact
before removal. Git history and the retained release provide the archive;
an additional repository is unnecessary.

The retained Swift baseline is
`4b913db3a3a8eb2602296489872af2ecaa5d0530`. The published Swift 0.2.41 ZIP
remains the default download until a verified Electron release replaces it.
The Electron candidate still has source version 0.2.41 and incomplete native
acceptance. This decision does not publish or install a release.

## Retirement conditions

1. Finish the agreed provider setup and parity work. Verify the affected paths
   against the [candidate gaps](../electron/README.md#known-parity-gaps).
   Intentional changes, including removal of pinned details and dot designs,
   remain intentional.
2. Complete ADR 0010's source and native acceptance on the exact candidate.
   Preserve saved accounts, preferences, history and schema-1 output. Exercise
   launch, relaunch, offline behavior, native controls, sharing and updates;
   capture different-height notch cards with fixed anchors. Record package
   size, idle memory and startup/scan performance without inventing pass limits.
3. Verify a deliberate update from the published Swift app to the intended
   Electron artifact, and verify rollback with preserved data. Keep the stable
   download and existing client asset contract until the replacement is ready.
   Existing publication and cutover holds remain in force.
4. Confirm that the exact legacy source and release remain retrievable. Then
   remove old-app-only `Sources/`, `Tests/`, `Package.swift`, build steps and
   obsolete CI references in an independently reviewed change. Trace consumers
   before removal and retain any shared fixture, asset or contract still used.
   Verify Electron build, packaging and the affected user paths afterward.

## Swift that stays

Retiring the Swift app does not remove every Swift file. Electron's current
build still uses [desktop-keychain.swift](../../Scripts/electron/desktop-keychain.swift)
and [export-symbols.swift](../../Scripts/electron/export-symbols.swift).
Keep those helpers and their required assets in `Resources/` unless a separate,
verified replacement removes the dependency. Do not delete by file extension.

## Identity and distribution

The intended end state is one app. ADR 0010's app identity, data compatibility
and no-automatic-cutover requirements remain intact. Normal-profile parallel
installs remain unsupported. A separate identity and data root are only needed
if simultaneous installs become a separately chosen requirement.

Beta distribution is optional and still needs explicit updater routing. Both
current updaters request `/releases/latest` and expect
`MeterUsage-<version>.zip`; Electron rejects prerelease tags. Renaming assets
alone does not create a channel. See [version strategy](../VERSIONS.md).

## Consequences

New work has one implementation target. Swift remains available while migration
proof is incomplete, but gains no parallel feature roadmap. Documentation
labels development status separately from the published download. This decision
does not itself change source files, workflows, versions, data or installed apps.
