# ADR 0044: Show Claude free resets and link to Claude to use them

- Status: Source implementation; live acceptance against a real account pending
- Date: 2026-11-03
- Amends: [ADR 0016](0016-claude-live-test-profile.md) (Claude usage request)

## Context

Claude occasionally gives eligible paid plans a one-time "Reset for free" in
Settings → Usage. It refills the 5-hour and weekly limits and expires at a
shown date. MeterUsage already reads the account's usage through the Claude
Desktop connection, but the response omits saved resets unless the request
opts in with `cedar_ember=1`. This field name is undocumented and can change.

## Decision

- The Claude usage request adds `?cedar_ember=1`. The endpoint check accepts
  only that exact query on the UUID-bound usage URL.
- If the opt-in request fails with a failed or not-signed-in error, MeterUsage
  retries once without it. Browser challenges and offline errors are not
  retried. The bootstrap checks and credential rereads around the request are
  unchanged.
- From the `cedar_ember` block MeterUsage selects only `eligible` and, per
  grant, `resets_left`, `resets_total`, `paused`, `starts_at` and `ends_at`.
  Grant identifiers are redemption handles and are never selected.
- A reset is available when the block is eligible and the grant is not paused,
  has resets left, has started and has not expired. Each available reset
  becomes a "Free reset" credit with only its expiry. A malformed grant is
  dropped. More than 200 grants or 50 resets shows none. The usage windows are
  never affected.
- The Claude card shows "N free reset(s)" with expiry dates. A live, unexpired
  reset offers **Open in Claude**, which opens the fixed
  `https://claude.ai/settings/usage` page from the menu, notch or Settings.
  The renderer supplies no URL. Demo, candidate and test profiles cannot open it.
- MeterUsage never redeems a Claude reset. Redeeming would need an
  undocumented write request with the Desktop session, which ADR 0016 rules out.
- Claude free resets are live-only. They are not written to the quota archive,
  so a reset used on claude.ai cannot reappear after a restart.
- The existing reset-credit expiry alert covers Claude free resets.

## Evidence and limits

Synthetic tests cover parsing, the retry, the endpoint check, the archive
exclusion, the card and the IPC surface rules. They do not prove that a real
account returns this block in this shape, or that Team and Enterprise
organizations receive it.
