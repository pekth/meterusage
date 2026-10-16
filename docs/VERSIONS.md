# MeterUsage versions and repository strategy

Electron is the sole active target for new features. Electron **0.3.0-beta.1,
build 54** is an opt-in public prerelease. Swift **0.2.41** remains the stable
download and rollback reference. The beta does not replace the stable updater.

## Current layout and status

| Area | Retained Swift | Electron beta |
| --- | --- | --- |
| Development | Critical fixes and transition compatibility | All new features |
| Source | `Sources/`, `Tests/`, `Package.swift` | `src/`, `tests/`, `package.json` |
| Download version | 0.2.41 | 0.3.0-beta.1, build 54 |
| Source metadata | 0.2.41 | Manifest retains 0.2.41; packaging overrides it |
| User installation | Pinned Swift ZIP via `Scripts/make-app.sh` | Manual signed/notarized Apple silicon ZIP |
| Updates | Stable release only | Manual beta downloads; no beta updater |
| Guide | [Swift](swift/README.md) | [Beta installation and limits](BETA.md), [Electron](electron/README.md) |

Build 54 was built from `6ce695324e54bb09bf6e5ab36fd4733875c94427`.
The beta tag also carries refreshed documentation and screenshots; its
executable inputs are unchanged. Its Settings footer still incorrectly displays
`0.2.41`. See [known limits and verification](BETA.md#known-limits).

The beta source and signed bundle have separate recorded checks. Native
acceptance remains incomplete and is disclosed for this opt-in prerelease.
Stable cutover, stack merge and Swift source retirement remain separate work.

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
   The opt-in beta is published separately; stable cutover still requires these checks.
4. Preserve the retrievable legacy source revision and matching release artifact,
   then remove old-app-only source, tests, build steps and obsolete CI references
   from the active branch in a reviewed change. No second repository is needed.

Keep `Scripts/electron/desktop-keychain.swift`,
`Scripts/electron/export-symbols.swift`, required `Resources/` assets and shared
fixtures/contracts used by Electron. Trace dependencies before removing legacy
files. Retiring the Swift application does not mean deleting all Swift files.

Source removal, workflow changes and stable cutover remain pending. Publishing
the manual beta does not change the stable download contract.

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
