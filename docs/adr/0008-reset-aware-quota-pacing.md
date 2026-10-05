# ADR 0008: Collect fresh quota observations after a manual reset

- Status: Accepted
- Date: 2026-10-05

## Context

Ordinary quota pacing estimates the cycle start from the provider's reset
deadline and window duration. A manual Codex reset invalidates that inferred
history. Dividing the new used percentage by the old elapsed time can show a
misleading burn rate and run-out time.

## Decision

After Codex accepts a manual reset, mark only the redeemed account slot for
observation-based pacing. Clear its prior pacing estimate immediately. The
first fresh reading establishes a baseline for each quota window. Later
readings with positive usage growth provide the observed rate:

`rate = (current used percent - baseline used percent) / observation interval`

Project exhaustion from the latest reading's remaining allowance and this
rate. Compare the rate with the allowance available from the baseline until
the provider's reset deadline. A first reading or unchanged usage supplies
no forecast. There is no fixed minimum collection duration.

Match samples within the same account, quota group, window label, reset
deadline, and duration. Start a new baseline when the cycle or duration
changes or usage decreases. Reject reads started before reset acceptance.
Rejected or failed reset requests preserve the existing estimate.

Persist the reset boundary, samples, and quota display metadata in the
existing quota archive. Older archives remain readable. Archived readings
remain dated and stale; loading them does not create a fresh observation.
General and model-specific windows retain separate baselines.

## Consequences

- ETA appears after measured post-reset usage growth, including across
  relaunches.
- Other account slots and providers retain their existing calculation.
- Provider reset deadlines, quota percentages, and burn-recency rules keep
  their existing meaning.
- Synthetic coordinator and model tests can verify the reset path without
  redeeming a real reset credit.
