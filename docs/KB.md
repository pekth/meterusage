# Project knowledge

Release documentation refresh: 2026-10-22 for build 75.

## Edition documentation

- [ADR 0024](adr/0024-electron-primary-swift-retirement.md) makes Electron the
  sole active feature-development target. Freeze the legacy Swift app for new
  features; retain critical maintenance, compatibility and rollback until
  native acceptance, deliberate cutover and retrievable archive checks pass.
  Source retirement is pending. Electron-required Swift helpers and assets stay.
- [Swift 0.2.41](swift/README.md) is the published default install route.
  [Electron 0.3.0-beta.6, build 75](BETA.md) is an opt-in public prerelease,
  signed and notarized for Apple silicon. Native acceptance remains incomplete.
  Source manifests retain 0.2.41; packaging sets the beta version and Settings
  shows the running bundle version. Stable updaters do not offer the beta.
- Both implementations remain in their current source trees. Shared app name,
  bundle ID and default data/preferences prevent safe normal-profile coexistence.
  Use only documented isolated QA profiles.
- [Versions](VERSIONS.md) records the accepted one-app development direction
  and staged retirement. It makes no layout, version, CI, identity or cutover
  change. ADR 0010's acceptance and compatibility requirements remain in force.
- Swift and stable Electron updaters use GitHub's latest-release endpoint.
  Electron beta builds (version `-beta.N`) read the release list and accept
  `-mac-arm64` assets, so betas update in-app from beta 5; see
  [update channels](VERSIONS.md#update-channels).
- Installed beta 5 recorded discovery of beta 6 on 2026-10-22. Automated
  installation and relaunch were not completed; native UI control was unavailable.
- Swift-to-Electron native upgrade and rollback remain blocked pending a
  separate macOS test user or VM. Swift 0.2.41 requires the unsuffixed
  `MeterUsage-<version>.zip` release asset and a GitHub SHA-256 digest. Its
  install script re-signs the replacement ad hoc, so the installed signature
  and native helper behavior need explicit acceptance. Both editions share
  the preferences domain, durable history and quota archive without a bulk
  migration. Neither updater retains a persistent rollback copy. See the
  [stable cutover checklist](VERSIONS.md#stable-cutover-checklist).
- Candidate gaps include Settings account overview, seven-day sparkline, reset
  timing display, update feedback and tray refresh. Smaller display omissions
  remain distinct. Current source adds AG Desktop/OpenCode setup, restores Bun
  discovery and matches activity grid geometry. See the candidate guide.
- Edition documentation was reconciled against revision
  build source `6ce695324e54bb09bf6e5ab36fd4733875c94427`.
- Current product screenshots use build 61's renderer and synthetic demo data.
  Old product captures are removed; see [capture provenance](SCREENSHOTS.md).

## Repository state

- Default branch: `main`.
- Swift baseline revision: `4b913db3a3a8eb2602296489872af2ecaa5d0530`. The Electron candidate is the accompanying migration change; native acceptance remains open.
- This index is public-safe repository documentation. It does not prove current local provider state, runtime behavior, release availability, or external service state.

## Product and source facts

- Claude Connect recognizes HTTP 403 responses with an explicit
  `cf-mitigated: challenge` header as provider browser verification blocking
  automation. It reports a fixed message and preserves the current source.
  The failed Desktop method offers a manual usage-page action in normal
  Settings. Opening that page does not connect MeterUsage or report quota.
  Synthetic checks do not establish native or live-provider acceptance.

- Electron Claude plan labels recognize known organization, seat and user tiers
  in that order. An unknown higher-priority value permits a known fallback;
  unknown-only metadata stays unavailable instead of exposing internal labels.
  Claude Desktop now uses consent-tagged web-session cookies instead of OAuth
  cache selection. Nested bootstrap identity and unique intended membership
  gate UUID-bound usage. Identical cookies deduplicate; conflicting sessions
  fail closed. Failed Connect preserves CLI selection. Synthetic checks do
  not establish native compatibility or live allowance.

- Unreleased Electron source adds opt-in Muse Code allowance with `muse serve`
  and the official experimental MSP `usage/read` method. The source starts
  disabled, reads no credential files and sends no model turn. It preserves
  observation age and percentages, including provider values above 100, while
  rejecting absent, expired or malformed observations. Settings, demo cards,
  menu-bar/notch provider ordering and JSON quota reporting use the separate
  `muse` provider. Saved opt-in also gates headless collection; stopping cancels
  active reads and invalidates allowance. JSON includes `observed_at`, and
  allowance stays in memory, outside the shared archive, to preserve rollback
  compatibility. Muse.ai native session import remains unimplemented; no
  verified native store path or schema is available. Native/live validation
  remains separate. See [ADR 0033](adr/0033-muse-code-subscription-allowance.md).

- Unreleased Antigravity Desktop setup reuses the existing connection controls,
  preferences, IPC and account-bound source. It requires one running same-user
  desktop language server with a CSRF token and PID-owned IPv4 loopback port.
  Fixed quota/status RPCs use request-scoped TLS handling, redirect rejection,
  1 MiB response limits and bounded time. Account fingerprints are opaque;
  credentials stay in main-process memory. Empty modern quota and missing
  fractions remain unavailable. Local CLI usage stays detached. Synthetic
  fixtures cover account switches, closure, transport failures and connection
  races. Native/live-provider proof and release inclusion remain pending.
  See [ADR 0026](adr/0026-antigravity-desktop-local-quota.md).

- Heatmap hover/focus readouts use compact token and session totals, including
  local, account, session-only, daily, weekly and cumulative grids. Exact grouped
  counts remain in tooltips and accessible labels. Summary counts compact from
  1,000. This follow-up is separate from the published build 54 artifact.

- Onboarding and Settings offer provider-specific source choices: Codex browser
  sign-in or CLI, Claude Desktop or Claude Code CLI, Antigravity Desktop or
  Antigravity CLI, and Grok CLI or opt-in Grok Bot Desktop Beta. Choosing
  an option does not change collection until its action is used. Use CLI waits
  for MeterUsage-owned connection cleanup before selecting existing local
  collection. Ordinary Disconnect still prevents automatic local fallback.
  CLI data covers this Mac; Claude CLI allowance needs a companion usage file.
  Done follows the source choices and remains optional. Demo and isolated live
  test profiles cannot switch to local collection. See
  [ADR 0023](adr/0023-onboarding-source-choice.md).

- Candidate Settings uses category navigation for Connections, API connections, Appearance,
  General, Providers, Side notch, Usage details and Diagnostics. Connection
  summaries show the current source, collection state and reading availability;
  Configure reveals the existing setup actions. Category changes preserve pending
  source selection, and choosing a method still requires its explicit action.
  Existing preferences and additional-account controls remain. Demo account
  restrictions appear before disabled connection actions. Provider column
  headings replace repeated visual labels on wide windows; at 450 pixels or
  narrower, each provider has two labelled control columns below its name.
  Input accessible names and full label hit areas remain. Settings action
  errors retain their alert role, message and dismissal in a sticky banner.
  Advanced account rows wrap without changing their save/remove behavior.
- Settings displays the running Electron bundle version supplied by the main
  process. Source previews without bundle metadata omit the version instead
  of showing the legacy Swift version.
- Candidate Usage keeps Service status first and visible, before provider usage.
  Provider/account tabs show one usage card at a time in saved provider order.
  Arrow keys and Home/End switch tabs; removing a selected slot falls back to
  the first available slot. Local summary metrics and measured burn remain in
  the All-provider activity breakdown disclosure. Summary metrics use three
  equal columns, with two columns at 360 pixels or narrower. Recorded
  activity labels distinguish telemetry counters from account/local totals
  without changing values or adding a time scope. Archived quota retains its
  timestamp and failure reason in a warning well. Long labels and metadata
  wrap; percentages and reset actions stay together. This is resilience
  polish, not a reproduced overflow fix.
- Live menu and side-notch cards show the first two available recorded metrics,
  with the remainder under More activity. Usage by period and active-window burn
  also use closed disclosures. Quota, eligible reset actions and heatmaps stay
  visible. Spacing and sparkline height are reduced without changing font-size
  choices or source values. Static exports retain all recorded metrics and full
  period/burn data without those disclosures.
- Static shared cards omit footer actions, reset buttons and the heatmap
  selector. Credit details and the 26 weeks label remain. Export heatmaps omit
  the unused hover readout space. Live readouts also use only their text height. Full-height capture,
  frozen account selection and the 250-pixel export width remain unchanged.
  Dark secondary text uses `#b0b0b8`; light text and semantic colors retain their
  existing rules. Usage, Settings and notch detail buttons use 120 ms background
  feedback only for enabled fine-pointer hover with reduced motion off. Press
  and keyboard focus remain immediate. Renderer fixture and build proof does
  not establish rendered layout, sticky alerts, motion or native export proof.

- Electron heatmaps show compact counts and readable dates for daily,
  weekly or cumulative scope on hover and keyboard focus. Tooltips and accessible
  labels retain exact grouped counts. Each live heatmap has one Tab entry; arrow keys move between days and
  Home/End reach the first/last available cell. Tab leaves the heatmap. Shared
  images have no focusable cells. Account, local-token and session-only
  providers share the same heading, caption, cells and intensity legend.
  Hover and keyboard focus replace the legend with the compact dated readout
  in a natural-height row. Long readouts can grow the card; the top and rail stay anchored. Unreported account days have subtle solid
  outlines; reported zeroes have filled neutral cells. Each source retains its
  own time range and units. Count-only providers report token totals unavailable.
  Reset buttons use the compact control size. An open notch
  interaction checks the native cursor to recover a missed pointer exit, then
  closes details through the existing delay and temporary action guards.
  The strip always shows usage rings and percentages, with no design selector
  or dots option. Disable/hide clears expanded state before re-enabling.
  Legacy pin data has no effect and pin controls are removed.
  Notch sizes use integer pixel text and spacing instead of CSS zoom.
  [ADR 0019](adr/0019-single-design-notch.md) records this candidate correction.
  Source fixtures do not prove native pointer events, keyboard access in the
  non-activating panel or rendered anchors. [Side notch](SIDE-NOTCH.md) records
  the behavior and native checks.

- Connected Codex menu cards expose **Use reset** for available, unexpired
  credits. The existing validated IPC and native confirmation use the captured
  connection profile. Confirmation rereads allowance before one helper consume;
  disconnect, stopped connections and profile changes reject the action.
  Coordinator source replacement, including Clear local scan cache, and stop
  abort active resets through the existing consumer signal. Cancellation during
  fresh eligibility prevents consume dispatch; a request already sent cannot be
  undone. The late-result guard still prevents an obsolete reset from changing
  pacing or refreshing its replacement. These cancellation checks use synthetic
  fixtures, with native and live account proof pending.
  Success collects fresh quota under the reset-pacing rules. This also applies
  in `--codex-test-profile`; other collection and system-effect restrictions
  remain. [ADR 0017](adr/0017-connected-codex-menu-reset.md) narrowly supersedes
  ADR 0012's reset prohibition. Synthetic proof is separate from native display,
  native confirmation and user-owned live redemption.

- Candidate onboarding lives in Settings and reuses its account connections.
  Incomplete setup opens Settings on launch or app activation. Done persists
  `onboardingCompleted` before returning to usage; a failed write leaves setup
  open. Sign-in is optional. The main panel has no setup card. Existing completed
  profiles retain their preference. [ADR 0014](adr/0014-settings-onboarding.md)
  records this placement; native acceptance is separate from source validation.

- The Electron candidate implements opt-in desktop account setup in `src/main/connections.ts`, `src/main/providers/claude-desktop.ts` and the renderer. Codex discovers an existing app helper and uses a separate generated keyring-only profile with browser login. Claude uses a fixed native Keychain helper, bounded sandboxed read-only schema-24 cookie selection, nested bootstrap verification and UUID-bound web usage after new session-cookie consent. Old untagged identities require reconnecting and authorize no private reads. No OAuth cache fallback remains. New Grok Bot Desktop connections select the active account-bound encrypted access token and optional team through a fixed Keychain item and bounded Connect allowance request. Saved Cursor connections retain their immutable SQLite reader and fixed identity-before-allowance requests. Both use opaque account binding. Nonempty WAL/journal files, ambiguous evidence and observed races fail closed. These are source and synthetic-fixture facts, not native or live-provider proof. [Desktop connections](DESKTOP-CONNECTIONS.md), ADR 0011, [ADR 0027](adr/0027-grok-cursor-closed-reader.md) and [ADR 0028](adr/0028-grok-bot-desktop-reader.md) define setup, data coverage, privacy and acceptance gaps. Connected-account cards omit local CLI activity, clear old quota on account changes and do not restore quota archives across launches.

- Each Claude Desktop allowance attempt obtains the Keychain password once
  and reuses it only in attempt-local memory. Local account and session stores
  are still read before and after requests. This avoids a second Keychain
  authorization during one Connect without weakening identity checks.
  Synthetic regression coverage does not prove live connection acceptance.

- Antigravity Desktop quota uses compact model headings and limit labels.
  It preserves provider-reported bucket values and resets; duration metadata
  is added only for explicit Weekly or 5-hour labels. Missing allowance under
  a saved account remains unavailable. This presentation does not establish
  that Desktop and the CLI use the same account. The Cursor process guard
  excludes only Apple's `CursorUIViewService` under `/System/Library/`, while
  retaining active-editor and database guards.

- meterusage is a macOS menu-bar app that displays AI coding-assistant quota and usage signals. `README.md` describes provider clusters, quota cards, heatmaps, sparklines, alerts, diagnostics, and a scriptable JSON CLI.
- The published app is Swift Package Manager based, targets macOS 13 or later, and includes an executable target and a test target. `Package.swift` is the source for this package structure. Its AppKit and SwiftUI imports require macOS for package build and test checks; Swift itself supports other platforms. `AGENTS.md` describes a generic macOS SSH route for Linux development without private host aliases.
- `README.md` links directly to the prebuilt v0.2.41 app ZIP as the default installation path. Installing and running it does not require Swift, Xcode, Command Line Tools, or Git; its Swift runtime ships with macOS. `Scripts/make-app.sh` also downloads that pinned release by default, checks its SHA-256 and code signature, and prepares `dist/MeterUsage.app` without compiling or installing developer tools. It copies and verifies the replacement in staging on the destination filesystem before replacing existing output, so copy or verification failures preserve the previous generated app. It rejects unsupported platforms and never falls back to a source build. Source builds require `--build-from-source` and are documented in `CONTRIBUTING.md`. The v0.2.41 asset targets Apple silicon and macOS 13 or later, is ad-hoc signed, and is not notarized. GitHub's source archives contain source and scripts, not an app bundle. ADR 0009 records the script's default.
- Swift provider data sources are implemented under `Sources/MeterUsage/Services/`; the candidate adapters live under `src/main/providers/` and `src/main/composition.ts`. `docs/PRIVACY.md` describes the boundary for local files, provider CLIs, documented network endpoints, and data reduction before display.
- Antigravity CLI quota and usage share a bounded Docker/Podman runtime resolver. It prefers a healthy runtime and can start only an already-existing `podman-machine-default` after an inspect check; it never creates a machine or pulls an image. Concurrent recovery calls are serialized; failed starts have a 60-second cooldown. Internet or authentication failures are not repaired by restarting a healthy runtime.
- Demo mode uses synthetic data. `README.md` and `docs/DEMO.md` describe it as the path for screenshots and local UI inspection without provider accounts.
- `Resources/Info.plist` and `CHANGELOG.md` record version 0.2.41, build 46, dated 2026-10-05. This release collects fresh quota observations after an accepted manual Codex reset, derives pacing and ETA from later usage growth, and removes the redeemed reset credit from archived quota data. The previous release was 0.2.40, which added accent colour themes, Codex cost estimates, and refreshed model prices. Repository version and release-note entries do not prove that a GitHub Release or its downloadable asset has been published.
- `CONTRIBUTING.md` requires focused changes, synthetic fixtures, and `swift build`, `swift test`, and `Scripts/make-app.sh --build-from-source` before a code pull request. `Tests/Scripts/make-app-tests.sh` covers default preparation, explicit source selection, and download, verification, argument, and platform failures without network or compiler access.
- The side notch panel is anchored by the strip's top-right corner and uses whole-point frames, so switching providers never moves the strip. `docs/SIDE-NOTCH.md` describes the states, geometry invariants, and required evidence. ADR 0004 records the decision.
- Window-shape displays report the raw pace (`QuotaPace.pace(now:)`): a quota bar, side-notch banner/row, or menu-bar chip keeps a deficit's projected run-out even when the burn that caused it has gone quiet. Present-tense claims are gated on burn recency (`BurnRecency` in `Sources/MeterUsage/Models/UsageModels.swift`): the failover nudge, pace alerts, and the machine report consume `QuotaPace.effective(lastBurn:now:)`, which demotes a burn-quiet deficit to on-pace, and require the provider to have burned within a 30-minute quiet period. A headline window at 80%+ without a current burn renders as "near its limit", not "burning fast". Providers without a local session store have no burn evidence: they keep the 80%/95% threshold alerts but never raise pace alerts.
- Burn attribution renders only measured burn (`BurnAttributionCalculator.calculate` in `Sources/MeterUsage/Services/BurnAttributionCalculator.swift`): sessions without a token ledger (for example Codex realtime sessions whose rollout records no `token_count` event) are excluded, and a scope with no token-bearing sessions yields no breakdown, so the burn card hides instead of showing all-zero rows.
- Successful manual Codex resets start observation-based pacing for the redeemed account slot. `AppCoordinator.consumeCodexReset` invalidates the old estimate only after the provider accepts the reset. The first fresh reading establishes each window's baseline; `QuotaWindow.pace` then uses observed usage growth divided by the time between readings. One reading or unchanged usage yields no pace or ETA. Reads started before the reset cannot seed the new baseline. `QuotaArchive` persists this state and quota metadata across relaunches, while old archives still decode. Cycle or duration changes and usage drops replace the window's baseline. Accepted resets also remove the redeemed credit from the archived snapshot and decrement its known count, so an offline refresh or relaunch cannot offer that credit again. Other accounts and providers keep their existing pacing. ADR 0008 records this decision; `ResetPacingTests` covers the reset path.
- Cost figures are local estimates from token counts against the single rate table in `Sources/MeterUsage/Services/Pricing.swift` (`Pricing.snapshotYearMonth` = `2026-09`). That table carries Claude list rates for the current generation (Opus 5.5, Sonnet 5.5, Haiku 4.5, Fable) and OpenAI/Codex Standard list rates for the GPT-6 family (GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, GPT-6 Astra) and GPT-5.6 Sol/Terra/Luna plus `gpt-5.3-codex`. `CodexLocalSource` reads the session's model from the rollout's `turn_context` event and prices its tokens; reasoning is billed at the output rate, cached input uses the model's published cached rate (GPT-6.1 Sol's 5% tier), and Codex charges no cache writes, so those rows price cache writes at zero. A session whose model cannot be read prices at the Codex default tier and is flagged as an unrecognised-model guess rather than zero. Claude rows use one rate per family, so an older generation is estimated at the current generation's price.
- GitHub Actions runs `swift build` and `swift test` on macOS 15, plus Electron typecheck, synthetic tests and production bundling on Linux, for pushes to `main` and pull requests. This repository fact does not prove that a workflow run has passed.
- The app preserves unreadable durable history and suspends history writes until relaunch after the file is repaired. Sanitized history load and save failures are visible in Copy diagnostics.
- Providers tray icon in Settings (the small button beside the "Notch" caption) uses the `menubar.rectangle` symbol for both switch states; state is carried by tint. `menubar.rectangle.fill` is absent from the system symbol catalog (returns nil, renders as nothing), so a filled variant must be probed with `NSImage(systemSymbolName:)` before use.
- `status.openai.com` runs on incident.io, which serves a Statuspage-compatible `components.json` but uses `full_outage` where Atlassian pages use `major_outage`. `StatusPageSource.severity(for:)` maps both to `.majorOutage`; an unmapped status degrades to `.unknown`, never to a false all-clear. Verified against the live feed on 2026-09-25 during an active Codex outage.
- Provider mark tint is identity unless the service check diverges from healthy (`MenuBarLabel.statusTint(_:for:)`): operational keeps `providerColor`, degraded/outage repaint amber/red, unreadable goes neutral grey. Quota headroom tint stays on rings and percents only; the side notch, menu bar, and status rows share this rule per ADR 0002's mark semantics.
- The app accent is user-selectable (`AccentTheme`, Settings → Appearance): Blue (default), Violet, Teal, Amber, Rose, and Graphite, persisted under `accentTheme`. `MU.accent` resolves the choice, so the popover heatmap, sparkline, accent text, and interactive control tint, the primary provider's (Codex's) mark, and the side notch chrome (body, card, ring disc/track) all recolour together. Headroom green/amber/red and every other provider identity stay fixed. Dark neutral surfaces are dark greys (popover canvas/surface/well and the notch body/card), not black.
- Side notch chrome is derived per theme in `SideNotchPanelView` by an HSV mix pinned to the popover surface's Rec. 709 relative luminance (`blendTinted`), so every accent renders at the same perceived brightness as the window beside it. The notch bands and hues delegate to the shared `headroomColor`/`MU` scale (80/95 thresholds), and the panel window forces `darkAqua` so those tokens resolve their dark variants on the strip.
- ADR 0006 replaces fixed alternate cases with a managed account list for Codex and Claude. Generated app IDs, provider, user label, directory and enabled state persist as JSON in UserDefaults Data. Primary keys retain their old form; additional history/archive keys use provider plus generated ID, and schema-1 reports add `account` labels. Rename preserves identity; remove stops metering without deleting provider files. No provider account identity is read for labels.
- ADR 0010 selects macOS TypeScript/Electron/React with pnpm, Vite+, Tailwind, Vitest and electron-builder. Main owns provider files/keys, native actions and persistence; a separate sandbox-compatible preload exposes sender-validated IPC to React. The candidate keeps JSON/history/archive and known preference formats. Swift remains the oracle and rollback path. No server or remote control layer is added.
- Windows implementation, installers, CI, testing and releases are paused until a test machine is available. The former RN/Tauri Windows-first plan is superseded; shared portable source does not establish Windows support.
- Candidate checks use synthetic fixtures. Demo/candidate selection isolates preferences, history, caches and Electron state before composition. Live provider/key discovery, updater installation and login-item changes are disabled in demo. `pnpm package:mac` creates a separate candidate with publication disabled, using existing macOS tools.
- Candidate account visibility rechecks directory presence. Sharing freezes the displayed account key. Pacing-off hides forecasts; notch details reuse window-scoped burn metrics and have a bounded scroller. These contracts have synthetic/static-markup proof; native UI acceptance remains open.
- The browser-demo notch uses viewport height when no native work-area height is supplied. The card and strip scroll independently; the 36-pixel charcoal strip has 22-pixel rings containing provider marks, percentages below. Settings is available in each expanded card footer, with no strip button or reserved slot. The 220-pixel detail card plus strip use 256 pixels total. Synthetic browser checks cover scrolling, two card heights and both CSS card sides, but do not verify native window placement or display changes.
- Candidate state publication returns before touching a destroyed tray. A synthetic Electron entrypoint regression emits display and theme events after tray destruction; native shutdown/display behavior remains an acceptance check.
- Candidate window cleanup uses the document ID captured while the window is alive. Closing a destroyed window cannot read its web contents or remove a replacement window for the same surface. The synthetic lifecycle regression exercises this path; native shutdown remains an acceptance check.
- Candidate Quit removes the display subscription before stopping collection and waiting for authentication cleanup. A late collection publication cannot recreate the notch or restart update checks. Lifecycle regressions cover flyout and tray Quit, repeated Quit during cleanup, and notch enabled or disabled. These tests do not establish native process termination.
- Candidate macOS GUI startup validates Electron's three direct singleton links as one coherent metadata set before requesting the native lock. Other profile symlinks remain rejected, and JSON entrypoints retain strict validation. A second instance exits before collection starts and asks the primary instance to reveal its panel. Startup failures emit a fixed error; activation during Quit cannot reopen windows. [ADR 0013](adr/0013-candidate-single-instance-startup.md) records the bounded exception and native acceptance requirements.
- Candidate Appearance includes a saved Small, Medium or Large panel size, defaulting to Medium. Main-panel widths are 336, 420 and 483 points before display clamping. Main-panel and Settings content use the same scale. Side-notch detail content uses explicit integer pixel sizes without CSS zoom. The notch card is 220 pixels wide beside the fixed 36-pixel strip; its height follows the size-specific content within the work area. Settings measures the scaled content height and fits its active category and expanded controls within the display work area, accounting for native title-bar height. Width and top position remain when on screen. Tray and 250-pixel shared-card capture remain unchanged. Ctrl/Cmd plus or minus selects the next size; Ctrl/Cmd 0 restores Medium. These shortcuts use the same saved preference and main-panel resizing as Settings. Window loads normalize retained Chromium zoom to avoid applying a second scale. The main panel measures natural content height, shrinks when content gets shorter, and scrolls within available display space without visible indicators. Synthetic tests cover persistence, invalid values, write failure, rapid keys and display clamping; actual native sizing acceptance is separate.
- Candidate Settings gives Appearance, General, Providers, Side notch, Usage details and Diagnostics direct category access beside Connections. Related options use grouped rows. Panel size uses a compact row of visible Small, Medium and Large choices; accent color uses six labelled radio swatches. Aligned provider controls distinguish collection from menu-bar and side-notch display; stopping primary collection preserves the saved display preference. The display control stays available when an additional account has an active source slot. Advanced local accounts remain available. Scrollbar indicators are hidden throughout candidate windows, with scrolling and keyboard access retained. These renderer contracts do not establish native UI parity.
- Codex login, allowance and own-profile logout select `app-server --listen stdio://`. Connection subprocesses keep interpreter search paths while excluding inherited credential variables. Connection tests restrict app-helper discovery to generated fixture roots. These are source contracts, not proof of a live helper or cloud account.
- The desktop-connection candidate has matching passing source proof for 165 synthetic TypeScript tests, TypeScript checking and production bundling on Linux. Its connection cleanup, account verification, cache/JSON readers, reset capability, alerts and locality labels have regression coverage. Disconnect blocks Claude's post-request credential reread; account-bound collection timeout removes unverified allowance; explicit Codex sign-in retry recovers retained cleanup before a new login. The unchanged migration baseline's headless demo comparison preserves stable schema-1 fields against the Swift demo oracle; that older native receipt does not verify the new connections. Source checks do not establish native parity or a published Electron release.
- The first macOS fixture attempt passed 90 cases and failed 29 due to temporary-path aliases and a case-sensitive filename assertion. Canonical roots and exact directory-entry checks now pass all 128 current fixtures on macOS, along with TypeScript checking and production bundling. Candidate symlink rejection is unchanged.
- A temporary candidate-local pnpm PATH alias resolved the dependency collector's broken launcher without changing host configuration. At source `193c2af42bd2a8641accbb3f7b5b333ba6cd9ac3`, the Apple silicon ZIP is 116,696,318 bytes with SHA-256 `4ea7a6f297402958a52173696880f8183a05454c2e08966d71ebeaa69f52e634`. Its extracted bundle passes `codesign --verify --deep --strict` with an ad-hoc signature and hardened runtime. It is not notarized, installed or published.
- The extracted native Electron executable exits successfully with schema-1 demo JSON and no stderr. Its eight provider/account entries match the Swift oracle's stable fields at numerical tolerance `1e-12`; comparison excludes `generated_at`, `resets_at`, `burn_rate`, `eta_seconds` and `eta_text`. The extracted bundle uses 290,148 KiB on disk. GUI behavior, idle RSS and packaged-app performance remain unverified.
- Synthetic source-scanner timing on the same Apple silicon Mac uses 32 files per provider, including 8,192 Claude messages. Empty/memory/restored-disk Claude cache samples are 30.93/0.56/0.76 ms on native Node and 392.63/1.25/1.48 ms in an optimized Swift harness. Codex first/second scan samples are 4.84/3.53 ms on Node and 3.81/3.39 ms on Swift. Session/token counts and cache-transition results pass. These are separate single samples of matching generated fixture contents, taken at different times outside the packaged apps. Empty cache means application cache, not flushed OS cache; compilation and fixture generation are excluded. Packaged-app performance and idle RSS remain unverified.
- Durable daily-history reads and writes project the known record fields and five token counters before coordinator merge or renderer publication. Unknown JSON fields are discarded; larger historic totals and account keys remain intact.
- Claude skips unreadable or disappearing sessions while keeping readable siblings. Codex retains the Swift metadata, modification-time and token-ledger fallbacks per session; a dated session without a readable ledger contributes no measured burn. Both readers propagate cancellation.
- Invalid Claude cache bucket costs or unsupported bucket/session dates discard only that cache entry and trigger a transcript rescan. Shared provider parsing rejects dates outside JavaScript's representable range before history or report serialization. Malformed optional dates are omitted; required dates retain provider-specific failure handling.
- The side-notch reset preference controls the detail card and context menu; flyout reset redemption remains available for a reported-available, unexpired credit. Main still requires explicit confirmation and rechecks the credit.
- Rolling usage bars show each window's share of `last 30d`, using estimated cost when reference cost is positive, otherwise measured tokens. Missing or zero reference produces zero share. The caption states the reference and pricing snapshot. These renderer contracts have fixture proof; native acceptance remains open.
- Archive reads validate optional plan, group, credit and reset metadata, retain Swift date/null compatibility and project only known fields. Reset preparation, confirmation and UI actions share the same reported-available and unexpired rule; absent status is unavailable.
- Primary Claude quota discovery prioritizes the app-support `claude-usage.json`, then `.claude/claudewatch-usage.json`, then `.claude/meterusage-usage.json`. Additional accounts read only their configured directory. Without `updated_at`, capture time comes from the selected file's modification time. Optional OpenRouter credits have a five-second deadline starting with the required quota request. Malformed optional Codex additional limits never discard valid base windows.
- Usage cards show current-day session/message counts and capture age without inventing token totals. Tray tooltips include non-operational status, reset countdown, stale capture age and last refresh. Claude, Antigravity, OpenCode Go, OpenRouter and Grok keep the Swift light/dark identity pairs, with semantic status overrides. These display contracts have synthetic/static-markup proof; native acceptance remains open.
- Flyout service health uses reported statuses independently of usage visibility. Failed refreshes retain the last successful status as last known, with its age and refresh failure shown in the status panel, notch card and tray tooltip. Copied diagnostics marks the reading stale with its successful-check age and a fixed service-status error; successful retry clears the marker. Public-feed failures use service-status wording while keeping their failure code for retry behavior. Status buttons ask main to open only the existing fixed public provider pages. The compact notch rail shows only provider marks and percentages; pacing and reset timing remain in details. Native rendering and page opening remain unverified.
- Replacing an account source invalidates its live quota, activity, usage, plan and pending reset confirmation. Late reads and reset completion from that source cannot update its replacement. Dated slot archives and durable history remain available; reset requires a current source reading.
- Shared-card sizing uses the full measured height, separate from visible-window bounds. The candidate rejects capture heights above 8,192 pixels, or 4,096 CSS pixels at 2x, with `Card too tall to share`. Native image completeness remains unverified.


