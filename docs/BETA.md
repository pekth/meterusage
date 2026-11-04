# Electron public beta

MeterUsage **0.3.0-beta.19, build 89** is the sole offered app and default
download. It remains a beta. The ZIP supports Apple silicon and macOS 13 or
later and is Developer ID signed, notarized and stapled. Historical Swift
source/releases remain available for recovery; stable acceptance is still open.

## Install

1. Download [the beta ZIP](https://github.com/tilorahdotco/meterusage/releases/download/v0.3.0-beta.19/MeterUsage-0.3.0-beta.19-mac-arm64.zip)
   and [SHA256SUMS](https://github.com/tilorahdotco/meterusage/releases/download/v0.3.0-beta.19/SHA256SUMS).
2. Quit MeterUsage and keep a copy of your existing app and its saved data for
   rollback. The beta shares the app identity and data locations with Swift.
3. Unzip the download, move `MeterUsage.app` to Applications, and open it.
4. In Settings, choose an existing CLI source or an optional account connection.
   Selecting a method alone does not connect it. Use its connection button.

No Node, pnpm, Swift or Xcode installation is needed to use this prebuilt beta.
Do not run Electron and a historical Swift app together against a normal profile.
Beta 5 and later check GitHub
hourly while **Check for updates** is on and offer newer betas or a newer
stable release in the app, with a notification. Beta 8 shows one update
notice with an inline icon in Usage and Settings > General. Install and Dismiss
are disabled while a request, download or installation is pending; failed offers
retain Retry update. **Install update** asks for confirmation, downloads the ZIP, verifies
its GitHub SHA-256 digest, bundle identity and signature, then replaces the app
and relaunches. Beta 11 adds **Install updates automatically** in
Settings > General (off by default). When on, a newer version that hasn't been
dismissed installs through the same checks without the dialog, only while you
aren't using MeterUsage. Beta 4 and earlier cannot see betas; install the current beta
manually once. Beta 5 through 10 can discover newer releases, but their installer
may reject macOS temporary-directory aliases. Install beta.11 or later manually
once to receive the updater fix. Every Electron build before beta 12 accepts updates
only from `pekth/meterusage`. The repository moved to the tilorahdotco
organization on 2026-11-01. Builds that updated to beta 12 before the move
keep updating; a build still on an earlier beta won't be offered later
releases, so install beta 12 or later manually once. `Scripts/make-app.sh` now prepares the pinned Electron beta with
checksum/signature verification, destination staging and no compiler fallback.
It preserves the published signature. Preparing output does not install it.

To check the ZIP in its download directory (`SHA256SUMS` also lists the
Windows files, so check only the macOS line):

```sh
grep -F 'MeterUsage-0.3.0-beta.19-mac-arm64.zip' SHA256SUMS | shasum -a 256 -c -
```

Expected ZIP SHA-256:

```text
99e328eefe43fd2b6b4ec0f571d79bb6d49e03d1c642f0c6afc29e1656adb73f
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

See [source choices](https://github.com/tilorahdotco/meterusage/blob/v0.3.0-beta.19/docs/electron/README.md#source-choices),
[desktop connections](https://github.com/tilorahdotco/meterusage/blob/v0.3.0-beta.19/docs/DESKTOP-CONNECTIONS.md) and [privacy](https://github.com/tilorahdotco/meterusage/blob/v0.3.0-beta.19/docs/PRIVACY.md).

## Known limits

- Beta.7 starts a fresh quota activity series when a connection changes and
  preserves Muse history across collection Stop/Start. Previous beta.6 users
  should update to receive these fixes.
- Provider masks for OpenRouter, Cursor, Copilot and Gemini ship in the app.
  Muse Code uses the official Meta infinity mark from its site. Installed
  rendering of these repaired icons remains visually unchecked.

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
- The Windows build of this release is unsigned; see [Windows beta 19](#windows-beta-19).
  Intel Mac binaries are not provided by this beta.

Use Settings > Diagnostics for sanitized diagnostics and **Send report**.
The app limits report attempts to one every ten minutes, including relaunches.
Review the [report contents and privacy limits](https://github.com/tilorahdotco/meterusage/blob/v0.3.0-beta.19/docs/REPORTING.md) before sending.
Never include tokens, passwords or raw account files in an issue.

## Build and screenshot identity

Beta.19 was built from `git archive` of main
`5cf9afc1a95e0addc2ed30f85ae59d319a390a67`. It shows Claude per-model weekly
plan limits, such as Fable on Max (#114), and points the Sponsor button at the
renamed account (#113). Packaging sets `0.3.0-beta.19`, build 89. The macOS
ZIP and the unsigned Windows installer and portable zip come from that commit
and share one `SHA256SUMS`. Source passed typecheck, 1009 synthetic tests and
production build, and hosted CI (`typescript`, `windows`) on the pull request.
Apple accepted notarization. Stapling, Gatekeeper (`Notarized Developer ID`),
bundle version and the uploaded assets' SHA-256 were checked separately. The
Windows build passed the release workflow (run 41768216629).

Beta.18 was built from `git archive` of main
`68ff0c80ed087389366ae75d8715e88663c68cf3`. It adds Claude free resets (#107)
and clear reasons when the Claude Code CLI or Antigravity CLI source cannot
supply allowance (#109, #111). Packaging sets `0.3.0-beta.18`, build 88. The
macOS ZIP and the unsigned Windows installer and portable zip come from that
commit and share one `SHA256SUMS`. Source passed typecheck, 1008 synthetic
tests and production build, and hosted CI (`typescript`, `windows`) on the
pull request. Apple accepted notarization. Stapling, Gatekeeper (`Notarized
Developer ID`), bundle version and the uploaded assets' SHA-256 were checked
separately. The Windows build passed the release workflow (run 41742128516).

Beta.17 was built from `git archive` of main
`206384b5aeded82f95c6ba4b18ed5a4c2684e06a`, which makes Settings wider instead
of taller (#105, ADR 0043). Packaging sets `0.3.0-beta.17`, build 87. The macOS
ZIP and the unsigned Windows installer and portable zip come from that commit
and share one `SHA256SUMS`. Source passed typecheck, 994 synthetic tests and
production build, and hosted CI (`typescript`, macOS `test`, `windows`) on the
pull request. Apple accepted notarization. Stapling, Gatekeeper (`Notarized
Developer ID`), bundle version and the uploaded assets' SHA-256 were checked
separately, and the installed app was launched on a Mac. The Windows build
passed the release workflow (run 41577638081).

Beta.16 was built from `git archive` of main
`73ce30bca997ffa733145327797d3c3bc28efc0f`. It adds selectable interface styles
(#102) and their fixes after beta.15 (#103). Packaging sets `0.3.0-beta.16`,
build 86. Source passed typecheck, 992 synthetic tests and production build,
and hosted CI (`typescript`, macOS `test`, `windows`) on that commit. Apple
accepted notarization. Stapling, Gatekeeper (`Notarized Developer ID`), bundle
version and the uploaded ZIP's SHA-256 were checked separately, and the
installed app was launched on a Mac. Beta.15 (build 85) shipped the styles
first. Beta.14 (build 84) was not published. Native side-notch captures for
the styles (ADR 0004/0042) remain pending.

Beta.12 was built from `git archive` of main
`44bf89d4802f52e1165fd0c1293406e8801a655d`, which adds the update-owner bridge
(#93) to beta.11 ahead of moving the repository to the tilorahdotco
organization. Source manifests retain `0.2.41`; packaging sets
`0.3.0-beta.12`, build 82. Screenshots are from build 61 and do not show later
controls, including the automatic-update setting.

Beta.12 source passed typecheck, 909 synthetic tests and production build, and
hosted CI (`typescript` and macOS `swift build`/`swift test`) on that commit.
Apple accepted notarization; stapling, Gatekeeper (`Notarized Developer ID`),
bundle version and the uploaded ZIP's SHA-256 were verified separately.
The paragraph below describes beta.11's validation.

Source validation passed typecheck, 902 synthetic tests and production build.
Hosted CI for the automatic-update feature (#91) passed the Electron checks,
`swift build` and `swift test`. The temporary-path fix passed the local checks
above.
Apple accepted notarization; the final ZIP passed native updater staging,
extracted signature, stapled-ticket and Gatekeeper checks. The extracted
executable returned schema-1 synthetic demo JSON without stderr, and ran as
an isolated demo process. No normal-profile installation was performed.
On 2026-11-01, an installed beta 11 with **Install updates automatically** on
replaced itself with beta 12 (build 82) and relaunched; the installed app
passed Gatekeeper as notarized Developer ID and left no staging copy in
Applications. The new artifact does not close the native acceptance gaps above.

The [screenshot gallery](SCREENSHOTS.md) uses invented demo data and the actual
release renderer. It replaces old product captures without exposing real accounts.

## Windows beta 19

[MeterUsage 0.3.0-beta.19, build 89](https://github.com/tilorahdotco/meterusage/releases/tag/v0.3.0-beta.19) carries the
**unsigned** Windows build for x64 Windows 10/11 alongside the macOS ZIP. Both
were built from `5cf9afc`, with one `SHA256SUMS` for all three files. Each
updater selects only its own platform's asset. The first Windows build,
[0.3.0-beta.13, build 83](https://github.com/tilorahdotco/meterusage/releases/tag/v0.3.0-beta.13), was Windows-only.

| Asset | SHA-256 |
| --- | --- |
| `MeterUsage-0.3.0-beta.19-win-x64.exe` (per-user installer) | `6201efd5a88abc5b65a20342e5a9a02f7c8be127f28faa71d5fa309e42130bd4` |
| `MeterUsage-0.3.0-beta.19-win-x64.zip` (portable; cannot update itself) | `e711068a86fc5aec93f4b221dd812f6b0bcbc2d2c1c3be72e3f7d087b9cb1beb` |

1. Download the installer and `SHA256SUMS` from the release.
2. In PowerShell, run `Get-FileHash -Algorithm SHA256 .\MeterUsage-0.3.0-beta.19-win-x64.exe`
   and compare it with `SHA256SUMS`.
3. Run the installer. SmartScreen warns because there is no code-signing
   certificate; choose **More info → Run anyway** only if the hash matches.
   It installs to `%LOCALAPPDATA%\Programs\MeterUsage` without admin rights.
4. MeterUsage runs in the notification area. Windows 11 may put a new icon in
   the overflow (^); drag it to the taskbar to keep it visible.

Data and settings are in `%APPDATA%\MeterUsage`. Uninstall from **Settings →
Apps**; app data is kept. Later Windows pre-releases install through the
in-app updater (digest-verified, unsigned; [ADR 0039](adr/0039-windows-updater.md)).

Beta.19's Windows assets were built from `5cf9afc` by the **Windows release
build** workflow
([run 41768216629](https://github.com/tilorahdotco/meterusage/actions/runs/41768216629)).
On a GitHub `windows-latest` runner, it passed typecheck, 674 Windows tests
(4 skipped), packaging, packaged-app smoke tests, and the silent install,
update handoff and uninstall check.

Beta.18's Windows assets were built from `68ff0c8` by the **Windows release
build** workflow
([run 41742128516](https://github.com/tilorahdotco/meterusage/actions/runs/41742128516)).
On a GitHub `windows-latest` runner, it passed typecheck, 674 Windows tests
(4 skipped), packaging, packaged-app smoke tests, and the silent install,
update handoff and uninstall check.

Beta.17's Windows assets were built from `206384b` by the **Windows release
build** workflow
([run 41577638081](https://github.com/tilorahdotco/meterusage/actions/runs/41577638081)).
On a GitHub `windows-latest` runner, it passed typecheck, 663 Windows tests
(4 skipped), packaging, packaged-app smoke tests, and the silent install,
update handoff and uninstall check.

Beta.13, the first Windows build, was built from `176b409` by the same
workflow
([run 41380556038](https://github.com/tilorahdotco/meterusage/actions/runs/41380556038)).
For that build, a GitHub Windows Server 2025 runner checked:

- 650 Windows tests, including a real DPAPI round trip, npm and `cmd.exe` shim
  handling and a synthetic Claude Desktop connection;
- packaged headless JSON and a demo GUI launch and relaunch;
- packaged `node:sqlite`;
- silent install, the updater's `/S --updated --force-run` relaunch, and
  silent uninstall.

Unverified on a real PC:

- desktop connections against real Claude Desktop, Grok Bot Desktop and
  Antigravity installs ([ADR 0040](adr/0040-windows-desktop-connections.md));
- Codex sign-in through Credential Manager;
- real provider CLIs and accounts;
- SmartScreen and antivirus behavior;
- an in-app upgrade between two versions;
- taskbar positions, multiple monitors and high DPI;
- notifications, launch at login, sleep and resume, accessibility;
- Windows 10, ARM64 and managed PCs.

**Use saved key** and saved Grok-via-Cursor connections are macOS-only.

