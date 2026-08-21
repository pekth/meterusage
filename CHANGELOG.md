# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Portable `MeterUsageCore` source with v1 Linux GTK3/Ayatana and Windows
  Win32 tray shells alongside the full macOS UI.

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
