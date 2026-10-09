# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Add an isolated Codex cloud test profile for the existing candidate UI. It
  starts disconnected, reads account allowance after browser sign-in, and
  excludes demo data, local activity and other providers. Candidate profiles
  cannot check or install updates, change login items or send notifications.
  Profile validation rejects nested symlinks before app or helper writes.

- Add candidate account setup for Codex browser sign-in and opt-in Claude
  Desktop allowance, with automatic refresh, account isolation and disconnect.
  Grok consumer connection remains unavailable. Native and provider acceptance
  are pending; the published Swift app is unchanged.

- Add a macOS TypeScript/Electron/React migration candidate and headless
  schema-1 JSON CLI, with synthetic provider, account, history, pacing and IPC
  tests. Use pnpm, Vite+, Tailwind, Vitest and electron-builder. Retain Swift as
  the behavior oracle until native acceptance passes. No Electron release or
  installed-app replacement is included.

### Changed

- Group candidate Settings by task, show six accent color swatches, and label
  provider collection separately from menu-bar and side-notch display.
  Turning collection off retains the saved display preference.

- Label local activity as activity on this Mac, keep folder-based accounts
  under advanced settings, and omit local CLI activity from separately
  connected account cards. Record the new opt-in authentication boundary.

- Record synthetic Claude and Codex source-scanner timings alongside the Swift
  baseline. Counts and cache transitions pass; packaged-app performance, idle
  RSS and native GUI acceptance remain open.
- Verify the current Apple silicon Electron candidate with 128 macOS fixtures,
  TypeScript checking, production bundles, extracted ZIP signature checks and
  the native schema-1 demo CLI. The candidate is ad-hoc signed and unpublished;
  native GUI acceptance and cutover remain open.
- Replace the earlier React Native/Tauri Windows plan with the selected macOS
  Electron direction. Windows implementation, installers, CI, testing and
  release are paused until a test machine is available.
- Correct privacy documentation for Codex token/model ledger reads, transient
  project paths, existing Grok/OpenCode keys, managed accounts and hourly
  update checks. Provider files and credentials stay in the main process.

### Fixed

- Launch Codex account helpers with the documented stdio transport. Keep
  interpreter search paths available without inheriting credential variables.
- Keep provider display controls available for active additional accounts when
  primary collection is off, and isolate connection-test helper discovery.

- Bound browser-demo notch cards and strips to the viewport height. Keep
  provider rings at full width while the strip scrolls.
- Hide scrollbar indicators throughout the candidate while retaining scrolling.
- Ignore display and theme publications after the candidate tray is destroyed.
- Retain each window's document ID before destruction so closing a candidate
  window does not access destroyed web contents or remove its replacement.

- Reject malformed connection provider values before consent and target the
  bundled Desktop Keychain helper explicitly at arm64/macOS 13.
- Disable cancelled or disconnected account collection before cleanup, recover
  unfinished sign-in profiles, and verify Claude identity after HTTP failures.
  Preserve connection readers across cache clearing and headless reports.
- Stop Claude credential rereads after disconnect, discard unverified account
  allowance on collection timeout, and retry retained Codex cleanup from the
  sign-in button before opening a new login.
- Show general weekly Claude allowance, hide unsupported reset actions, clear
  replaced-account alert suppression, and exclude remote usage from local totals.

- Check repaired cache token fields directly in the synthetic regression test;
  a raw substring check could also match an unrelated timestamp or opaque ID.

- Rescan corrupt Claude cache entries with non-finite costs or unsupported
  dates. Ignore unsupported optional provider timestamps before JSON output.
- Use canonical temporary paths in candidate fixtures and demo commands.
  Check the packaged executable's exact directory-entry spelling on both
  case-sensitive and case-insensitive filesystems. Preserve symlink rejection.
- Remove unknown daily-history fields before saving or publishing renderer
  state, while preserving larger historic totals and account separation.
- Keep readable sessions when a sibling disappears or cannot be opened.
  Preserve Codex metadata/ledger fallbacks and propagate scan cancellation.
- Scope the reset-button setting to side-notch details and context menus;
  retain flyout redemption with the same availability and confirmation checks.
- Restore 30-day rolling cost/token share bars and the existing adaptive
  Claude, Antigravity, OpenCode Go and OpenRouter identity colours.
