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
| [0007](0007-openai-api-usage.md) | Keep OpenAI API organization usage separate from Codex limits and local coding totals; use an opt-in Admin key for aggregate usage and costs. | Accepted |
| [0008](0008-anthropic-api-usage.md) | Apply the organization-monitor boundary to Anthropic API spend and Messages API tokens, separate from Claude Code and subscription quota. | Accepted |
| [0009](0009-session-only-api-connections.md) | Add masked API key entry and connection testing, retaining credentials only for the app session. | Accepted; amends credential input in 0007 and 0008 |
| [0010](0010-openai-side-notch.md) | Show OpenAI API reported spend in the side notch without quota semantics; reuse the popover usage details. | Accepted; extends display locations in 0007 |
