# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

## [0.2.27] - 2026-09-17

### Fixed

- **Side notch stuttered when sweeping hover across providers.** The 0.2.26
  glide animated AppKit frame resizes, and overlapping frame animations fight
  each other, so rapid switches shuddered worse than the original snap. The
  glide now lives in SwiftUI, which retargets interrupted animations cleanly:
  the card container height interpolates on hover change and the controller
  tracks each step instantly. Folds, flips, drags, and data ticks still snap.

## [0.2.26] - 2026-09-17

### Fixed

- **Side notch card edge flapped when switching providers.** Each provider's
  detail card mounts at its own height and the window snapped to it, so the
  card's bottom edge jumped while the strip stayed put. Height-only resizes
  now glide; folds, card side flips, drags, and screen changes still snap.
  The pointer beak glides to the newly hovered ring with it.

## [0.2.25] - 2026-09-17

### Fixed

- **Antigravity pacing banner went silent on an exhausted window.** When the
  most-constrained window sat at 100%, its ETA computed as `nil` and the side
  notch detail card showed no pacing banner at all, unlike every other
  provider. An exhausted window now reports its reset countdown ("how long
  until you can go again"), so the banner renders with an honest
  "Exhausted early — waiting for reset" subtitle instead of disappearing or
  falsely claiming "Paced to last until reset".

## [0.2.24] - 2026-09-17

### Fixed

- **Today total survives a session that runs past midnight.** Today counted
  only sessions started today, so the card collapsed to 0 at local midnight
  and stayed 0 until a brand-new session began. A session now counts toward
  today when its activity window (start to its store's last write) overlaps
  today, so a session in flight across midnight keeps the day non-zero. A
  session that finished before midnight still belongs to yesterday.
- **Side-notch card refreshes when you open it.** The panel is always on
  screen, so unlike the popover it never refreshed on open. Unfolding it now
  refreshes data older than 20 seconds instead of showing a reading up to a
  full scheduled-sweep interval old.
- **Burn attribution names OpenCode Go projects instead of the provider.** The top row read "OpenCode Go" with the provider's whole week. OpenCode Go sessions carry a working directory, so the source splits its week total by project and attribution shows one row per project. Providers that cannot split (Antigravity, OpenRouter) keep the single provider row.

## [0.2.23] - 2026-09-16

### Fixed

- **Today total counts sessions started today, at every hour** — deriving
  today from UTC day buckets still zeroed each evening past 20:00 EDT. The
  strip now counts sessions started today against local midnight, which holds
  in any time zone, and the 7-day total still sums the UTC buckets.

## [0.2.22] - 2026-09-16

### Fixed

- **Today total no longer reads 0 with activity present** — Codex and Claude
  bucket daily activity by UTC midnight, but the strip compared those buckets
  with the local calendar. West of UTC that shifted today's bucket onto
  yesterday, so the strip showed 0 and "no sessions today" while "last 7
  days" still showed the tokens. Daily buckets are now compared in UTC.

## [0.2.21] - 2026-09-14

### Fixed

- **Share menu survives panel folding** — the picker anchors to the content
  view (which outlives the hover card) with the click-time button rect, so
  folding mid-share no longer dismisses it. The hold-open flag this replaces,
  with its stuck-forever failure mode, is removed.
- **Share crop no longer depends on strip measurement** — the card column is
  a fixed 250pt, so the capture rect derives from content size and card side
  only.

## [0.2.20] - 2026-09-14

### Fixed

- **Share menu detached from its button** — the picker anchored to the whole
  panel rect. The Share button is now a real `NSButton` handing itself to the
  picker at click time, so the menu hugs the button.
- **Share menu dismissed mid-reach** — sliding the pointer toward the menu
  folded the hover card after 450ms, unmounting the button underneath it.
  The panel now stays open while the share menu tracks and releases when
  menu tracking ends.
- **Share snapshot included the ring strip** — captures crop to the fixed
  250pt detail-card column, strip excluded.

## [0.2.19] - 2026-09-13

### Fixed

- **ALL AI totals missed non-session providers** — the today strip only summed
  Codex and Claude sessions, so a day worked in OpenCode Go read as 0 tokens
  today. OpenCode Go, Antigravity, and OpenRouter now report today/week token
  totals and the strip sums them.
- **Burn attribution showed stale sessions** — attribution covered only the
  last 8 Codex/Claude sessions of any age. It now covers every token-bearing
  provider over the same 7-day scope as the totals, and an empty week hides
  the section instead of presenting old burn as today's.
- **Burn shares rendered as 9,998%** — the percent-scale share was multiplied
  by 100 a second time. Shares render once, with sub-1% contributors shown as
  `<1%` instead of `0%`.
- **"Last 7 days" counted 8 days** — the `>=` range on a −7d start spanned
  today plus 7 prior days. All calendar-day windows now use −6d.
- **Failover nudge recommended the burning provider** — "Codex burning fast.
  Switch to Codex" can no longer happen; burning providers are excluded from
  alternatives and the nudge wraps instead of truncating.
- **Settings Accounts listed disabled providers** — only enabled providers are
  shown, since a hidden provider is not read at all.
- **Share menu detached from its button** — the picker anchored to the whole
  panel rect. The Share button is now a real `NSButton` handing itself to the
  picker at click time, so the menu hugs the button.
- **Share menu dismissed mid-reach** — sliding the pointer toward the menu
  folded the hover card after 450ms, unmounting the button underneath it.
  The panel now stays open while the share menu tracks and releases when
  menu tracking ends.
- **Share snapshot included the ring strip** — captures crop to the fixed
  250pt detail-card column, strip excluded.

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
