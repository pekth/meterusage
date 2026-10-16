# Electron public beta

MeterUsage **0.3.0-beta.1, build 54** is an opt-in macOS beta. The ZIP supports
Apple silicon and macOS 13 or later. It is Developer ID signed, notarized and
stapled. Swift `0.2.41` remains the stable release and updater download.

## Install

1. Download [the beta ZIP](https://github.com/pekth/meterusage/releases/download/v0.3.0-beta.1/MeterUsage-0.3.0-beta.1-mac-arm64.zip)
   and [SHA256SUMS](https://github.com/pekth/meterusage/releases/download/v0.3.0-beta.1/SHA256SUMS).
2. Quit MeterUsage and keep a copy of your existing app and its saved data for
   rollback. The beta shares the app identity and data locations with Swift.
3. Unzip the download, move `MeterUsage.app` to Applications, and open it.
4. In Settings, choose an existing CLI source or an optional account connection.
   Selecting a method alone does not connect it. Use its connection button.

No Node, pnpm, Swift or Xcode installation is needed to use this prebuilt beta.
Do not run the two editions together against a normal profile. Updating to later
betas is manual. `Scripts/make-app.sh` still prepares the stable Swift download.

To check the ZIP in its download directory:

```sh
shasum -a 256 -c SHA256SUMS
```

Expected ZIP SHA-256:

```text
ec4e8878e6a35120b397d8c118d023f010e8a6952a257b75764f05ecbc6f52ba
```

## Provider coverage

- Codex browser sign-in reads allowance and provider-reported daily account
  tokens when supplied. Missing days remain unavailable. Its account history
  is separate from this Mac's CLI sessions; universal product/device coverage
  is not established.
- Codex CLI reads existing authenticated quota and local rollout activity.
- Claude Desktop uses explicit consent and a macOS Keychain access prompt to
  read current allowance through a compatibility endpoint. Some accounts,
  including free accounts, may have no allowance token. This does not sign the
  user out of Claude Desktop. Desktop chat/token history is not collected.
- Claude Code CLI reads local transcript activity. Quota requires an optional
  companion file. Local activity does not cover other devices.
- Existing Grok CLI, Antigravity container, OpenCode Go and other adapters retain
  their source-specific limits. New Antigravity Desktop and Grok/Cursor login
  integrations are not included. Grok consumer web sign-in is unavailable.

See [source choices](https://github.com/pekth/meterusage/blob/v0.3.0-beta.1/docs/electron/README.md#source-choices),
[desktop connections](https://github.com/pekth/meterusage/blob/v0.3.0-beta.1/docs/DESKTOP-CONNECTIONS.md) and [privacy](https://github.com/pekth/meterusage/blob/v0.3.0-beta.1/docs/PRIVACY.md).

## Known limits

- Settings displays a hardcoded `0.2.41` footer. The installed bundle and beta
  download are version `0.3.0-beta.1`, build 54. A footer fix is separate work.
- Native keyboard/VoiceOver, complete setup/account/offline journeys,
  notifications/login items, sharing, update/relaunch/rollback and multi-display
  notch transitions have incomplete acceptance coverage. These are gaps in
  verification, not confirmed failures.
- Live Codex refresh was observed. Claude paid-account allowance was not
  live-tested. Optional support-report delivery and deployed relay limits
  were not verified end to end.
- Windows support is paused. Intel Mac binaries are not provided by this beta.

Use Settings > Diagnostics for sanitized diagnostics and **Send report**.
The app limits report attempts to one every ten minutes, including relaunches.
Review the [report contents and privacy limits](https://github.com/pekth/meterusage/blob/v0.3.0-beta.1/docs/REPORTING.md) before sending.
Never include tokens, passwords or raw account files in an issue.

## Build and screenshot identity

The signed artifact was built from source
`6ce695324e54bb09bf6e5ab36fd4733875c94427`. Release documentation and new
screenshots are a documentation-only descendant; executable inputs are unchanged.
Source manifests retain `0.2.41`; beta packaging explicitly set `0.3.0-beta.1`.

Matching validation recorded 417 synthetic tests across 19 files, TypeScript
checking and production bundling. Signing, notarization, stapling, Gatekeeper,
installed bundle identity and ZIP bytes were verified separately. These checks
do not close the native acceptance gaps above.

The [screenshot gallery](SCREENSHOTS.md) uses invented demo data and the actual
release renderer. It replaces old product captures without exposing real accounts.
