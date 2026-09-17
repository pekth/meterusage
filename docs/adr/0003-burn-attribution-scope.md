# ADR 0003 — 7-day burn attribution scope with provider aggregates

- Status: Accepted
- Date: 2026-09-13

## Decision

Burn attribution covers the last 7 calendar days across every token-bearing provider, matching the "last 7 days" totals it sits under — not the last N sessions of any age, and not Codex/Claude only.

## Rules

- Scope is `since: weekStart` with no fallback: an empty week hides the section instead of presenting stale burn as today's.
- Usage providers without per-session lists contribute synthetic aggregates: one per project when the source can split its week by project (OpenCode Go reads each session's working directory), otherwise one per provider (Antigravity, OpenRouter), carrying week tokens with no model.
- Aggregates join token totals but never count as long chats (`hasRealSession` gate).
- Day totals: activity sources bucket by session start day; usage sources by last activity. Both approximate "work done today" from stores with no per-day ledger.

## Consequences

- Totals and attribution can't contradict each other on provider coverage or window.
- "Last 7 days" means today plus 6 prior days everywhere (`-6d`); rolling `last 7d` usage windows are unchanged.
- Side-notch quota-window attribution keeps its own window scope and recent-burn fallback.

## References

- `Sources/MeterUsage/Services/BurnAttributionCalculator.swift`
- `Sources/MeterUsage/Views/PopoverRoot.swift` (`unifiedActivityStrip`)
