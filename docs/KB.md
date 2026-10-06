# Project knowledge

Last source review: 2026-10-06

## Repository state

- Default branch: `main`.
- Swift baseline revision: `4b913db3a3a8eb2602296489872af2ecaa5d0530`. The Electron candidate is the accompanying migration change; native acceptance remains open.
- This index is public-safe repository documentation. It does not prove current local provider state, runtime behavior, release availability, or external service state.

## Product and source facts

- meterusage is a macOS menu-bar app that displays AI coding-assistant quota and usage signals. `README.md` describes provider clusters, quota cards, heatmaps, sparklines, alerts, diagnostics, and a scriptable JSON CLI.
- The published app is Swift Package Manager based, targets macOS 13 or later, and includes an executable target and a test target. `Package.swift` is the source for this package structure. Its AppKit and SwiftUI imports require macOS for package build and test checks; Swift itself supports other platforms. `AGENTS.md` describes a generic macOS SSH route for Linux development without private host aliases.
- `README.md` links directly to the prebuilt v0.2.41 app ZIP as the default installation path. Installing and running it does not require Swift, Xcode, Command Line Tools, or Git; its Swift runtime ships with macOS. `Scripts/make-app.sh` also downloads that pinned release by default, checks its SHA-256 and code signature, and prepares `dist/MeterUsage.app` without compiling or installing developer tools. It copies and verifies the replacement in staging on the destination filesystem before replacing existing output, so copy or verification failures preserve the previous generated app. It rejects unsupported platforms and never falls back to a source build. Source builds require `--build-from-source` and are documented in `CONTRIBUTING.md`. The v0.2.41 asset targets Apple silicon and macOS 13 or later, is ad-hoc signed, and is not notarized. GitHub's source archives contain source and scripts, not an app bundle. ADR 0009 records the script's default.
- Swift provider data sources are implemented under `Sources/MeterUsage/Services/`; the candidate adapters live under `src/main/providers/` and `src/main/composition.ts`. `docs/PRIVACY.md` describes the boundary for local files, provider CLIs, documented network endpoints, and data reduction before display.
- Antigravity quota and usage share a bounded Docker/Podman runtime resolver. It prefers a healthy runtime and can start only an already-existing `podman-machine-default` after an inspect check; it never creates a machine or pulls an image. Concurrent recovery calls are serialized; failed starts have a 60-second cooldown. Internet or authentication failures are not repaired by restarting a healthy runtime.
- Demo mode uses synthetic data. `README.md` and `docs/DEMO.md` describe it as the path for screenshots and local UI inspection without provider accounts.
- `Resources/Info.plist` and `CHANGELOG.md` record version 0.2.41, build 46, dated 2026-10-05. This release collects fresh quota observations after an accepted manual Codex reset, derives pacing and ETA from later usage growth, and removes the redeemed reset credit from archived quota data. The previous release was 0.2.40, which added accent colour themes, Codex cost estimates, and refreshed model prices. Repository version and release-note entries do not prove that a GitHub Release or its downloadable asset has been published.
- `CONTRIBUTING.md` requires focused changes, synthetic fixtures, and `swift build`, `swift test`, and `Scripts/make-app.sh --build-from-source` before a code pull request. `Tests/Scripts/make-app-tests.sh` covers default preparation, explicit source selection, and download, verification, argument, and platform failures without network or compiler access.
- The side notch panel is anchored by the strip's top-right corner and uses whole-point frames, so switching providers never moves the strip. `docs/SIDE-NOTCH.md` describes the states, geometry invariants, and required evidence. ADR 0004 records the decision.
- Window-shape displays report the raw pace (`QuotaPace.pace(now:)`): a quota bar, side-notch banner/row, or menu-bar chip keeps a deficit's projected run-out even when the burn that caused it has gone quiet. Present-tense claims are gated on burn recency (`BurnRecency` in `Sources/MeterUsage/Models/UsageModels.swift`): the failover nudge, pace alerts, and the machine report consume `QuotaPace.effective(lastBurn:now:)`, which demotes a burn-quiet deficit to on-pace, and require the provider to have burned within a 30-minute quiet period. A headline window at 80%+ without a current burn renders as "near its limit", not "burning fast". Providers without a local session store have no burn evidence: they keep the 80%/95% threshold alerts but never raise pace alerts.
- Burn attribution renders only measured burn (`BurnAttributionCalculator.calculate` in `Sources/MeterUsage/Services/BurnAttributionCalculator.swift`): sessions without a token ledger (for example Codex realtime sessions whose rollout records no `token_count` event) are excluded, and a scope with no token-bearing sessions yields no breakdown, so the burn card hides instead of showing all-zero rows.
- Successful manual Codex resets start observation-based pacing for the redeemed account slot. `AppCoordinator.consumeCodexReset` invalidates the old estimate only after the provider accepts the reset. The first fresh reading establishes each window's baseline; `QuotaWindow.pace` then uses observed usage growth divided by the time between readings. One reading or unchanged usage yields no pace or ETA. Reads started before the reset cannot seed the new baseline. `QuotaArchive` persists this state and quota metadata across relaunches, while old archives still decode. Cycle or duration changes and usage drops replace the window's baseline. Accepted resets also remove the redeemed credit from the archived snapshot and decrement its known count, so an offline refresh or relaunch cannot offer that credit again. Other accounts and providers keep their existing pacing. ADR 0008 records this decision; `ResetPacingTests` covers the reset path.
- Cost figures are local estimates from token counts against the single rate table in `Sources/MeterUsage/Services/Pricing.swift` (`Pricing.snapshotYearMonth` = `2026-09`). That table carries Claude list rates for the current generation (Opus 5.5, Sonnet 5.5, Haiku 4.5, Fable) and OpenAI/Codex Standard list rates for the GPT-6 family (GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, GPT-6 Astra) and GPT-5.6 Sol/Terra/Luna plus `gpt-5.3-codex`. `CodexLocalSource` reads the session's model from the rollout's `turn_context` event and prices its tokens; reasoning is billed at the output rate, cached input uses the model's published cached rate (GPT-6.1 Sol's 5% tier), and Codex charges no cache writes, so those rows price cache writes at zero. A session whose model cannot be read prices at the Codex default tier and is flagged as an unrecognised-model guess rather than zero. Claude rows use one rate per family, so an older generation is estimated at the current generation's price.
- GitHub Actions runs `swift build` and `swift test` on macOS 15 for pushes to `main` and pull requests. This repository fact does not prove that a workflow run has passed.
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
- Current source checks pass 93 TypeScript fixture tests, TypeScript checking and production bundling. The bundled headless demo preserves stable schema-1 fields against the Swift demo oracle. This is source/fixture evidence only, not native parity or a published Electron release.


## Verification gaps

- The Electron candidate still needs native bundle identity/digest/signature, launch/relaunch, preferences round-trip, tray/notification/login/share/updater paths and two different-height notch captures. Source-only draft delivery cannot close migration or cutover.
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