- The `--codex-test-profile` candidate mode runs the existing Codex connection UI with isolated preferences, app data and Electron state. It excludes synthetic readings, other provider sources, local activity and Claude status. It reads the public OpenAI status feed without credentials; updates, login-item changes and notifications are blocked. [ADR 0012](adr/0012-codex-live-test-profile.md) amends the demo-only candidate restriction; [ADR 0015](adr/0015-codex-test-public-status.md) permits this public status request. Native and provider acceptance remain separate.
- The separate `--claude-test-profile` candidate mode starts without consent and runs only the existing Claude Desktop allowance flow. It uses isolated JSON preferences and Electron state, blocks Codex access and cleanup, and retains the candidate system-effect guards. A Claude connection call without a consent callback denies access. Synthetic fixtures cover consent, relaunch, disconnect and profile isolation; native Keychain, Desktop format and live-provider acceptance remain open. See [ADR 0016](adr/0016-claude-live-test-profile.md).

- Electron notch secondary labels use a scoped `#b0b0b8`; semantic provider and quota colors retain their existing rules. Telemetry adds a border and size-specific top padding. Enabled detail buttons use 120 ms background feedback for fine-pointer hover with reduced motion off. Press and keyboard focus stay immediate; reduced motion disables transitions. Card/window/ring geometry and the 450 ms close delay retain their source behavior. Rendered feedback, scrolling and native anchors still need target proof. See [SIDE-NOTCH.md](SIDE-NOTCH.md).

