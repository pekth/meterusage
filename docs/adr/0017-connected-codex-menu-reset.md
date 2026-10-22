# ADR 0017: Allow confirmed resets for the connected Codex menu

- Status: Accepted implementation direction; native and live redemption proof pending
- Date: 2026-10-10

## Decision

Show **Use reset** beside available, unexpired Codex reset credits in the menu.
Reuse the existing renderer action, validated IPC, coordinator intent and native
confirmation. Confirmation defaults to Cancel and identifies the credit and
account. No automatic redemption or model request is added.

Bind the source and consume operation to the generated connection profile that
supplied allowance. After confirmation, reread allowance and require the same
available, unexpired credit. Recheck the enabled profile before helper dispatch
and after completion. Reject overlap; abort pending reset work on disconnect or
quit. Profile replacement invalidates the coordinator's intent and readings.
A request already sent to the provider may consume a credit despite cancellation;
do not retry automatically or claim it was undone.

Use the existing official helper reset RPC with keyring-only configuration and
real OS home. The helper continues to own authentication and secrets. Require an
explicit reset outcome before resetting pacing and collecting fresh quota.

This narrowly supersedes ADR 0012's prohibition on reset redemption in
`--codex-test-profile`. That mode retains isolated preferences, app data and
Electron state. Public Codex status remains permitted under
[ADR 0015](0015-codex-test-public-status.md). Other providers, local activity,
other status feeds, updates, login-item changes, notifications and model requests
remain excluded.

## Acceptance

Synthetic fixtures cover connected eligibility, the menu request, cancellation,
one confirmed consume, duplicate actions, stale/spent/expired credits,
disconnect/profile changes, failure outcomes and refreshed quota. Static markup
checks cover the accessible control at Small, Medium and Large panel scales.
These checks do not prove native layout, native confirmation or provider RPC
support in an installed helper. Native integration validation is separate. Live
redemption requires the user's own click and confirmation; implementation tests
must not consume real credits.
