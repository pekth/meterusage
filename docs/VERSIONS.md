# MeterUsage versions

Electron 0.3.0-beta.6, build 75, is the opt-in public beta. Swift 0.2.41 stays
stable and remains the updater/installer download. New features target Electron;
Swift is retained for critical maintenance and rollback.

| Version | Source | Download |
| --- | --- | --- |
| Electron beta | [v0.3.0-beta.6](https://github.com/pekth/meterusage/tree/v0.3.0-beta.6) | [Manual signed/notarized Apple silicon ZIP](BETA.md) |
| Swift stable | Retained `Sources/` and [v0.2.41](https://github.com/pekth/meterusage/tree/v0.2.41) | [Swift guide](swift/README.md) |

The Electron source stack is on main through [PR #76](https://github.com/pekth/meterusage/pull/76),
merge `0d514dd`. That integration preserves the newer Swift reporting source and
adds account-isolated quota activity and Muse Stop/Start history preservation.
These later fixes are not included in beta.6. The beta tag includes release
documentation and build 61 synthetic screenshots;
its executable inputs match build source
`023b753cfa1c248774efecb28a1770ee8de0950b`. The beta's package version was set
at packaging time; its source manifest retains 0.2.41. Settings shows the
running bundle version. See [known beta limits](BETA.md#known-limits).

The apps share an identity and normal data locations. Quit one before replacing
it and preserve a rollback copy. Do not run both against a normal profile.
Stable cutover and Swift retirement remain separate work, defined in the
[beta repository strategy](https://github.com/pekth/meterusage/blob/v0.3.0-beta.6/docs/VERSIONS.md).

## Update channels

Swift and stable Electron builds read GitHub's `/releases/latest`, which never
returns prereleases, and expect `MeterUsage-<version>.zip`. Electron builds whose
version ends in `-beta.N` read the release list instead, skip drafts and pick the
newest release with a verified `MeterUsage-<version>.zip` or
`MeterUsage-<version>-mac-arm64.zip` asset. A final release outranks its betas,
so beta users are offered the stable release that follows. Beta 4 and earlier
predate this and need one manual install.

## Stable cutover checklist

Stable Electron publication is pending. Source inspection establishes the
following requirements; it does not prove an installed Swift upgrade.

- Publish the intended stable ZIP as `MeterUsage-0.3.0.zip`, with GitHub's
  `sha256:` asset digest. The Swift 0.2.41 updater selects only
  `MeterUsage-<version>.zip`; an asset named only
  `MeterUsage-0.3.0-mac-arm64.zip` cannot install through that updater.
  `/releases/latest` must select the stable release. Keep prereleases outside
  that endpoint until cutover is approved.
- Preserve `MeterUsage.app`, executable `meterusage`, bundle ID
  `dev.meterusage.app`, the native preferences domain and
  `Library/Application Support/MeterUsage`. Electron reads existing known
  preference keys, including JSON stored as UserDefaults Data for managed
  accounts. It shares `durable-daily-history.json` and `quota-archive.json`;
  archive dates retain Swift's 2001 reference epoch. There is no bulk data
  migration. Electron adds its own state and derived quota-activity data.
- Test in a separate macOS user account or VM with synthetic preferences,
  managed accounts and history. Start the published Swift 0.2.41 app, exercise
  its actual download/install path against the intended Electron artifact,
  then verify launch, settings, account isolation and history after relaunch.
  On 2026-10-22 this native test was blocked: the available Mac had no separate
  test user or detected VM. An isolated Electron demo profile cannot test
  Swift's normal UserDefaults and updater path.
- Check the installed signature after the Swift updater runs. Its install
  script clears extended attributes and runs
  `codesign --force --deep -s -` on the replacement. This can replace the
  Electron Developer ID signature with an ad-hoc signature. Verify hardened
  runtime, Gatekeeper and the bundled helpers after the actual transition;
  the signed download alone does not prove their installed state.
- Before the transition, retain the Swift ZIP, a copy of the installed app,
  and a backup of its preferences and support directory. Quit Electron before
  restoring Swift. Verify the restored preferences and history in that same
  isolated account. Neither updater provides a persistent rollback backup:
  both remove their temporary old-bundle backup after replacement. Do not
  assume an older reader accepts every new provider or archive value.
- Keep the default installer, README and release metadata on Swift until the
  isolated upgrade and rollback evidence passes and stable publication is
  authorized. Merging Electron source does not publish a stable release.
