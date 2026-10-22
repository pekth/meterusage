# Electron public beta

MeterUsage **0.3.0-beta.4, build 73** is an opt-in macOS beta. The ZIP supports
Apple silicon and macOS 13 or later. It is Developer ID signed, notarized and
stapled. Swift `0.2.41` remains the stable release and updater download.

## Install

1. Download [the beta ZIP](https://github.com/pekth/meterusage/releases/download/v0.3.0-beta.4/MeterUsage-0.3.0-beta.4-mac-arm64.zip)
   and [SHA256SUMS](https://github.com/pekth/meterusage/releases/download/v0.3.0-beta.4/SHA256SUMS).
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
a86cc1eba95b0b7ce3badb294f1357c1800ce05c2d3160123cd12b82590c1ae1
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
- Every provider card with a quota reading shows a **Quota activity** heatmap:
  the daily rise in that provider's weekly (or longest) allowance, counting
  desktop, web and other-device use. Each provider keeps its own history.
  On first run, the current window's usage is spread over its elapsed days and
  marked estimated; earlier weeks are not backfilled. Days count only while
  MeterUsage refreshes; offline usage lands on the next reading's day. Values
  are percentage points, never inferred tokens. Tooltips add measured Claude
  Code or Codex tokens from this Mac when present.
- Claude Code CLI reads local transcript activity. Quota requires an optional
  companion file. Local activity does not cover other devices.
- Antigravity Desktop reads account allowance from one running, signed-in
  language server. The owner confirmed a live connection; broad compatibility
  and an automated desktop-versus-CLI comparison remain incomplete. Local CLI
  activity stays separate.
- Grok Bot Desktop (Beta) reads the active account's encrypted local credential
  after consent and requests allowance. Quota burn needs recent same-account
  observations and is measured in percentage points per hour, not tokens.
  Live burn-rate and broad endpoint compatibility remain unverified. Existing
  saved Cursor connections retain their original source. Consumer web sign-in
  is unavailable.
- OpenCode Go offers local session history without a key. Allowance separately
  requires an existing Go key saved by OpenCode. Only Go sessions count.
- OpenAI API and Anthropic API billing use separate owner-only snapshots.
  Settings → API connections can reuse a provider's fixed legacy Keychain
  Admin key or accept a masked one-time Admin key. Original saved keys are
  preserved and newly pasted keys are not saved. OpenRouter keeps its existing
  balance and aggregate activity source. Read [API setup and limits](API_USAGE_BETA.md).

See [source choices](https://github.com/pekth/meterusage/blob/v0.3.0-beta.4/docs/electron/README.md#source-choices),
[desktop connections](https://github.com/pekth/meterusage/blob/v0.3.0-beta.4/docs/DESKTOP-CONNECTIONS.md) and [privacy](https://github.com/pekth/meterusage/blob/v0.3.0-beta.4/docs/PRIVACY.md).

## Known limits

- Settings now shows the running bundle version. Source previews omit it when
  packaging metadata is absent.
- The tray renderer preloads after completed onboarding. Native first-click
  latency has not been measured, so no timing guarantee is made.
- OpenAI saved-key recovery through the installed signed helper succeeded.
  The live Settings button journey, Anthropic billing, invoice completeness
  and live Grok burn-rate acceptance remain unverified. Anthropic Priority
  Tier costs are excluded.
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
Review the [report contents and privacy limits](https://github.com/pekth/meterusage/blob/v0.3.0-beta.4/docs/REPORTING.md) before sending.
Never include tokens, passwords or raw account files in an issue.

## Build and screenshot identity

The signed artifact was built from source
`3c56bd0d4ebf6d51996b9ebdc0a9b09f5570f182`. Release documentation is a documentation-only descendant; executable
inputs are unchanged. Screenshots are from build 61 and do not show the Quota
activity heatmap. Source manifests retain `0.2.41`; beta packaging explicitly
set `0.3.0-beta.4`.

Matching validation recorded 846 tests across 33 files on macOS, TypeScript
checking and production bundling. Swift build and tests were not rerun for this
beta. The installed build was observed recording quota activity for Claude,
Codex, Antigravity and Grok. Native rendering of filled heatmaps
remains unverified. Signing, notarization, stapling, Gatekeeper,
installed bundle identity and ZIP bytes were verified separately. These checks
do not close the native acceptance gaps above.

The [screenshot gallery](SCREENSHOTS.md) uses invented demo data and the actual
release renderer. It replaces old product captures without exposing real accounts.
