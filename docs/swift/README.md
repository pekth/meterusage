<p align="center">
  <img src="../../docs/images/icon.png" alt="meterusage app icon" width="96">
</p>

<h1 align="center">MeterUsage Swift 0.2.41</h1>

<p align="center">
  <strong>Native macOS menu-bar and floating side-notch HUD for monitoring your AI coding quotas.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform: macOS 13+">
  <img src="https://img.shields.io/badge/privacy-no%20telemetry-brightgreen?style=flat-square" alt="Privacy: no telemetry">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License: MIT">
</p>

---

## Historical Swift recovery reference

Use the [Electron beta](../../README.md) for the offered app. This guide retains
historical behavior and recovery instructions. See [versions](../VERSIONS.md).

This guide describes the published Swift 0.2.41 app and retained Swift sources.
The Swift app is frozen for new features. New feature work targets Electron;
Swift receives only critical fixes and transition compatibility work. Preserve
historical source/releases for recovery, with no separate offered edition.
Source removal still requires the
[retirement conditions](../adr/0024-electron-primary-swift-retirement.md#retirement-conditions).
Stable acceptance and isolated Swift upgrade/rollback remain open.
Current product images are in the [Electron beta gallery](../SCREENSHOTS.md).
Old Swift product captures have been removed from the active documentation.

MeterUsage shows supported AI coding allowances, measured token usage, pacing
and reset times in the menu bar, popover and floating side notch.

* **Broad Provider Coverage**: OpenAI Codex, Google Antigravity, Claude Code, OpenRouter, Grok, OpenCode Go, Cursor, GitHub Copilot CLI, and Google Gemini CLI.
* **Second-Account Meters**: Hold two Codex or Claude Code accounts? Each local configuration directory gets its own row with quota windows, plan badge, history and alerts. See [Second accounts](#second-accounts).
* **Ambient Time-to-Empty**: Live depletion velocity against reset deadlines (`~47m left at current pace` / `Paced to last until reset`) directly in the menu bar and side notch.
* **Burn Attribution & Context Waste**: Token breakdown by project, model, and turns over the last 7 days across every token-bearing provider, plus cache-hit efficiency % and long-chat flags.
* **Durable Daily History**: Local summary store surviving CLI transcript purges and session cleanup.
* **Existing provider access**: Uses existing provider setup; there is no account connection UI in Swift. Uses existing provider CLIs, local SQLite/JSON stores and aggregate usage endpoints.
* **Agent Budget API**: Machine-readable JSON CLI (`meterusage json`) exporting burn rates, pacing, and time-to-empty for autonomous AI agents.

[Historical MeterUsage 0.2.41 ZIP for recovery](https://github.com/pekth/meterusage/releases/download/v0.2.41/MeterUsage-0.2.41.zip),
unzip it, and drag `MeterUsage.app` to
**Applications**. No Swift, Xcode, Command Line Tools, or Git is required.
The historical prebuilt release supports Apple silicon Macs with macOS 13 or later.
See [installation](#download-and-installation) for first-launch steps.

---

## Showcase

See the [current Electron beta screenshots](../SCREENSHOTS.md). This legacy
Swift guide retains its behavior and installation reference without old images.

---

## Provider matrix

| Provider | Live Cloud Quota | Local Activity & Tokens | Reset Countdowns | 26-Week Heatmap | Source Mechanism |
|---|:---:|:---:|:---:|:---:|---|
| **Codex** | ✅ | ✅ | ✅ | ✅ | Local JSON-RPC via `codex app-server --listen stdio://` |
| **Antigravity** | ✅ | ✅ | ✅ |. | CLI `/usage` & local conversation SQLite |
| **Claude Code** | Optional* | ✅ | ✅* | ✅ | Local session JSONL streams (`limits[]` file optional) |
| **OpenRouter** | ✅ | ✅ | ✅ |. | Public account API & `/api/v1/activity` telemetry |
| **Grok** | ✅ | ✅ | ✅ |. | CLI auth bearer token & session summaries |
| **OpenCode Go** | ✅ | ✅ | ✅ |. | Existing Go key for quota; independent Go-only read-only session SQL |
| **Cursor** | Local snapshot |. | Snapshot-dependent |. | Existing local quota/usage JSON or presence check |
| **Copilot CLI** | Local snapshot |. | Snapshot-dependent |. | Existing local quota/usage JSON or presence check |
| **Gemini CLI** | Local snapshot |. | Snapshot-dependent |. | Existing local quota/usage JSON or presence check |

<small>*Claude publishes no public quota API; meterusage reads an on-disk JSON snapshot if a local companion writes one (see [docs/COMPANION.md](../../docs/COMPANION.md) and [`Scripts/claude-companion.sh`](../../Scripts/claude-companion.sh)).</small>

<small>Second accounts for Codex and Claude use the same mechanisms pointed at the alternate account's config directory (see [Second accounts](#second-accounts) and [docs/adr/0005](../../docs/adr/0005-multi-account-slots.md)).</small>

---

## Key features

* **Ambient Time-to-Empty**: Dynamic ETA calculations (`~47m left at current pace` / `Paced to last until reset`) directly in the menu bar and side notch. The bar, banner, and menu-bar chip report the window's own pace, so a deficit keeps its projected run-out after the burst has cooled; only the present-tense "burning fast" nudge and pace alerts require a current burn. After a successful Codex "Use reset", pacing waits for fresh quota readings with usage growth. The first reading establishes a baseline, and later growth determines the rate and ETA. Each account keeps its own baseline across relaunches.
* **Window Burn Attribution**: Explains *"Where did my tokens go?"* by decomposing the last 7 days of token consumption by project, model, and message turns across all token-bearing providers.
* **Context Waste & Cache Hints**: Diagnostic metadata highlighting cache hit rate %, average tokens per turn, and long-chat flags ($\ge 10$ turns or $\ge 100\text{k}$ tokens) to curb silent context waste.
* **Durable Daily History Store**: Preserves daily token tallies, estimated spend, and peak window utilization in a durable local database (`~/Library/Application Support/MeterUsage/durable-daily-history.json`) that survives CLI transcript pruning.
* **Unified AI Coding Strip**: High-level summary card in the popover showing all AI coding today (tokens, weekly volume, and estimated USD spend) across all active providers.
* **Floating Side Notch HUD**: Fixed-black, hardware-like collapsible strip. Hovering a ring expands a docked detail card with smooth spring animations. Features auto-flip positioning (switches left/right depending on screen position). The strip stays anchored to its parked corner while cards change, so provider switches never shift it.
* **Cross-Provider Headroom Failover**: Instant suggestions when a provider is burning fast or near exhaustion, identifying which alternative model has headroom available. "Burning fast" requires a current burn; a window that is merely near its limit says so in its own words.
* **Agent Budget API**: Run `meterusage json` to export machine-readable quota telemetry, burn velocity, pacing status, and seconds-to-empty for autonomous AI agents. Pacing in the report is gated on burn recency, matching the failover nudge and pace alerts.
* **26-Week Activity Heatmaps**: GitHub-style activity matrix inside Codex and Claude cards with Day, Week, or Cumulative views, accompanied by 7-day sparklines.
* **Accent Colour Themes**: Pick an accent palette (Blue, Violet, Teal, Amber, Rose, Graphite) in Settings → Appearance. It recolours the app accent and the primary provider's mark across the popover, menu bar, and side notch; quota headroom and the other provider identities stay fixed.
* **Opt-In Pacing Alerts**: Native macOS notifications when an active window crosses critical burn velocity or drops below 30 minutes to empty. Pace alerts fire only on a current burn; threshold alerts (80%/95%) remain state-based.
* **Share screenshot**: The share button on each provider's usage card (side notch panel detail card) shares a sharp 2x image of the panel through macOS share services, or saves it for X and other apps.

### Second accounts

Two or more accounts with the same tool are separate budgets, so meterusage
gives each one its own row with quota windows, plan badge, session
history, alerts and (for Codex) reset credits. Add as many as you need:
**Settings → Second accounts → "Add Codex/Claude account"**, then name the
account and point it at that account's own config directory (e.g.
`~/.codex-work`, `~/.claude-personal`). Sign the CLI in under that directory
(`CODEX_HOME=~/.codex-work codex login`, or run Claude Code with
`CLAUDE_CONFIG_DIR=~/.claude-personal`), and relaunch meterusage. readings
appear once the directory exists. Removing a row stops metering that account;
nothing in the directory is deleted.

Slots are named by your own label ("Codex · Work", a digit beside the mark in
the tray and notch); no provider account identifier is read or displayed. Each
account stays under its own keys in the Agent Budget API, which reports the
label in an additive `account` field.

---

## Privacy and architecture

MeterUsage reads selected numeric usage fields and existing provider access:
* **No Network Man-in-the-Middle**: Reuses the authenticated CLI sessions already on your Mac.
* **Selective local reads**: Selects numeric session metadata, token tallies, model names and timestamps. Project directories become basenames. Message content, tool payloads and file diffs are skipped.
* **No Telemetry / Analytics**: Zero outgoing telemetry calls.
* **Inspectable data boundary**: Full privacy architecture documented in [docs/PRIVACY.md](../../docs/PRIVACY.md).

---

## Download and installation

<a id="install-the-prebuilt-app"></a>
### Recover the historical prebuilt app

Installing and running MeterUsage does not require Swift, Xcode, Command Line
Tools, or Git. The Swift runtime it uses ships with macOS.

1. [Historical MeterUsage 0.2.41 ZIP for recovery](https://github.com/pekth/meterusage/releases/download/v0.2.41/MeterUsage-0.2.41.zip). This app ZIP is for Apple silicon Macs (M1 or later) with macOS 13 or later. Other versions are on [Releases](https://github.com/pekth/meterusage/releases). Choose the app ZIP, not GitHub's **Source code** archives.
2. Unzip and drag `MeterUsage.app` to your `/Applications/` folder.
3. Open `MeterUsage.app`. Releases are ad-hoc signed and are not notarized. If macOS blocks the first launch, right-click the app in Finder and choose **Open**, or use **Open Anyway** in System Settings → Privacy & Security.

If a release has no app ZIP, use an earlier release that includes one or report
the missing asset.

<a id="from-a-git-checkout-no-swift"></a>
### Explicit legacy source build

`./Scripts/make-app.sh` now prepares the Electron beta. For an explicit legacy
Swift source build for recovery or reference, run:

```sh
./Scripts/make-app.sh --build-from-source
```

That mode requires Swift and Xcode Command Line Tools and signs ad hoc. It does
not reproduce the published Electron beta. The default download path never
falls back to compilation. Use the historical ZIP above when recovering the
published Swift release. Quit the active app and preserve app/data backups
before replacement; native upgrade/rollback acceptance remains open.

---

## Requirements

* Apple silicon Mac with macOS 13 Ventura or later for the current prebuilt release.
* A supported provider CLI or data source for the meters you want to use. Provider accounts are not required to install the app or run demo mode.

### Contributing

Swift and Xcode Command Line Tools are needed only to build from source.
See [CONTRIBUTING.md](../../CONTRIBUTING.md) for developer setup, build commands,
and tests. Source builds require the explicit `--build-from-source` option.

### Agent Budget CLI
To consume quota telemetry programmatically in scripts or agents:
```sh
meterusage json
```
The schema-1 quota report does not export token totals, sessions or heatmaps. It includes `remaining_percent`, `resets_at`, `pacing`, `burn_rate`, and `eta_seconds`.

---

## License and disclaimer

* **License**: [MIT](../../LICENSE)
* **Disclaimer**: Independent open-source project. Not affiliated with or endorsed by OpenAI, Anthropic, Google, xAI, Microsoft, or OpenRouter.

Cost figures are estimates. Provider dashboards remain the billing source of record.
