# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

## [0.2.5] - 2026-08-24

### Added

- **Scriptable CLI** — `meterusage json` prints every enabled provider's
  limits as stable snake_case JSON on stdout and exits, without launching
  the menu-bar app. Agents and scripts can read quota without scraping UI.
  `--force` is accepted and ignored — output is always fresh. Output
  carries display names, percentages, reset timestamps, plan labels, and
  credit balances only — the same privacy contract as the popover.
- **Notification Center widgets** — an automatic widget (whichever provider
  is closest to its limit) plus one widget per provider: Codex, Claude,
  Grok, Antigravity, OpenCode Go, OpenRouter. Small shows the worst window
  as a headline figure; medium lists windows with bars and reset
  countdowns — pinned providers default to their current and weekly
  windows. Click a provider widget to switch it to all windows instead;
  a configurable widget with a right-click → Edit provider picker is also
  included. Widgets render the snapshot the app rewrites after every
  refresh into a shared app-group container; they read that one file and
  nothing else — no provider CLIs, no network. The extension is built by
  `xcodebuild` from `MeterUsageWidget.xcodeproj` (a SwiftPM-wrapped binary
  cannot load as a widget); builds without full Xcode skip widgets with a
  warning.

### Fixed

- Heatmap aggregation tests no longer fail every Monday and Sunday: they
  anchored to the live clock, and the grid omits future cells, so the
  tested "tomorrow" did not exist at the start of a week. They now use a
  fixed mid-week anchor.

## [0.2.4] - 2026-08-24

### Fixed

- **Fail-safe update install** — the installer now copies the new bundle to
  a verified replacement before moving the old app aside, and rolls back
  from a backup if the swap fails. Previously a failed copy during the
  swap could leave the app deleted with no recovery.

## [0.2.3] - 2026-08-23

### Added

- **One-click update install** — the update banner's Install button now
  downloads the release zip, verifies its SHA-256 against the digest GitHub
  publishes with the asset (a missing or mismatched digest aborts), swaps
  the bundle in place, and relaunches. Failed installs stay retryable from
  the banner, and release notes remain reachable from its caption.

## [0.2.2] - 2026-08-23

### Added

- **Update notifications** — at most once a day, the app checks the public
  GitHub Releases feed and, when a newer version exists, shows a dismissible
  banner in the popover with a link to the release page. If notification
  permission is already granted (e.g. via quota alerts), a one-shot system
  notice fires per version; it never requests permission on its own.
  The check is unauthenticated, sends no identifier or usage data, and can
  be switched off in Settings → General → "Check for updates".

### Fixed

- An explicit refresh requested while a scheduled sweep was in flight is no
  longer swallowed — previously the popover could keep showing stale numbers
  (for example right after a Codex reset) until the next manual open.

## [0.2.1] - 2026-08-23

### Changed

- **Compact settings layout** — the separate "Providers" and "Menu bar"
  sections merged into one card: each provider row carries its popover
  switch plus a small tray-icon toggle for menu-bar visibility. Refresh
  and Theme became inline label-plus-picker rows, Alerts and Startup
  folded into a single "General" card, and card padding tightened
  throughout.
- **Tighter service status** — per-provider rows use a compact two-line
  layout with hairline dividers; all status detail (description,
  severity badge, checked time) is retained.
- **Color-coded window percentages** — every quota window row now shows
  its percentage in the headroom colour band (green/amber/red),
  including providers that previously printed no figure.

### Removed

- The large hero percentage on quota cards: it duplicated the corner
  summary and the per-window rows, and misread cards with several model
  groups. The corner summary and window rows remain the single source
  for each figure.

## [0.2.0] - 2026-08-21

### Added

- **Quota threshold notifications** — optional local alerts when a quota
  window crosses 80% or 95% used, or an earned reset credit is about to
  expire within 24 hours. Off by default; the "Alerts" section of Settings
  opts in and requests notification permission at that moment, never at
  launch. Alerts are edge-triggered, so a window above the threshold is
  reported once, not every refresh.
- **Copy diagnostics** — a "Copy diagnostics" row under Maintenance in
  Settings copies a privacy-safe summary of each provider's status
  ("quota: unavailable (failed)") for bug reports. The report carries state
  categories only: no paths, account ids, or raw provider errors.
- **7-day sparklines** — Codex and Claude quota cards now lead with a compact
  last-7-days trend line (tokens, or sessions for Codex), answering "am I
  burning faster than usual?" at a glance alongside the 26-week heatmap.