- Electron Settings persists provider group order through validated IPC. Drag handles, arrow keys and move buttons use the same saved order for usage cards, service health, menu bar and side notch. Stored lists retain known providers once and append missing providers in default order. Additional accounts remain grouped, with independent Collect and Show settings. Failed saves and canceled drags retain the saved order. Synthetic proof does not establish rendered or native drag, focus, VoiceOver or notch-anchor behavior. See [ADR 0021](adr/0021-provider-group-order.md).

- The macOS preferences reader accepts complete legacy hex data and reads
  complete NSData through Foundation when `defaults` prints an abbreviated
  description. Provider order and managed accounts retain their saved format.
  Relaunches and app updates reuse the saved order; newly added providers append
  after the retained entries.

- Every provider card with a quota reading shows a "Quota activity" heatmap
  (`src/main/quota-activity.ts`) unless it already shows Codex account token
  history. Each slot records the rise in its own tracking window (weekly
  all-models when present, else the longest window) per local day, so usage
  from desktop apps and other devices appears. The first reading spreads
  the current window's usage evenly over its elapsed days, marked estimated;
  earlier windows are never backfilled. Connection changes retire the previous
  series under an opaque generated key, so replacement accounts never inherit
  its days or baseline. Retired observations remain on disk outside active
  heatmaps; normal relaunch and Muse collection Stop/Start retain the active
  series.
  Quota activity stays in percentage points: providers report no account
  token totals for desktop or web use, so tokens are never inferred. When
  Claude Code (or Codex) ran on this Mac that day, the tooltip adds the
  measured local tokens, labelled "on this Mac". A rise seen after the
  Mac was offline lands on the next reading's day. A reset-time change over
  one hour, or a drop, counts the new window from zero. Demo mode is excluded.

