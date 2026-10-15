# MeterUsage versions and repository strategy

Electron is the sole active target for new features. The published Swift app is
frozen as legacy support and rollback during migration. Both currently say
`0.2.41`. That shared number does not establish
build identity, publication, installation or native acceptance. The candidate
is not a released v2.1. This comparison describes source at revision
`605f1c4328eed6d4f793fcee0937a8d2e1659f6d` with the accompanying candidate changes.

## Current layout and status

| Area | Retained Swift | Electron candidate |
| --- | --- | --- |
| Development | Critical fixes and transition compatibility only | All new features |
| Source and manifest | `Sources/`, `Tests/`, [Package.swift](../Package.swift) | `src/`, `tests/`, [package.json](../package.json) |
| Version | 0.2.41 in [Info.plist](../Resources/Info.plist) | 0.2.41 in package metadata |
| Build | `swift build`; explicit `./Scripts/make-app.sh --build-from-source` | `pnpm build`; macOS `pnpm package:mac` |
| Default user download | Pinned published Swift ZIP via `./Scripts/make-app.sh` | No published candidate download route |
| Build/install evidence | Separate from source and release metadata | Private build and installation receipts exist; complete native acceptance remains open |
| Guide | [Swift](swift/README.md) | [Electron](electron/README.md) |

A source check does not prove a signed bundle. A built bundle does not prove
installation or launch. A tag does not create a GitHub Release, and an uploaded
asset does not prove native runtime acceptance. Current public availability and
installed state need their own observation; this documentation does not refresh
them. The pinned Swift download contract remains unchanged.

## Repository coexistence and app isolation

Both implementations remain in one repository during migration. The intended
end state is one Electron app. Two normally installed apps cannot safely share
the present identity and data locations.
[ADR 0010](adr/0010-macos-typescript-electron.md) retains `MeterUsage.app`,
executable `meterusage`, bundle ID `dev.meterusage.app`, preference keys and
history/archive formats. There is no automatic cutover or new durable-data
migration. Swift remains the behavior reference and rollback path.

Only documented isolated demo/test profiles are supported for candidate QA.
They isolate preferences, history, caches and Electron state; live test modes
retain only their explicitly permitted provider access. See
[Electron isolated QA](electron/README.md#isolated-qa) and [privacy](PRIVACY.md).
A distinct app ID and data root would require a later decision before true
side-by-side installation. A single-app replacement can retain the existing
identity after its compatibility and update/rollback checks pass. This decision
does not rename apps or perform the replacement.

<a id="proposed-same-repository-strategy"></a>
## Accepted development and retirement strategy

The owner selected one active implementation in
[ADR 0024](adr/0024-electron-primary-swift-retirement.md). This supersedes the
earlier proposal to maintain two editions as a long-term direction. ADR 0010's
data compatibility, native acceptance and no-automatic-cutover rules still apply.

1. Freeze new Swift features now. Route feature work to Electron; keep Swift for
   critical maintenance, transition compatibility and rollback.
2. Close agreed setup/parity gaps and complete source/native acceptance on the
   exact Electron candidate, including preserved saved data and measured native
   performance. Keep intentional UI removals intact.
3. Verify deliberate update and rollback before public cutover. Preserve the
   current Swift download and installer contract until the replacement is ready.
   Release publication remains subject to the existing release holds.
4. Preserve the retrievable legacy source revision and matching release artifact,
   then remove old-app-only source, tests, build steps and obsolete CI references
   from the active branch in a reviewed change. No second repository is needed.

Keep `Scripts/electron/desktop-keychain.swift`,
`Scripts/electron/export-symbols.swift`, required `Resources/` assets and shared
fixtures/contracts used by Electron. Trace dependencies before removing legacy
files. Retiring the Swift application does not mean deleting all Swift files.

Only the development guidance is applied here. Source removal, workflow changes,
version assignment and cutover remain pending.

### Update-channel prerequisites

Both the [Swift updater](../Sources/MeterUsage/Services/UpdateChecker.swift) and
[Electron updater](../src/main/updater.ts) request GitHub's `/releases/latest`
endpoint and expect an asset named `MeterUsage-<version>.zip`. Electron's release
parser accepts only numeric stable versions such as `0.2.41`; it rejects
prerelease tags. Neither updater currently selects an edition-specific channel.

An optional Electron beta channel needs explicit routing, prerelease parsing
and matching asset validation. It does not require a permanent second edition.
Preserve the existing Swift asset contract for installed clients. Renaming ZIPs
or publishing a prerelease alone does not implement this routing. Verify that
stable clients receive only the intended tested replacement before changing
release assets. The current updater is unchanged.

No competitor feature or parity fix is implemented by this documentation change.
See the [candidate gaps](electron/README.md#known-parity-gaps),
[contribution routing](../CONTRIBUTING.md) and [accepted decision index](adr/README.md).
