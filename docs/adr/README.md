# Architecture decision records

This directory records decisions that affect repository work. Read an ADR before changing a documented decision. Add a new numbered ADR for a new decision; do not rewrite an accepted decision to fit a later change.

## Index

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-repository-owned-knowledge.md) | Keep public-safe project knowledge and decisions beside the project and exclude private operational content. | Accepted |
| [0002](0002-provider-marks-stay.md) | Keep existing provider logos/marks (`ProviderMark` + `Resources/*-logo.png`); do not redesign them in feature or cross-platform work. | Accepted |
| [0003](0003-burn-attribution-scope.md) | Scope burn attribution to the last 7 days across all token-bearing providers, with per-provider aggregates that never count as long chats. | Accepted |
| [0004](0004-side-notch-anchor-invariant.md) | Keep the side notch anchored by the strip's top-right corner, use whole-point frames, anchor content to the window top, and require captured frame evidence for layout or motion changes. | Accepted |
| [0005](0005-multi-account-slots.md) | Model a second Claude/Codex account as its own provider slot keyed by an alternate config directory; never merge two accounts' windows and never read or display account identity. | Accepted; slot mechanism amended by [0006](0006-managed-account-list.md) |
| [0006](0006-managed-account-list.md) | Additional accounts are a managed, unbounded Settings list; `ProviderSlot` (provider + generated id, label display-only) keys every metered surface, with primary-slot persistence formats unchanged. | Accepted |
| [0008](0008-reset-aware-quota-pacing.md) | ADR 0008: Collect fresh quota observations after a manual reset | Accepted |
| [0009](0009-prebuilt-bundle-default.md) | Download and verify the prebuilt app by default; compile only with `--build-from-source`. | Accepted |

| [0010](0010-user-triggered-github-diagnostics.md) | Initial GitHub form proposal, withdrawn before implementation because it required login. | Superseded by 0011 |
| [0011](0011-login-free-linear-reports.md) | Send user-requested diagnostics through a free relay to a private Linear project without user login. | Accepted; report lifetime amended by 0012; relay activated 2026-10-08 |
| [0012](0012-report-state-outlives-settings.md) | Retain report identity and delivery state in the app coordinator across Settings navigation. | Accepted; native-client delivery verified; native interaction pending |

| [0013](0013-agent-feedback-native-consent.md) | Require native user consent for bounded agent bug drafts through the existing reporting relay. | Accepted |
