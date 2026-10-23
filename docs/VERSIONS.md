# MeterUsage versions

Electron **0.3.0-beta.7, build 77** is the sole offered distribution and default
installer download. It remains a beta, with stable acceptance open. New features
target Electron. Historical Swift 0.2.41 releases and retained `Sources/` remain
recovery/reference material, including explicit `--build-from-source` builds.
See the [beta download](BETA.md), [historical Swift reference](swift/README.md)
and [distribution decision](adr/0034-electron-beta-default.md).

The Electron source stack is on main through [PR #76](https://github.com/pekth/meterusage/pull/76),
merge `0d514dd`. That integration preserves the newer Swift reporting source and
adds account-isolated quota activity and Muse Stop/Start history preservation.
Beta.7 includes those history fixes and the provider-icon repair from
[PR #78](https://github.com/pekth/meterusage/pull/78). Its executable source is
`9cb8880ceedf7107558f7cf8197885753059e28b`. Release documentation and build 61
synthetic screenshots are separate from executable acceptance. The package
version is set at packaging time; the source manifest retains 0.2.41. Settings
shows the running bundle version. See [known beta limits](BETA.md#known-limits).

The apps share an identity and normal data locations. Quit one before replacing
it and preserve a rollback copy. Do not run both against a normal profile.
The default installer pins the beta's version, `-mac-arm64.zip` asset and SHA-256
as one target, verifies the staged bundle, and preserves its published signature.
Stable acceptance and Swift source retirement remain separate work under
[ADR 0010](adr/0010-macos-typescript-electron.md) and
[ADR 0024](adr/0024-electron-primary-swift-retirement.md).

## Update channels

Swift and stable Electron builds read GitHub's `/releases/latest`, which never
returns prereleases, and expect `MeterUsage-<version>.zip`. Electron builds whose
version ends in `-beta.N` read the release list instead, skip drafts and pick the
newest release with a verified `MeterUsage-<version>.zip` or
`MeterUsage-<version>-mac-arm64.zip` asset. A final release outranks its betas,
so beta users are offered the stable release that follows. Beta 4 and earlier
predate this and need one manual install.

Current source reuses the projected update offer in Usage and Settings > General,
with a local icon, Install/Retry and Dismiss. Busy requests/downloads/installs
disable both actions. Dismissed, disabled, demo and absent offers stay hidden
through the existing updater projection. This UI change is not in beta.7's ZIP.

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
- Keep stable publication and the existing Swift updater transition separate
  from the default beta download. The default installer and README offer the
  Electron beta under [ADR 0034](adr/0034-electron-beta-default.md); they do not
  change `/releases/latest`, install an update for existing users, or close the
  isolated upgrade/rollback and native acceptance checks above.