- Validate optional archive metadata and restore only known fields. Reject
  reset redemption unless the credit is reported available and unexpired,
  including after the confirmation dialog.
- Restore the primary Claude companion-file order and file modification time
  fallback. Keep valid required quota when optional OpenRouter credits stall
  or additional Codex model limits are malformed.
- Show today's usage counts and reading age, restore textual tray outage/reset
  summaries, and adapt the existing Grok mark tint to light and dark appearance.
- Keep candidate service health visible when provider usage is hidden, with
  buttons for the existing public status pages. Restore notch ambient ETA
  from raw window pace and hide it when pacing is off.
- Invalidate live readings and reset confirmations when a candidate account
  source changes. Reject late results and reset completion from the old source
  while keeping dated slot archives and durable history.
- Measure shared cards at full height. Reject captures above 8,192 pixels with
  an explicit error instead of exporting a cropped image.
- Hide candidate accounts whose configured directory disappears. Bind sharing
  to the displayed card, hide forecasts when pacing is off, restore active-window
  burn detail and bound tall notch cards to the display work area.

- `Scripts/make-app.sh` now downloads and verifies the prebuilt app by default,
  so installation from a Git checkout does not need Swift. Source builds require
  `--build-from-source`. Failed downloads or verification never trigger compilation.
  Copy and verify the replacement in staging so a failed copy or signature check
  preserves the existing generated app.
- Make the prebuilt app download the default installation path. Clarify that
  Swift and Xcode Command Line Tools are needed only to build from source,
  link directly to the current Apple silicon app ZIP, and keep build commands
  in the contributor guide instead of the README.

## [0.2.41] - 2026-10-05

### Fixed

- Remove a redeemed Codex reset credit from the archived snapshot immediately,
  so offline refreshes and relaunches cannot offer it again.
- After a successful Codex "Use reset", discard the account's old pacing
  estimate. The first fresh quota reading starts a baseline; later usage
  growth supplies the burn rate and ETA. Baselines survive relaunch and restart
  when the quota cycle changes or usage decreases.


## [0.2.40] - 2026-09-29

### Added

- **Codex sessions now show an estimated cost.** The local Codex source reads
  each rollout's model from its `turn_context` event and prices the session's
  tokens against a new OpenAI/Codex row in the pricing table, so the burn
  attribution and cost figures include Codex instead of a hardcoded `$0`. The
  table covers the GPT-6 family (GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, GPT-6
  Astra) plus the still-supported GPT-5.6 Sol/Terra/Luna and `gpt-5.3-codex`,
  using the published Standard list prices. Codex's cache model is applied as
  published: cached input is billed at the model's cached rate (GPT-6.1 Sol's
  new 5% tier), and Codex charges nothing for cache writes, so cache writes
  are free here. A session whose model cannot be read still prices, flagged at
  the current Codex default tier, rather than silently reporting zero. Pricing
  remains a local estimate — see `docs/PRIVACY.md`.
- **Accent colour themes.** Settings → Appearance now offers an accent palette
  (Blue, Violet, Teal, Amber, Rose, Graphite). It recolours the app accent and
  the primary provider's (Codex's) mark across the popover, the menu bar, and
  the side notch, tints the popover's interactive controls, and drives the side
  notch's chrome — its body, hover card, and ring disc/track all take the
  accent. Quota headroom colours and every other provider identity stay fixed.
- **Dark surfaces are dark grey, not black.** The popover backdrop and cards and
  the side notch body and hover card now use dark greys, so the app reads as one
  object instead of a black slab.

### Changed

- **Pricing table refreshed to the current rates.** Claude rows now use the
  published Opus 5.5 (`$4` / `$20`) and Sonnet 5.5 (`$2` / `$10`) list prices,
  with cache reads and writes derived from the same 0.1x / 1.25x multipliers;
  Fable and Haiku are unchanged. The verification stamp moved to `2026-09`.
  One rate still covers a whole Claude family, so an older generation is
  estimated at the current generation's price.

## [0.2.39] - 2026-09-27

### Fixed

- **Pace displays stop hiding a deficit once the burn cools.** The quota bar,
  side-notch banner and window rows, and the menu-bar ETA chip now report the
  window's own pace, so a window ahead of the even-burn line keeps its
  projected run-out — a weekly at 43% with 6 days left — instead of flipping to
  "on pace" 30 minutes after the last local session. The present-tense
  "burning fast" failover nudge, pace alerts, and `meterusage json` pacing stay
  gated on a current burn, so the stale-nudge fix is unchanged.