- **Provider marks in the popover** — the plain colour dots that previously
  identified providers in service-status rows, quota-card headers, usage
  rows, and the Settings provider list are now each provider's real mark,
  tinted by severity in the status rows.

### Changed

- **Per-source retry backoff** — a source that keeps failing (provider
  outage, offline) is skipped by scheduled sweeps with an exponential 1m →
  2m → 4m … 30m cap backoff instead of being retried every cycle. Explicit
  refreshes (button, wake, popover open) always bypass backoff. Permanent
  conditions (CLI not installed, not signed in, no data) never back off.
- **Estimated costs disclose their rate vintage** — cost captions now carry
  the rate-table snapshot month (e.g. "est. Jul 2026 rates"), and the
  snapshot date in `Pricing.swift` is a machine-readable constant, so a
  stale rate table reads as stale instead of silently drifting.

## [0.1.6] - 2026-08-19

### Changed

- Codex quota rows keep the reset countdown and local reset time on one line.
- Model-specific quota headings drop the redundant "usage limits" suffix, so
  headings such as `Weekly` and `GPT-5.3-Codex-Spark` stay compact.

## [0.1.5] - 2026-08-18

### Changed

- **OpenRouter removed from the system tray** — OpenRouter is pay-as-you-go
  (no quota window), so it no longer appears as a menu-bar cluster or in the
  "Menu bar" tray-selection section of Settings. It still works as before in
  the popover.

## [0.1.4] - 2026-08-18

### Added

- **Menu-bar provider clusters** — every enabled provider now appears in the
  system tray as its own compact `[mark] %` cluster, so you can glance at
  several quotas at once (Codex, Grok, OpenCode Go, and friends) instead of a
  single most-constrained figure.
- **Real provider logos in the tray** — Codex and Claude use the same marks as
  ClaudeWatch, and Grok, OpenCode Go, and Antigravity use their own logos.
  Each is bundled as a tintable template image so the mark still carries the
  provider's service-status colour.
- **Per-provider tray selection** — a new "Menu bar" section in Settings picks
  which providers show as clusters in the tray, independent of which appear in
  the popover.
- **Hover tooltip** — hovering the tray item shows a per-provider usage and
  service-status summary plus the last-refresh time.

### Changed

- The tray now honours provider-visibility changes immediately instead of
  waiting for the next scheduled refresh.


## [0.1.3] - 2026-08-16

### Added

- **Codex weekly heatmap** — sessions per day read from
  `~/.codex/sessions/**/*.jsonl` (only each rollout's start timestamp; session
  payloads are never opened), rendered inside the Codex quota card.
- **Claude weekly heatmap** — tokens per day from your local transcripts,
  rendered inside the Claude quota card.
- **Heatmap view modes** — each grid switches between daily, weekly, and
  cumulative aggregation with a segmented control.
- **Instant hover tooltip** on heatmap cells showing the date and token count
  (sessions for token-less Codex), floating above the hovered cell.
- **Settings** — a master "Show heatmap" switch plus per-provider Codex and
  Claude heatmap toggles.

### Changed

- Grok quota now re-reads its OIDC token from `~/.grok/auth.json` on every
  refresh instead of caching it at launch, so a `grok` re-login or token
  rotation no longer leaves the app on a stale credential until relaunch.

### Fixed

- Grok quota maps the billing service's string-form 401 body
  (`{"error":"Invalid or expired credentials"}`) to a "not signed in" state
  instead of a generic failure.


## [0.1.2] - 2026-08-15

### Added

- Live Grok weekly usage limits read from the same billing service the Grok
  CLI uses, with duplicate usage rows dropped.
- OpenCode Go account quota windows, rolling usage windows, and
  share-of-last-30-days bars.
- Provider usage dashboard expansion, adaptive menu-bar/popover sizing, and
  status-page links.
- Codex reset notifications, guarded to fire only on genuine usage resets,
  and a repaired reset confirmation flow.

### Fixed

- Grok, Antigravity, and OpenCode Go usage reads.
- OpenCode Go window semantics now match the stats `updatedAt` field.
- Codex usage display semantics and usage severity colours.

## [0.1.1] - 2026-08-01

### Added

- App icon, generated from the menu-bar glyph geometry.
- Docs for feeding the Claude quota bars via a companion file.

## [0.1.0] - 2026-08-01

### Added

- Initial release: live Codex and OpenRouter quotas, optional Claude quota
  bars from a companion file, local usage rows, service status, and a 26-week
  activity heatmap.
