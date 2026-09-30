# Project knowledge

Last verified: 2026-09-29

## Repository state

- Default branch: `main`.
- Reviewed source revision: `1c4f169`.
- This index is public-safe repository documentation. It does not prove current local provider state, runtime behavior, release availability, or external service state.

## Product and source facts

- meterusage is a macOS menu-bar app that displays AI coding-assistant quota and usage signals. `README.md` describes provider clusters, quota cards, heatmaps, sparklines, alerts, diagnostics, and a scriptable JSON CLI.
- The app is Swift Package Manager based, targets macOS 13 or later, and includes an executable target and a test target. `Package.swift` is the source for this package structure.
- Provider data sources are implemented under `Sources/MeterUsage/Services/`. `docs/PRIVACY.md` describes the boundary for local files, provider CLIs, documented network endpoints, and data reduction before display.
- Antigravity quota and usage share a bounded Docker/Podman runtime resolver. It prefers a healthy runtime and can start only an already-existing `podman-machine-default` after an inspect check; it never creates a machine or pulls an image. Concurrent recovery calls are serialized; failed starts have a 60-second cooldown. Internet or authentication failures are not repaired by restarting a healthy runtime.
- Demo mode uses synthetic data. `README.md` and `docs/DEMO.md` describe it as the path for screenshots and local UI inspection without provider accounts.
- `CHANGELOG.md` records version 0.2.40 as the latest repository release entry, dated 2026-09-29: accent colour themes, Codex cost estimates read from the rollout's `turn_context` model, and a 2026-09 pricing-table refresh (OpenAI/Codex rates plus current Claude prices). This follows 0.2.39's pace-display fix and 0.2.38's multi-account meters for Codex and Claude (ADR 0005–0006). This is repository release-note state, not proof of a published release.
- `CONTRIBUTING.md` requires focused changes, synthetic fixtures, and `swift build`, `swift test`, and `Scripts/make-app.sh` before a code pull request.
- `CONTRIBUTING.md#candidate-verification` requires source identity checks before testing a copied candidate and a nonzero executed test count. Its verification record separates source, bundle, launch, installation, native UI, and published-release evidence; these are contributor checks, not automatic release enforcement.
- The side notch panel is anchored by the strip's top-right corner and uses whole-point frames, so switching providers never moves the strip. `docs/SIDE-NOTCH.md` describes the states, geometry invariants, and required evidence. ADR 0004 records the decision.
- Window-shape displays report the raw pace (`QuotaPace.pace(now:)`): a quota bar, side-notch banner/row, or menu-bar chip keeps a deficit's projected run-out even when the burn that caused it has gone quiet. Present-tense claims are gated on burn recency (`BurnRecency` in `Sources/MeterUsage/Models/UsageModels.swift`): the failover nudge, pace alerts, and the machine report consume `QuotaPace.effective(lastBurn:now:)`, which demotes a burn-quiet deficit to on-pace, and require the provider to have burned within a 30-minute quiet period. A headline window at 80%+ without a current burn renders as "near its limit", not "burning fast". Providers without a local session store have no burn evidence: they keep the 80%/95% threshold alerts but never raise pace alerts.
- Burn attribution renders only measured burn (`BurnAttributionCalculator.calculate` in `Sources/MeterUsage/Services/BurnAttributionCalculator.swift`): sessions without a token ledger (for example Codex realtime sessions whose rollout records no `token_count` event) are excluded, and a scope with no token-bearing sessions yields no breakdown, so the burn card hides instead of showing all-zero rows.
- Cost figures are local estimates from token counts against the single rate table in `Sources/MeterUsage/Services/Pricing.swift` (`Pricing.snapshotYearMonth` = `2026-09`). That table carries Claude list rates for the current generation (Opus 5.5, Sonnet 5.5, Haiku 4.5, Fable) and OpenAI/Codex Standard list rates for the GPT-6 family (GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, GPT-6 Astra) and GPT-5.6 Sol/Terra/Luna plus `gpt-5.3-codex`. `CodexLocalSource` reads the session's model from the rollout's `turn_context` event and prices its tokens; reasoning is billed at the output rate, cached input uses the model's published cached rate (GPT-6.1 Sol's 5% tier), and Codex charges no cache writes, so those rows price cache writes at zero. A session whose model cannot be read prices at the Codex default tier and is flagged as an unrecognised-model guess rather than zero. Claude rows use one rate per family, so an older generation is estimated at the current generation's price.
- GitHub Actions runs `swift build` and `swift test` on macOS 15 for pushes to `main` and pull requests. This repository fact does not prove that a workflow run has passed.
- The app preserves unreadable durable history and suspends history writes until relaunch after the file is repaired. Sanitized history load and save failures are visible in Copy diagnostics.
- Providers tray icon in Settings (the small button beside the "Notch" caption) uses the `menubar.rectangle` symbol for both switch states; state is carried by tint. `menubar.rectangle.fill` is absent from the system symbol catalog (returns nil, renders as nothing), so a filled variant must be probed with `NSImage(systemSymbolName:)` before use.
- `status.openai.com` runs on incident.io, which serves a Statuspage-compatible `components.json` but uses `full_outage` where Atlassian pages use `major_outage`. `StatusPageSource.severity(for:)` maps both to `.majorOutage`; an unmapped status degrades to `.unknown`, never to a false all-clear. Verified against the live feed on 2026-09-25 during an active Codex outage.
- Provider mark tint is identity unless the service check diverges from healthy (`MenuBarLabel.statusTint(_:for:)`): operational keeps `providerColor`, degraded/outage repaint amber/red, unreadable goes neutral grey. Quota headroom tint stays on rings and percents only; the side notch, menu bar, and status rows share this rule per ADR 0002's mark semantics.
- The app accent is user-selectable (`AccentTheme`, Settings → Appearance): Blue (default), Violet, Teal, Amber, Rose, and Graphite, persisted under `accentTheme`. `MU.accent` resolves the choice, so the popover heatmap, sparkline, accent text, and interactive control tint, the primary provider's (Codex's) mark, and the side notch chrome (body, card, ring disc/track) all recolour together. Headroom green/amber/red and every other provider identity stay fixed. Dark neutral surfaces are dark greys (popover canvas/surface/well and the notch body/card), not black.
- Side notch chrome is derived per theme in `SideNotchPanelView` by an HSV mix pinned to the popover surface's Rec. 709 relative luminance (`blendTinted`), so every accent renders at the same perceived brightness as the window beside it. The notch bands and hues delegate to the shared `headroomColor`/`MU` scale (80/95 thresholds), and the panel window forces `darkAqua` so those tokens resolve their dark variants on the strip.
- Second accounts (multi-account support, ADR 0005): `.codexAlt` / `.claudeAlt` provider slots are keyed by an alternate config directory resolved in `AccountSlots` (`Sources/MeterUsage/Services/DataSource.swift`) from `METERUSAGE_CODEX_ALT_HOME` / `METERUSAGE_CLAUDE_ALT_CONFIG` or the `meterusage.codexAltHome` / `meterusage.claudeAltConfig` defaults keys, which are editable in Settings → Providers. A slot exists only when its directory exists; slots never merge with the primary account, keep per-slot durable history and archive keys, and are named by position only (no account identity is read). The JSON report lists them under `codexAlt` / `claudeAlt`.

