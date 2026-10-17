<p align="center">
  <img src="docs/images/icon.png" alt="MeterUsage app icon" width="96">
</p>

# MeterUsage

MeterUsage monitors AI coding allowance and usage in a macOS menu bar and
floating side notch. Electron is the active development target. The legacy
Swift app remains the stable download and rollback option during migration.

## Download

| Edition | Current status | Setup and behavior |
| --- | --- | --- |
| Electron 0.3.0-beta.1, build 54 | Public beta for Apple silicon, macOS 13+; signed and notarized | [Download beta](https://github.com/pekth/meterusage/releases/tag/v0.3.0-beta.1) · [Beta guide](docs/BETA.md) |
| Legacy Swift 0.2.41 | Frozen for new features; published stable download and migration rollback | [Swift guide](docs/swift/README.md) |

Electron is the active app for new features. Swift remains the stable download
and rollback reference. The beta is installed manually; the stable updater does
not offer it. Quit the existing MeterUsage before replacing it, and keep a copy
for rollback. Both apps share their identity and saved data, so do not run them
together against a normal profile. See [beta installation and limits](docs/BETA.md)
and the [version strategy](docs/VERSIONS.md).

## Current beta UI

<p>
  <img src="docs/images/beta-usage-claude.png" alt="Electron beta Claude usage demo with service status and token heatmap" width="300">
  <img src="docs/images/beta-notch-claude.png" alt="Electron beta hover card and compact side-notch usage rail" width="256">
</p>

Synthetic demo captures of build 54's renderer. Claude Desktop provides allowance,
not a chat-history heatmap. See the [full screenshot gallery and capture details](docs/SCREENSHOTS.md)
for Codex, Claude, side notch and Settings.

The beta includes Codex browser sign-in/account history, optional Claude Desktop
allowance, existing CLI sources, compact provider tabs and hover cards, provider
reordering and readable token totals. Account coverage depends on the source.
Build 54 keeps Grok Beta CLI-only; Antigravity desktop login is follow-up work.
Current source additionally offers opt-in [Grok Bot Desktop Beta](docs/DESKTOP-CONNECTIONS.md#grok-bot-desktop-beta).
Sign in through Grok Bot Desktop first, then approve read-only access.
Native/live allowance, X and shared-pool coverage remain unverified.
Current source also adds separate [OpenAI API and Anthropic API billing snapshots](docs/API_USAGE_BETA.md)
through Settings → API connections with a saved legacy Admin key, a one-time
Admin key, or the bundled environment-only helper. Existing Keychain entries
are preserved; pasted keys are not saved. OpenRouter keeps its existing
account balance and aggregate activity integration.
Unreleased source adds opt-in [Muse Code CLI allowance](docs/DESKTOP-CONNECTIONS.md#muse-code-cli).
Muse.ai cloud/Desktop connection is separate and remains pending.
Build 54's Settings footer incorrectly says `0.2.41`; the packaged version is
`0.3.0-beta.1`. See [known beta limits](docs/BETA.md#known-limits).

## Stable Swift installation

The default installation is the published Swift app for Apple silicon Macs
with macOS 13 or later. No Swift, Xcode, Command Line Tools or Git is required.

1. [Download MeterUsage 0.2.41](https://github.com/pekth/meterusage/releases/download/v0.2.41/MeterUsage-0.2.41.zip).
2. Unzip and drag `MeterUsage.app` to Applications.
3. Open the app. The release is ad-hoc signed and not notarized. If macOS blocks
   first launch, right-click the app in Finder and choose **Open**, or use
   **Open Anyway** in System Settings > Privacy & Security.

From a Git checkout or source archive, run:

```sh
./Scripts/make-app.sh
```

This downloads the pinned Swift ZIP, verifies its checksum and signature, and
prepares `dist/MeterUsage.app`. Drag that app to Applications to install it.
The script does not build Electron. A failed download or verification does not
fall back to compilation. See the [Swift installation guide](docs/swift/README.md#download-and-installation).

## Setup and data coverage

The original nine provider adapters remain in the retained Swift and candidate source:
Codex, Claude Code, Antigravity, OpenRouter, Grok, OpenCode Go, Cursor, Copilot
CLI and Gemini CLI. Their inputs and available measurements differ. The
[Swift provider matrix](docs/swift/README.md#provider-matrix) describes existing
CLI/local collection. The [Electron source choices](docs/electron/README.md#source-choices)
also describe optional Codex browser sign-in and Claude Desktop allowance.

Local activity covers this Mac. Provider-reported account data has its own
coverage limits. Missing tokens remain unknown. Local token costs are estimates; optional API
billing cards label provider-reported amounts separately. Provider dashboards
remain the billing source of record. Read the [privacy contract](docs/PRIVACY.md)
before changing a data source or sharing screenshots.

## Can both editions coexist?

Both source trees remain during migration; the intended end state is one
Electron app. Normal-profile side-by-side installation is unsafe:
the app name, bundle ID and default preferences/data locations are shared.
Use only the documented [isolated candidate QA profiles](docs/electron/README.md#isolated-qa)
for testing. A separate app identity and data root require a later decision;
there is no automatic cutover. See [ADR 0010](docs/adr/0010-macos-typescript-electron.md).

## Documentation

- [Beta download, verification and limits](docs/BETA.md)
- [Current beta screenshots](docs/SCREENSHOTS.md)
- [Swift guide](docs/swift/README.md)
- [Electron guide and known gaps](docs/electron/README.md)
- [Versions and staged Swift retirement](docs/VERSIONS.md)
- [Contributing](CONTRIBUTING.md)
- [Project knowledge](docs/KB.md) and [decision index](docs/adr/README.md)
- [Desktop connections](docs/DESKTOP-CONNECTIONS.md), [demo mode](docs/DEMO.md)
  and [side notch](docs/SIDE-NOTCH.md)
- [Concept mockups](docs/mockups/README.md) and [changelog](CHANGELOG.md)

## Compatibility links

Older root README links continue below. Detailed Swift descriptions remain in
the Swift guide; product screenshots now show the Electron beta.

<a id="choose-an-edition"></a>
See [downloads](#download).

<a id="macos-electron-migration-candidate"></a>
See the [Electron candidate guide](docs/electron/README.md).

<a id="second-accounts"></a>
See [Swift additional local accounts](docs/swift/README.md#second-accounts) and
[Electron advanced local accounts](docs/electron/README.md#advanced-local-accounts).

<a id="requirements"></a>
See [Swift requirements](docs/swift/README.md#requirements).

<a id="contributing"></a>
See [contributor setup](CONTRIBUTING.md).

<a id="agent-budget-cli"></a>
See the [Swift Agent Budget CLI](docs/swift/README.md#agent-budget-cli) and
[Electron commands](docs/electron/README.md#build-and-test).

<a id="showcase"></a><a id="-showcase"></a>
<a id="ambient-time-to-empty--side-notch-hud"></a>
<a id="menu-bar--popover-dashboard"></a>
<a id="settings-accounts--providers"></a>
See [current beta screenshots](docs/SCREENSHOTS.md).

<a id="provider-matrix"></a><a id="-provider-matrix"></a>
See the [Swift provider matrix](docs/swift/README.md#provider-matrix).

<a id="key-features"></a><a id="-key-features"></a>
See [Swift behavior](docs/swift/README.md#key-features).

<a id="privacy--architecture"></a><a id="-privacy--architecture"></a>
See [privacy and data handling](docs/PRIVACY.md).

<a id="install-the-prebuilt-app"></a><a id="from-a-git-checkout-no-swift"></a>
See [installation details](docs/swift/README.md#download-and-installation).

<a id="-tldr"></a><a id="tldr"></a>
See [downloads](#download).

<a id="license--disclaimer"></a><a id="-license--disclaimer"></a>
## License and disclaimer

[MIT](LICENSE). Independent project, not affiliated with or endorsed by OpenAI,
Anthropic, Google, xAI, Microsoft or other providers.