- Connected Codex account history uses `account/usage/read` without `threadId`
  through the existing managed ChatGPT helper and effective keyring guard. It
  publishes only valid unique calendar labels, safe nonnegative token counts
  and capture time in separate in-memory state. Main, notch and shared cards
  show "Account token activity" under existing heatmap preferences. Null or
  absent history and unreported days remain unavailable; reported zero stays
  zero. Profile replacement, disconnect and failed reads clear the reading;
  late results cannot update a replacement source. Account history is excluded
  from local rollups, durable history and schema-1 quota JSON. Source and
  synthetic proof do not establish live availability or universal cloud,
  device or product coverage. See [ADR 0022](adr/0022-codex-account-token-history.md).

- The retained Swift reporting candidate adds Settings Report issue, using an HTTPS relay to create a private Linear issue without a user login or bundled Linear credential. Diagnostics use allowlisted state and numbers; success requires a matching server receipt. AppCoordinator retains pending reports and receipts across Settings navigation until the app quits. On 2026-10-08, Workers Free and native-client delivery/retry were verified, and the source bundle endpoint was configured. Native Settings interaction and released-app availability remain unverified. See [Swift reporting](swift/REPORTING.md) and the retained Swift reporting ADRs 0011 and 0012.

- The retained Swift agent feedback CLI accepts short structured bug drafts, then requires a native preview and user consent for each send. It reuses the private reporting client and relay, without polling providers or collecting transcripts. See [Swift reporting](swift/REPORTING.md) and [ADR 0013](adr/0013-agent-feedback-native-consent.md).

