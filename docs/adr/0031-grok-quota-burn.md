# Measure Grok Bot quota burn from recent observations

- Status: Accepted
- Date: 2026-10-17

## Context

Grok Bot Desktop reports a used percentage and sometimes a reset deadline. It
does not report token counts, billing, or the duration of that quota cycle.
Cycle-based pacing would need to invent a start time.

## Decision

Track fresh same-account Bot readings in memory through the existing quota
baseline fields. Require increasing observation timestamps spanning at least
one minute, with baseline and latest readings within five minutes. Divide the
change in percentage points by observed elapsed time. Unchanged usage yields
zero only after the minimum interval. This is a recent measured average, not
an instantaneous token rate.

Discard measurement on quota decrease, reset/deadline change, expiry, stale or
invalid timestamps, failed collection, reconnect or source/account changes.
Use live readings only; strip baselines from retained and saved Grok archives.
Old archive baselines cannot initialize measurement. Preserve Codex reset pacing.

Show the rate in menu and notch usage cards while pacing is enabled. A positive
rate can project remaining allowance; suppress projections in the past or after
a reported reset. Missing data displays collection state without invented zero,
tokens, cost, or a quota-cycle duration. No new request or credential access is
needed. Provider percentage rounding can make this short-window estimate uneven.

## Verification

Synthetic domain/coordinator and renderer tests cover measurement, zero,
minimum interval, stale/reset/account boundaries, archives and display controls.
Native packaging and live measured-rate acceptance require separate evidence.