## Verification gaps

- Repository files do not prove current provider authentication, quota freshness, network responses, local machine state, app installation, signed-bundle state, GitHub Release state, or runtime UI behavior.
- Treat cost figures as estimates. `README.md` identifies provider dashboards as the billing source of record.

## Public disclosure boundary

- This KB contains only public repository facts. Do not add private paths, account identifiers, tokens, prompts, source transcripts, internal agent instructions, private repository references, or personal data.

## Repository references

- [`README.md`](../README.md): product behavior, setup, provider boundaries, and public claims.
- [`docs/PRIVACY.md`](PRIVACY.md): data-handling boundaries and enforcement claims.
- [`docs/DEMO.md`](DEMO.md): synthetic demo mode.
- [`docs/SIDE-NOTCH.md`](SIDE-NOTCH.md): side notch states, anchor and geometry invariants, interaction, and verification.
- [`docs/adr/0005-multi-account-slots.md`](adr/0005-multi-account-slots.md): second-account slot decision.
- [`docs/mockups/README.md`](mockups/README.md): Wave 1–3 concept mockups; provider marks stay.
- [`docs/plans/feature-and-windows-pipeline.md`](plans/feature-and-windows-pipeline.md): macOS feature waves + Windows track.
- [`Package.swift`](../Package.swift): package targets and platform requirement.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contribution and validation commands.
- [`CHANGELOG.md`](../CHANGELOG.md): repository release-note history.
- [`AGENTS.md`](../AGENTS.md): public-safe repository operating and knowledge-maintenance rules.
- [`docs/adr/README.md`](adr/README.md): decision index.
