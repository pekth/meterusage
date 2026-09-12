# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

## [0.2.18] - 2026-09-12

### Added

- **Ambient time-to-empty** — dynamic ETA calculations (`~47m left at current pace` / `Paced to last until reset`) directly in the menu bar and side notch, warning of rapid burn cliffs before limits expire.
- **Window burn attribution** — real-time token breakdown by project, model, and message turns for the active window.
- **Context waste hints** — diagnostic metadata highlighting cache hit rate %, average tokens per turn, and long-chat flags (≥ 10 turns or ≥ 100k tokens).
- **Durable daily history store** — local summary database (`~/Library/Application Support/MeterUsage/durable-daily-history.json`) persisting token tallies and spend across CLI transcript cleanups.
- **Unified AI coding today strip** — high-level summary in popover displaying aggregate tokens today, 7-day volume, and estimated USD spend across all active providers.
- **Claude live quota companion** — reliable companion script (`Scripts/claude-companion.sh`) maintaining live `limits[]` arrays with stale-file detection.
- **Expanded tool coverage** — native local quota and session sources for Cursor, GitHub Copilot CLI, and Google Gemini CLI.
- **Smarter pace alerts** — native macOS notifications for fast burn cliffs (< 30m) and 50% soft warning thresholds.
- **Cross-provider failover recommendations** — headroom suggestions when current provider burns fast.
- **Agent budget API** — structured JSON CLI export via `meterusage json` reporting `remaining_percent`, `eta_seconds`, `pacing`, and `burn_rate`.

## [0.2.17] - 2026-09-11

### Fixed

- **OpenRouter hover card mixed two budgets** — a key spending limit and the
  account credit balance are separate ledgers. A key-limit row now reports only
  its own headroom; the account balance appears only on the synthesized
  account-balance window.

## [0.2.16] - 2026-09-09

### Removed

- **WidgetKit extension & legacy snapshot writes** — removed `MeterUsageWidget`, `MeterUsageWidget.xcodeproj`, and background `widget-snapshot.json` group-container writes to streamline the app footprint, reduce disk I/O, and eliminate `AppIntents` system-daemon dependencies.

## [0.2.15] - 2026-09-09

### Added

- **Antigravity demo quota & multi-group windows** — added demo data source matching `agy`'s dual model families (Gemini Models weekly/5h and Claude/GPT models weekly/5h).
- **Grouped quota display in side notch HUD** — floating side notch detail cards now render subheaded groups cleanly when a provider reports multiple quota groups.
- **Documentation overhaul with TL;DR sections** — added punchy TL;DR summaries, badges, and quick-start guides across `README.md`, `docs/PRIVACY.md`, `docs/DEMO.md`, and `docs/COMPANION.md`.

### Fixed

- **Side notch text scaling** — applied `.minimumScaleFactor(0.8)` to provider header titles and reset countdowns to prevent string truncation.
- **Menu bar label & event monitor lifecycle fixes** — broke retain cycle in `MenuBarLabel` width callback and ensured global mouse-up event monitor is cleaned up on deallocation.


## [0.2.14] - 2026-09-09

### Added

- **Codex limit resets in side notch** — floating side notch detail cards now
  display available Codex rate limit resets with expiration moments and an
  inline 2-step confirmation action (`Use reset` → `Confirm` / `Cancel`).
- **Side notch context menu reset action** — quick shortcut to trigger
  the next available Codex limit reset directly from the side notch right-click menu.
- **Customizable reset toggle** — new "Codex limit resets" setting under
  Settings → Side notch to turn reset actions on or off (enabled by default).

### Fixed

- **Panel fold prevention during reset** — side notch remains pinned open while
  confirming or consuming a reset so the action is never dismissed mid-flight.
- **Reset error propagation** — side notch cards now show error feedback if
  RPC invocation fails or backend is unreachable.

## [0.2.13] - 2026-09-09

### Added

- **Pacing & burn rate analysis** — linear quota projection for 5-hour and
  weekly windows, highlighting usage states (*well paced*, *on pace*, *burning fast*).
- **Activity telemetry in hover card** — lifetime, 30-day, peak, and today token counts.
- **30-day daily activity chart** — rolling activity histogram in side notch detail cards.
- **Activity telemetry preferences** — toggles under Settings → Side notch to show/hide
  pacing, telemetry, and daily charts.

## [0.2.12] - 2026-09-08

### Added

- **Settings clarity & unknown status surfacing** — clarified provider list, added
  status badges for unknown or degraded service states.

## [0.2.11] - 2026-09-08

### Added

- **Side notch cards & flip geometry** — side notch cards auto-dock and flip
  left/right based on screen position.

## [0.2.10] - 2026-09-04

### Added

- **Per-provider hover cards** — dedicated hover cards for each provider in side notch.

## [0.2.9] - 2026-09-04

### Fixed

- **Side notch hover & drag fixes** — refined hover sensitivity and drag interactions.

## [0.2.8] - 2026-09-04

### Added

- **Side notch HUD** — initial release of floating side notch panel.
- **Compact tray mode** — option to show minimal icon in menu bar.

## [0.2.7] - 2026-09-04

### Added

- **Antigravity live quota & token usage** — live quota limits and token history
  for Antigravity CLI.

## [0.2.6] - 2026-08-25

### Fixed

- **Codex usage display & widget popup** — fixed Codex usage parsing and popup interactions.

## [0.2.5] - 2026-08-24

### Added

- **Notification Center widgets & CLI** — initial widgets and scriptable CLI.