## Verification gaps

- Claude Desktop GUI connections and subsequent allowance polling share one HTTP
  transport. Only the fixed bootstrap and UUID-bound usage routes use a unique
  nonpersistent Electron session with caching disabled and ambient credentials
  omitted. Demo, JSON and Codex test paths do not use this native session. Source
  and synthetic checks do not establish native cookie handling or provider acceptance.

- The Electron candidate still needs native GUI launch/relaunch, preferences/account/offline journeys, tray/focus/accessibility, notification/login/share/updater paths, drag/display persistence and two different-height notch captures. Verified packaging and headless JSON cannot close migration or cutover.
- Repository files do not prove current provider authentication, quota freshness, network responses, local machine state, app installation, signed-bundle state, GitHub Release state, or runtime UI behavior.
- Treat cost figures as estimates. `README.md` identifies provider dashboards as the billing source of record.

## Public disclosure boundary

- This KB contains only public repository facts. Do not add private paths, account identifiers, tokens, prompts, source transcripts, internal agent instructions, private repository references, or personal data.

## Repository references

- [`README.md`](../README.md): product behavior, setup, provider boundaries, and public claims.
- [`docs/PRIVACY.md`](PRIVACY.md): data-handling boundaries and enforcement claims.
- [`docs/DEMO.md`](DEMO.md): synthetic demo mode.
- [`docs/SIDE-NOTCH.md`](SIDE-NOTCH.md): side notch states, anchor and geometry invariants, interaction, and verification.
- [`docs/adr/0006-managed-account-list.md`](adr/0006-managed-account-list.md): current managed-account decision.
- [`docs/adr/0010-macos-typescript-electron.md`](adr/0010-macos-typescript-electron.md): macOS migration and Windows hold.
- [`docs/mockups/README.md`](mockups/README.md): Wave 1–3 concept mockups; provider marks stay.
- [`docs/plans/feature-and-windows-pipeline.md`](plans/feature-and-windows-pipeline.md): superseded platform plan, current macOS direction and Windows hold.
- [`Package.swift`](../Package.swift): package targets and platform requirement.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contribution and validation commands.
- [`CHANGELOG.md`](../CHANGELOG.md): repository release-note history.
- [`AGENTS.md`](../AGENTS.md): public-safe repository operating and knowledge-maintenance rules.
- [`docs/adr/README.md`](adr/README.md): decision index.

