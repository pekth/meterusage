# ADR 0006: Additional accounts are a managed list

## Status

Accepted (2026-09-26). Amends ADR 0005: the fixed one-per-tool alternate
slots it introduced are replaced by a dynamic, user-managed account list.
Its invariants carry over unchanged.

## Context

ADR 0005 shipped second accounts as two fixed `Provider` cases (`.codexAlt`,
`.claudeAlt`) keyed by conventional alternate directories. Two limitations
surfaced immediately:

- A user with three or more accounts of one tool has no third slot; the enum
  is closed.
- The slot could not be configured anywhere except `defaults write` or a
  launch-environment variable, so Settings showed nothing until a directory
  already existed — the feature was undiscoverable exactly where users look
  for it.

## Decision

Additional accounts become a **managed list**:

- `ManagedAccount` (id, provider, label, path, enabled) is persisted as a
  JSON list under the `managedAccounts` defaults key. Settings gains a
  Second accounts card: add per supported tool, edit name and directory,
  enable, remove — unbounded count.
- `ProviderSlot` (provider + generated slot id, label carried for display
  only) becomes the identity that every metered surface keys on: coordinator
  state maps, backoff, durable history, quota archive, alerts, and the JSON
  report. Hashing and persistence exclude the label, so renaming an account
  never orphans its history or alert state. Primary slots keep the empty id
  and serialize exactly like the pre-slot formats, so existing files and
  consumers stay compatible.
- The JSON report gains an additive `account` field carrying the label for
  additional slots; primary slots omit it. Schema unchanged.
- Presence stays honest: a slot polls, renders, and alerts only when enabled
  and its directory exists. Removing a row stops metering that account and
  deletes nothing from the tool's directory; history for a removed slot key
  is retained, so re-adding the same directory keeps its past.
- The label is the user's own text — typed, stored locally, displayed. No
  account identifier is read or displayed anywhere (the ADR 0005 privacy
  boundary, unchanged).

## Consequences

- Any number of accounts per supported tool (Codex, Claude) without further
  model changes.
- Sources must declare slot identity; the protocols default to the primary
  slot, so single-account sources and test stubs are unaffected. Per-account
  sources (the Codex and Claude families) store their slot and derive
  `provider` from it.
- Readings for a newly added or re-pointed account appear after relaunch,
  when composition builds that slot's sources; the Settings card says so.
- The protocol `slot` default must not be paired with a `provider` default
  in the same extension: inside a protocol extension the unqualified name
  resolves to the extension's own default, and the pair recurses to a stack
  overflow (found by the test suite crash). Only `slot` carries a default;
  `provider` stays a plain requirement.