## [0.2.38] - 2026-09-26

### Added

- **Multi-account meters for Codex and Claude.** People who hold two or more
  accounts with the same tool get one independent meter row per account
  instead of a merge — two accounts' windows are two different budgets. Add
  accounts in Settings → Second accounts (name + config directory, any
  number, add or remove freely); readings appear after relaunch once the
  directory exists. The Codex slot spawns its own `codex` subprocess with
  that home (the CLI authenticates as that account; meterusage still never
  touches any auth file); the Claude slot scans that account's own transcript
  tree, plan file, and companion quota snapshot. Account rows carry your
  label ("Codex · Work") and a digit beside the mark in the tray and side
  notch, and the `meterusage json` report lists each account with its own
  windows, plan, and reset credits plus an additive `account` label field.
  No account identifier is ever read or displayed — labels are user-typed,
  and each account's history, archive, and alerts are kept separate.

## [0.2.37] - 2026-09-25

### Fixed

- Codex service status reads the real outage vocabulary again. status.openai.com
  runs on incident.io, whose compatible feed reports `full_outage` where
  Statuspage pages report `major_outage`, so an active outage rendered as
  "Unknown"; it now reports the outage.

### Changed

- Provider marks in the menu bar, side notch strip, and service-status rows keep
  the provider's identity colour while its service is healthy. Only a check that
  diverges from healthy repaints the mark — amber on a degraded service, red on
  an outage, grey when the check is unreadable — and quota headroom stays on the
  ring and percents, where it belongs.

## [0.2.36] - 2026-09-25

### Fixed

- The Providers tray button beside the "Notch" caption is visible in both switch
  states again. The filled SF Symbol variant it used for the on state is absent
  from the system symbol catalog and drew nothing; the outline glyph now serves
  both states with the tint carrying the difference.

## [0.2.35] - 2026-09-23

### Fixed

- Unreadable daily history is preserved instead of overwritten. Copy diagnostics
  reports a sanitized load or save error, and the app suspends history writes
  until the file is repaired and the app restarts.
- The side-notch right-click menu stays the same for every provider. Dragging
  starts from the strip or card again, keeps the strip anchored while the card
  hides, and saves the final position when released.
- Antigravity usage recovers when its existing local container runtime stops.
  Recovery does not create a machine or pull an image, and failures are bounded
  by a cooldown.

## [0.2.34] - 2026-09-20

### Fixed

- **Active window burn shows the active session's repo, not automation
  threads.** Codex Desktop scheduled automations run in per-thread folders
  instead of a repo checkout, so the card named thread directories (morning
  brief, email review) rather than the repos being worked in. Sessions are now
  flagged at scan time and skipped by burn attribution on both surfaces, while
  telemetry and pace recency still count them since they really burn quota.

## [0.2.33] - 2026-09-20

### Fixed

- **Active window burn no longer shows an all-zero card.** When the active
  window's only sessions carried no token ledger (for example Codex realtime
  sessions whose rollout records no `token_count` event), the burn card
  rendered fabricated zeros ("0 tokens", a 0% contributor row, "Avg/turn: 0").
  Sessions without a token ledger are now excluded from burn attribution, so a
  scope with no measured burn yields no breakdown and the card hides instead —
  the same rule the popover already applies to an empty week.

## [0.2.32] - 2026-09-17

### Fixed

- **Side notch top edge moved a pixel when hovering Grok or OpenRouter.** Card
  heights measured fractional for some providers (532.5pt, 443.5pt) and whole
  points for others. AppKit rounds a fractional window frame up, leaving the
  window up to a point taller than its content, and SwiftUI centered that
  leftover above and below the content, so fractional-height cards drew about
  a pixel lower than the rest. The content is now anchored to the top of the
  window, and the strip's width and height are whole points, so the visible
  top edge lands on the same row for every provider.

## [0.2.25] - 2026-09-17

### Fixed

- **Antigravity pacing banner went silent on an exhausted window.** When the
  most-constrained window sat at 100%, its ETA computed as `nil` and the side
  notch detail card showed no pacing banner at all, unlike every other
  provider. An exhausted window now reports its reset countdown, so the banner
  renders with the subtitle "Exhausted early — waiting for reset" instead of
  disappearing or claiming "Paced to last until reset".

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