## CI workflow maintenance

- [ci.yml](../.github/workflows/ci.yml) uses full-SHA v7 pins for `actions/checkout`. Application language versions and explicit cache settings are preserved.
- Obsolete runs for the same pull request or branch are cancelled. Existing timeout caps are preserved.

Reviewed Swift base: `4b913db3a3a8eb2602296489872af2ecaa5d0530`. Source checks do not prove runtime, deployment or device behavior.

- Electron Diagnostics restores explicit **Send report** through the existing private support relay. Main generates the same allowlisted status summary used by Copy diagnostics with the running app version; renderer IPC accepts intent only. In-flight clicks are deduplicated, uncertain retries reuse the report UUID/snapshot, and a matching HTTP201 receipt supplies the support reference. No raw logs, account labels/IDs, paths, credentials or transcripts are uploaded. See [REPORTING.md](REPORTING.md). Transport fixtures do not prove live Linear delivery.

- Grok is labeled **Beta** in Electron usage cards, setup and provider settings. Official-source desktop research found X Subscription per-seat shared Grok/Cursor usage, unified local Antigravity authentication and API-key-based OpenCode Go setup. Those research findings alone do not establish connections. The source-only Bot Desktop Beta implementation is documented in [ADR 0028](adr/0028-grok-bot-desktop-reader.md), with saved Cursor compatibility in ADR 0027; universal shared-pool coverage remains unverified. See [desktop login research](DESKTOP-LOGIN-RESEARCH.md).

