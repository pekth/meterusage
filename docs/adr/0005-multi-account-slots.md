# ADR 0005: Second accounts are per-directory provider slots

## Status

Accepted (2026-09-26)

## Context

People who hold two accounts with the same CLI tool (a personal and a work
Codex login, or two Claude Code accounts) still get one meter row per tool.
The windows those rows report come from one authenticated CLI session each,
so a two-account user sees only the first account's budget and a token total
that silently mixes both accounts.

meterusage's privacy contract forbids reading account identity: no
`auth.json`, no credential material, no OAuth account fields. That rules out
 enumerating accounts from provider state. It also rules out merging two
accounts' windows into one row: a merged reading would be a third, fictional
budget — neither account's percent used is the other's.

## Decision

A second account is a **provider slot**: a new `Provider` case (`.codexAlt`,
`.claudeAlt`) that every surface treats as its own meter row — quota card,
ring, tray cluster, alerts, durable history, archive, and the machine-readable
JSON report. Slots are keyed by config directory, the only account boundary
these CLIs expose:

- Codex: `CODEX_HOME` relocation. The slot's source spawns its own
  `codex app-server` subprocess with that home set, so the subprocess
  authenticates as the second account. meterusage still never reads anything
  inside it.
- Claude: `CLAUDE_CONFIG_DIR` relocation. The slot scans that directory's
  `projects/` transcript tree, reads the plan tier from its own `.claude.json`
  (narrow decode, same as the primary slot), and parses a companion quota
  snapshot inside it.

Resolution lives in one place (`AccountSlots`): the path comes from the
environment (`METERUSAGE_CODEX_ALT_HOME`, `METERUSAGE_CLAUDE_ALT_CONFIG`) or
the stored defaults keys (`meterusage.codexAltHome`,
`meterusage.claudeAltConfig`). A slot exists only when its directory exists —
an alternate slot without its directory is not an account, so it never polls,
renders, or alerts.

Slots are labelled by position ("Codex second account", digit "2" beside the
mark). No account identifier is read or displayed; the user's own directory
path is rendered only back to them in Settings, reduced to `~` form.

## Consequences

- Single-account installs are unchanged: the slots default off and absent
  directories gate them out of every surface.
- One alternate account per tool is supported. A third account would need
  either more slot cases or a general `(provider, slot)` identity axis through
  the coordinator maps; the case-based seam keeps that a deliberate future
  decision rather than an accident.
- Per-slot state (durable history, quota archive, alerts) keys on the slot's
  raw value (`codexAlt`, `claudeAlt`). Older app versions reading a newer
  archive degrade to an empty archive rather than an error.
- The JSON report gains `codexAlt` / `claudeAlt` provider entries. The schema
  is unchanged (additive entries); consumers keyed on provider strings must
  treat unknown entries as additional meters, not errors.
- Service health stays per service: an alternate slot resolves its status
  through its base provider, so one outage tints both accounts without
  polling a public feed twice.
