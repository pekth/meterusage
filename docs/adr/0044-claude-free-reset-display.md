# ADR 0044: Show and redeem Claude free resets in MeterUsage

- Status: Accepted; display confirmed on a real personal account; redemption pending first real use
- Date: 2026-11-03
- Amends: [ADR 0016](0016-claude-live-test-profile.md) (Claude usage request; reset redemption outside the test profile)

## Context

Claude occasionally gives eligible paid plans a one-time "Reset for free" in
Settings → Usage. It refills the usage limits and expires at a shown date.
MeterUsage already reads the account's usage through the Claude Desktop
connection, but the response omits saved resets unless the request opts in
with `cedar_ember=1`. Claude redeems a reset through
`POST /api/organizations/{organization}/reset_rate_limits` with the grant and
an idempotency key. Neither is documented, and either can change.

The owner decided MeterUsage should redeem a reset itself, as it does for
Codex, rather than send users to Claude's website.

## Decision

- The Claude usage request adds `?cedar_ember=1`. If it fails with a failed or
  not-signed-in error, MeterUsage retries once without it. Browser challenges
  and offline errors are not retried.
- From the `cedar_ember` block MeterUsage selects only `eligible`,
  `next_grant_id` and, per grant, `id`, `resets_left`, `resets_total`,
  `paused`, `starts_at`, `ends_at` and `usable_now`.
- A grant is live when it is not paused, has resets left, has started and has
  not expired. It is redeemable when its identifier matches
  `^[A-Za-z0-9_-]{1,64}$`, `usable_now` is not false and, when Claude names a
  next grant, it is that grant. Other live grants show as "Not usable yet".
  More than 200 grants or 50 resets shows none. The usage windows are never
  affected.
- The card shows "N free reset(s)" from fresh readings only. A redeemable grant
  offers **Use reset**. MeterUsage asks for native confirmation, which defaults
  to Cancel and names the account.
- After confirmation MeterUsage reads the Keychain password once without UI,
  verifies the bootstrap account and organization, rereads usage and checks
  that the grant is still redeemable. Only then does it send
  `POST https://claude.ai/api/organizations/{organization-uuid}/reset_rate_limits`
  with `{"program":"cedar_ember","grant_id":…,"request_id":…}`, the Desktop
  session cookie, `Content-Type: application/json` and
  `Origin: https://claude.ai`. Bootstrap and the local credential are checked
  again before the result is reported. The transport sends a body only to this
  exact URL, and only up to 1 KiB.
- Claude's `reset` result resets pacing as in
  [ADR 0008](0008-reset-aware-quota-pacing.md) and refreshes usage.
  `not_limited`, `already_used`, `ineligible`, `cooldown` and `unavailable`
  show a fixed message. An unanswered or `unavailable` claim keeps its request
  ID in memory so a retry addresses the same claim.
- Grant identifiers stay in memory. They are not written to the quota archive
  or included in JSON reports. Demo and Claude test profiles cannot redeem.
- MeterUsage never redeems automatically.

## Evidence and limits

Synthetic tests cover parsing, the usage retry, both endpoint checks, the claim
body, every outcome, request ID reuse, account changes during a claim, the
archive exclusion, the card and the coordinator messages. On 2026-11-03 a
signed local build on a Mac, connected to a personal Claude Desktop account
with one unused reset, showed "1 free reset" expiring 2026-12-15 and offered
**Use reset**, so the grant identifier and usability fields parsed. Redemption
through `claude.ai` has not yet run against a real account. The owner is
keeping the reset until it is needed. Team and Enterprise organizations are
not covered.
