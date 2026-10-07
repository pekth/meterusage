<p align="center">
  <img src="docs/images/icon.png" alt="meterusage app icon" width="96">
</p>

<h1 align="center">meterusage</h1>

<p align="center">
  <strong>Native macOS menu-bar and floating side-notch HUD for monitoring your AI coding quotas.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform: macOS 13+">
  <img src="https://img.shields.io/badge/privacy-no%20telemetry-brightgreen?style=flat-square" alt="Privacy: no telemetry">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License: MIT">
</p>

---

### ⚡ TL;DR

**meterusage** brings all your AI coding allowances, token burn rates, and rate-limit reset timers together into a clean macOS menu bar item and an interactive floating side-notch HUD.

* **Broad Provider Coverage**: OpenAI Codex, Google Antigravity, Claude Code, OpenRouter, Grok, OpenCode Go, Cursor, GitHub Copilot CLI, and Google Gemini CLI.
* **Second-Account Meters**: Hold two Codex or Claude Code accounts? Each one gets its own independent meter row — own quota windows, plan badge, history, and alerts — instead of a merged guess. See [Second accounts](#second-accounts).
* **Ambient Time-to-Empty**: Live depletion velocity against reset deadlines (`~47m left at current pace` / `Paced to last until reset`) directly in the menu bar and side notch.
* **Burn Attribution & Context Waste**: Token breakdown by project, model, and turns over the last 7 days across every token-bearing provider, plus cache-hit efficiency % and long-chat flags.
* **Durable Daily History**: Local summary store surviving CLI transcript purges and session cleanup.
* **Existing provider access**: No accounts to connect or passwords to enter. Uses existing provider CLIs, local SQLite/JSON stores and aggregate usage endpoints.
* **Agent Budget API**: Machine-readable JSON CLI (`meterusage json`) exporting burn rates, pacing, and time-to-empty for autonomous AI agents.

[Download MeterUsage 0.2.41 for Apple silicon](https://github.com/pekth/meterusage/releases/download/v0.2.41/MeterUsage-0.2.41.zip),
unzip it, and drag `MeterUsage.app` to
**Applications**. No Swift, Xcode, Command Line Tools, or Git is required.
The current prebuilt release supports Apple silicon Macs with macOS 13 or later.
See [installation](#download-and-installation) for first-launch steps.

---

## macOS Electron migration candidate

The macOS app and schema-1 JSON CLI are being ported to TypeScript, Electron
and React. The candidate uses pnpm, Vite+, Tailwind, Vitest and electron-builder.
The downloadable 0.2.41 app above remains the Swift release. The Electron
candidate has not passed native macOS acceptance and is not a published release.

The candidate also has [desktop account connection controls](docs/DESKTOP-CONNECTIONS.md)
for Codex browser sign-in and opt-in Claude Desktop allowance. Setup uses buttons
and approval dialogs. Grok consumer connection remains unavailable. Native
sign-in, provider responses and Keychain acceptance still require verification.

Provider readers and credentials stay in the main process. The sandboxed
renderer receives validated snapshots through a small IPC bridge. Existing
history/archive JSON, preference keys, managed account IDs and provider marks
remain compatibility targets. Windows implementation, installers, testing and
release are paused until a test machine is available.

See [the migration decision](docs/adr/0010-macos-typescript-electron.md),
[contributor commands](CONTRIBUTING.md#typescript-electron-candidate), and
[isolated demo testing](docs/DEMO.md#electron-candidate). Native tray, settings,
notifications, login items, sharing, updater and two different-height notch
captures are required before cutover.

---

## 📸 Showcase

### Ambient Time-To-Empty & Side Notch HUD
A dockable, collapsible HUD pinned to the edge of your screen. Hovering any provider ring expands a dedicated detail card with rate limits, ambient time-to-empty, pacing diagnostics, and token telemetry. The panel is anchored by the strip's top-right corner, so switching providers never moves the strip ([`docs/SIDE-NOTCH.md`](docs/SIDE-NOTCH.md)):

<p align="center">
  <img src="docs/images/sidenotch-codex.png" alt="Codex rate limits, reset credits, and usage" width="340">
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="docs/images/sidenotch-v2-live.png" alt="Antigravity limits, pacing, and token telemetry" width="320">
</p>

<p align="center">
  <img src="docs/images/sidenotch-grok.png" alt="Grok weekly quota, sessions, and message volume" width="320">
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="docs/images/sidenotch-opencode-go.png" alt="OpenCode Go rolling, weekly, and monthly quotas" width="320">
</p>

### Menu Bar & Popover Dashboard
Click the menu bar mark anytime to inspect full rate-limit details, multi-window countdowns, and 26-week activity heatmaps:

<p align="center">
  <img src="docs/images/popover.png" alt="Service status, pipeline, AI coding today, and Codex quotas" width="270">
  &nbsp;
  <img src="docs/images/popover-2.png" alt="Codex heatmap, Grok quota, and OpenCode Go quota" width="270">
  &nbsp;
  <img src="docs/images/popover-3.png" alt="OpenRouter quota, Claude quota, Claude heatmap, and Antigravity" width="270">
</p>

<sub>Screenshots show the app in demo mode (`METERUSAGE_DEMO=1`) — all numbers and names are synthetic.</sub>

### Settings: Accounts & Providers
Toggle providers on or off, choose refresh cadence, and switch themes and the accent colour:

<p align="center">
  <img src="docs/images/settings-accounts.png" alt="Settings accounts list with provider connections and appearance theme" width="270">
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="docs/images/settings-providers.png" alt="Settings providers list with refresh interval and side notch toggles" width="270">
</p>

---

## 🔍 Provider Matrix

| Provider | Live Cloud Quota | Local Activity & Tokens | Reset Countdowns | 26-Week Heatmap | Source Mechanism |
|---|:---:|:---:|:---:|:---:|---|
| **Codex** | ✅ | ✅ | ✅ | ✅ | Local JSON-RPC via `codex app-server --stdio` |
| **Antigravity** | ✅ | ✅ | ✅ | — | CLI `/usage` & local conversation SQLite |
| **Claude Code** | Optional* | ✅ | ✅* | ✅ | Local session JSONL streams (`limits[]` file optional) |
| **OpenRouter** | ✅ | ✅ | ✅ | — | Public account API & `/api/v1/activity` telemetry |
| **Grok** | ✅ | ✅ | ✅ | — | CLI auth bearer token & session summaries |
| **OpenCode Go** | ✅ | ✅ | ✅ | — | Local `opencode db` read-only queries |
| **Cursor** | Local snapshot | — | Snapshot-dependent | — | Existing local quota/usage JSON or presence check |
| **Copilot CLI** | Local snapshot | — | Snapshot-dependent | — | Existing local quota/usage JSON or presence check |
| **Gemini CLI** | Local snapshot | — | Snapshot-dependent | — | Existing local quota/usage JSON or presence check |

<small>*Claude publishes no public quota API; meterusage reads an on-disk JSON snapshot if a local companion writes one (see [docs/COMPANION.md](docs/COMPANION.md) and [`Scripts/claude-companion.sh`](Scripts/claude-companion.sh)).</small>

<small>Second accounts for Codex and Claude use the same mechanisms pointed at the alternate account's config directory (see [Second accounts](#second-accounts) and [docs/adr/0005](docs/adr/0005-multi-account-slots.md)).</small>

---

## 🚀 Key Features

* **Ambient Time-to-Empty**: Dynamic ETA calculations (`~47m left at current pace` / `Paced to last until reset`) directly in the menu bar and side notch. The bar, banner, and menu-bar chip report the window's own pace, so a deficit keeps its projected run-out after the burst has cooled; only the present-tense "burning fast" nudge and pace alerts require a current burn. After a successful Codex "Use reset", pacing waits for fresh quota readings with usage growth. The first reading establishes a baseline, and later growth determines the rate and ETA. Each account keeps its own baseline across relaunches.
* **Window Burn Attribution** — Explains *"Where did my tokens go?"* by decomposing the last 7 days of token consumption by project, model, and message turns across all token-bearing providers.
* **Context Waste & Cache Hints** — Diagnostic metadata highlighting cache hit rate %, average tokens per turn, and long-chat flags ($\ge 10$ turns or $\ge 100\text{k}$ tokens) to curb silent context waste.
* **Durable Daily History Store** — Preserves daily token tallies, estimated spend, and peak window utilization in a durable local database (`~/Library/Application Support/MeterUsage/durable-daily-history.json`) that survives CLI transcript pruning.
* **Unified AI Coding Strip** — High-level summary card in the popover showing all AI coding today (tokens, weekly volume, and estimated USD spend) across all active providers.
* **Floating Side Notch HUD** — Fixed-black, hardware-like collapsible strip. Hovering a ring expands a docked detail card with smooth spring animations. Features auto-flip positioning (switches left/right depending on screen position). The strip stays anchored to its parked corner while cards change, so provider switches never shift it.
* **Cross-Provider Headroom Failover** — Instant suggestions when a provider is burning fast or near exhaustion, identifying which alternative model has headroom available. "Burning fast" requires a current burn; a window that is merely near its limit says so in its own words.
* **Agent Budget API** — Run `meterusage json` to export machine-readable quota telemetry, burn velocity, pacing status, and seconds-to-empty for autonomous AI agents. Pacing in the report is gated on burn recency, matching the failover nudge and pace alerts.
* **26-Week Activity Heatmaps** — GitHub-style activity matrix inside Codex and Claude cards with Day, Week, or Cumulative views, accompanied by 7-day sparklines.
* **Accent Colour Themes** — Pick an accent palette (Blue, Violet, Teal, Amber, Rose, Graphite) in Settings → Appearance. It recolours the app accent and the primary provider's mark across the popover, menu bar, and side notch; quota headroom and the other provider identities stay fixed.
* **Opt-In Pacing Alerts** — Native macOS notifications when an active window crosses critical burn velocity or drops below 30 minutes to empty. Pace alerts fire only on a current burn; threshold alerts (80%/95%) remain state-based.
* **Share screenshot**: The share button on each provider's usage card (side notch panel detail card) shares a sharp 2x image of the panel through macOS share services, or saves it for X and other apps.

### Second accounts

Two or more accounts with the same tool are separate budgets, so meterusage
gives each one its own meter row — own quota windows, plan badge, session
history, alerts, and (for Codex) reset credits. Add as many as you need:
**Settings → Second accounts → "Add Codex/Claude account"**, then name the
account and point it at that account's own config directory (e.g.
`~/.codex-work`, `~/.claude-personal`). Sign the CLI in under that directory
(`CODEX_HOME=~/.codex-work codex login`, or run Claude Code with
`CLAUDE_CONFIG_DIR=~/.claude-personal`), and relaunch meterusage — readings
appear once the directory exists. Removing a row stops metering that account;
nothing in the directory is deleted.

Slots are named by your own label ("Codex · Work", a digit beside the mark in
the tray and notch); no provider account identifier is read or displayed. Each
account stays under its own keys in the Agent Budget API, which reports the
label in an additive `account` field.

---

## 🔒 Privacy & Architecture

meterusage is built from the ground up to respect developer privacy:
* **No Network Man-in-the-Middle**: Reuses the authenticated CLI sessions already on your Mac.
* **Selective local reads**: Selects numeric session metadata, token tallies, model names and timestamps. Project directories become basenames. Message content, tool payloads and file diffs are skipped.
* **No Telemetry / Analytics**: Zero outgoing telemetry calls.
* **Inspectable data boundary**: Full privacy architecture documented in [docs/PRIVACY.md](docs/PRIVACY.md).

---

## Download and installation

### Install the prebuilt app

Installing and running MeterUsage does not require Swift, Xcode, Command Line
Tools, or Git. The Swift runtime it uses ships with macOS.

1. [Download MeterUsage 0.2.41 for Apple silicon](https://github.com/pekth/meterusage/releases/download/v0.2.41/MeterUsage-0.2.41.zip). This app ZIP is for Apple silicon Macs (M1 or later) with macOS 13 or later. Other versions are on [Releases](https://github.com/pekth/meterusage/releases). Choose the app ZIP, not GitHub's **Source code** archives.
2. Unzip and drag `MeterUsage.app` to your `/Applications/` folder.
3. Open `MeterUsage.app`. Releases are ad-hoc signed and are not notarized. If macOS blocks the first launch, right-click the app in Finder and choose **Open**, or use **Open Anyway** in System Settings → Privacy & Security.

If a release has no app ZIP, use an earlier release that includes one or report
the missing asset.

### From a Git checkout (no Swift)

If you already cloned this repository or downloaded its source archive, run:

```sh
./Scripts/make-app.sh
```

This downloads the verified prebuilt release to `dist/MeterUsage.app`. Drag
that app to Applications and use the same first-launch steps above. It does
not compile your checkout, install developer tools, or fall back to a source
build when the download fails.

---

## Requirements

* Apple silicon Mac with macOS 13 Ventura or later for the current prebuilt release.
* A supported provider CLI or data source for the meters you want to use. Provider accounts are not required to install the app or run demo mode.

### Contributing

Swift and Xcode Command Line Tools are needed only to build from source.
See [CONTRIBUTING.md](CONTRIBUTING.md) for developer setup, build commands,
and tests. Source builds require the explicit `--build-from-source` option.

### Agent Budget CLI
To consume quota telemetry programmatically in scripts or agents:
```sh
meterusage json
```
Outputs structured JSON including `remaining_percent`, `resets_at`, `pacing`, `burn_rate`, and `eta_seconds`.

---

## 📄 License & Disclaimer

* **License**: [MIT](LICENSE)
* **Disclaimer**: Independent open-source project. Not affiliated with or endorsed by OpenAI, Anthropic, Google, xAI, Microsoft, or OpenRouter.