- Diagnostic report attempts have a 10-minute main-process cooldown persisted as a private native preference before HTTP. Relaunch and failed sends retain the limit. Storage failure prevents transmission; Copy diagnostics remains available. Only the timestamp persists, with no report content, account identifier or receipt. See [REPORTING.md](REPORTING.md).

- OpenCode Go has an explicit local setup action. Local Go session history needs
  no key; allowance uses the existing Go key. CLI fallback includes executable
  `~/.bun/bin/opencode`. Coverage remains Go-only.
- Activity heatmaps use one 26-column, seven-row layout. Thirty-day telemetry
  leaves older dates unavailable. Local-day and OpenRouter UTC scope are retained.

Completed-onboarding launches preload the usage window hidden before connection
recovery and provider collection. The first tray click reuses that renderer;
fresh provider data still depends on its source. Incomplete onboarding continues
to open Settings. No window is shown or focused by preload.

## API billing and Grok compatibility follow-up

- OpenAI API and Anthropic API are independent billing snapshots, not quota
  provider slots. Settings → API connections accepts a one-time masked Admin
  key and fetches billing without Terminal. The field clears on submit or
  leaving the page; pasted keys are never saved. **Use saved key** reads only the
  selected provider's legacy `com.meterusage.api-keys` Keychain entry without
  changing it or returning the key to the renderer. It runs only on request. A bundled environment-only helper
  remains available. Both paths use fixed cost endpoints and projected
  owner-only USD files. Cards retain the
  reported UTC period, exact capture time and explicit stale state. Empty
  reports do not become zero usage. Real organization billing remains unverified.
  See [API billing](API_USAGE_BETA.md) and [ADR 0029](adr/0029-api-billing-snapshots.md).
