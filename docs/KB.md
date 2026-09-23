# Project knowledge

Last verified: 2026-09-17

## Repository state

- Default branch: `main`.
- Verified source revision: `998d7dd`.
- The clean checkout was verified before this documentation change. This index is public-safe repository documentation. It does not prove current local provider state, runtime behavior, release availability, or external service state.

## Product and source facts

- meterusage is a macOS menu-bar app that displays AI coding-assistant quota and usage signals. `README.md` describes provider clusters, quota cards, heatmaps, sparklines, alerts, diagnostics, and a scriptable JSON CLI.
- The app is Swift Package Manager based, targets macOS 13 or later, and includes an executable target and a test target. `Package.swift` is the source for this package structure.
- Provider data sources are implemented under `Sources/MeterUsage/Services/`. `docs/PRIVACY.md` describes the boundary for local files, provider CLIs, documented network endpoints, and data reduction before display.
- Demo mode uses synthetic data. `README.md` and `docs/DEMO.md` describe it as the path for screenshots and local UI inspection without provider accounts.
- `CHANGELOG.md` records version 0.2.34 as the latest repository release entry, with the burn-attribution automation-skip fix dated 2026-09-20. This is repository release-note state, not proof of a published release.
- `CONTRIBUTING.md` requires focused changes, synthetic fixtures, and `swift build`, `swift test`, and `Scripts/make-app.sh` before a code pull request.
- The side notch panel is anchored by the strip's top-right corner and uses whole-point frames, so switching providers never moves the strip. `docs/SIDE-NOTCH.md` describes the states, geometry invariants, and required evidence. ADR 0004 records the decision.
- Pace claims are gated on burn recency (`BurnRecency` in `Sources/MeterUsage/Models/UsageModels.swift`): a quota window's shape can hold a pace deficit long after the burst that caused it, so "burning fast" requires the provider to have burned within a 30-minute quiet period. Surfaces consume `QuotaPace.effective(lastBurn:now:)`, which demotes a burn-quiet deficit to on-pace. A headline window at 80%+ without a current burn renders as "near its limit", not "burning fast". Providers without a local session store have no burn evidence: they keep the 80%/95% threshold alerts but never raise pace alerts.
- Burn attribution renders only measured burn (`BurnAttributionCalculator.calculate` in `Sources/MeterUsage/Services/BurnAttributionCalculator.swift`): sessions without a token ledger (for example Codex realtime sessions whose rollout records no `token_count` event) are excluded, and a scope with no token-bearing sessions yields no breakdown, so the burn card hides instead of showing all-zero rows.
- GitHub Actions runs `swift build` and `swift test` on macOS 15 for pushes to `main` and pull requests. This repository fact does not prove that a workflow run has passed.
- The app preserves unreadable durable history and suspends history writes until relaunch after the file is repaired. Sanitized history load and save failures are visible in Copy diagnostics.

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
- [`docs/mockups/README.md`](mockups/README.md): Wave 1–3 concept mockups; provider marks stay.
- [`docs/plans/feature-and-windows-pipeline.md`](plans/feature-and-windows-pipeline.md): macOS feature waves + Windows track.
- [`Package.swift`](../Package.swift): package targets and platform requirement.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contribution and validation commands.
- [`CHANGELOG.md`](../CHANGELOG.md): repository release-note history.
- [`AGENTS.md`](../AGENTS.md): public-safe repository operating and knowledge-maintenance rules.
- [`docs/adr/README.md`](adr/README.md): decision index.
