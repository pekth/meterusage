# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

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

### Removed

- The "Local activity" card (combined totals and per-model breakdown) and its
  "Recent sessions" list; activity now surfaces through the per-provider
  heatmaps.
- The retired ClaudeWatch `claudewatch-agy-cache.json` fallback for
  Antigravity usage and its documentation.

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