- The Grok Bot encrypted reader accepts canonical v10 legacy values with the
  same full-subject active-account binding as scoped envelopes. Its fixed
  Keychain pair is Grok Bot Safe Storage / Grok Bot Key. Native metadata confirms
  these shapes; access and live allowance remain separate gates. See
  [ADR 0030](adr/0030-grok-bot-encrypted-compatibility.md).

- Grok Bot Desktop quota burn uses live same-account observations spanning at
  least one minute and no more than five minutes. It reports percentage points
  per hour and can estimate run-out without assuming a quota-cycle duration.
  Missing/stale reads, reconnects, source changes and resets clear measurement.
  Archives retain quota but discard these observation baselines. No token or
  dollar rate is derived. See [ADR 0031](adr/0031-grok-quota-burn.md).
- API setup has its own Settings category, separate from account connections
  and onboarding. Fetch billing updates the snapshot automatically; ordinary
  Refresh only rereads it. The advanced helper retains key-free macOS zsh
  commands and a hidden prompt. See [ADR 0032](adr/0032-one-time-api-setup.md).
  Real organization billing remains unverified.

## Retained Swift reporting source

Main's Swift reporting client, native-consent bug draft CLI and their tests
remain in the retained Swift tree. Their diagnostic payload and user flow
differ from Electron. See [the Swift reporting contract](swift/REPORTING.md)
and its activation evidence; this does not add them to Swift 0.2.41.
