# ADR 0007: Track observed Codex credit balance decreases

- Status: Accepted
- Date: 2026-09-30

## Decision

Reuse the Codex credit balance already returned with quota. Track positive
decreases between successive finite, non-negative balances for each
`ProviderSlot.key`. An increase sets a new baseline and keeps the observed
total. Duplicate or older readings do not change it. Missing, unlimited,
or invalid balances clear the comparison baseline.

Store the total, baseline, first observation date, and latest sample date
in the existing UserDefaults preferences system. Keep credentials, account
identity, labels, and paths out of this record. Preserve unreadable stored
data and stop recording instead of replacing it.

Expose one switch in Settings → Pacing & Telemetry. Tracking defaults to on.
Off pauses recording, clears baselines, and hides the credit rows. On retains
totals and starts comparing after the next reading. Demo mode uses synthetic
usage and never writes credit history.

The quota card and side-notch hover card share a compact credit row: available
balance first, observed use below, and a quiet start date. Keep subscription
quota windows and earned reset credits separate. Preserve provider marks and
the side-notch anchor. Do not draw a percentage meter without a known credit
budget.

## Limits

The measure is sampled balance change, not a billing ledger. Top-ups can mask
spending; expiry and adjustments can lower balances. No session attribution
or historical backfill is possible from this response. A login change within
the same config directory requires the user to switch tracking off and on
to reset the baseline; the app does not inspect account identity.

## Verification

Synthetic tests cover first readings, decreases to zero, top-ups, duplicate
and older responses, per-account isolation, invalid and unlimited balances,
pause/resume, relaunch persistence, demo isolation, and unreadable storage.
Native side-notch captures must prove visual fit and preserve the strip
anchor for two providers with different card heights before release.
