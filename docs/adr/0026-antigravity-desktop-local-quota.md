# ADR 0026: Read Antigravity Desktop quota through its local service

- Status: Source implementation; native and provider acceptance pending
- Date: 2026-10-16
- Amends: [ADR 0011](0011-desktop-account-connections.md), for opt-in Antigravity Desktop allowance

## Decision

Offer **Connect Antigravity Desktop** beside the existing explicit CLI choice.
Use the running desktop language server's fixed `GetUserStatus` and
`RetrieveUserQuotaSummary` RPCs. Do not require or start `agy`, download a helper,
copy OAuth credentials, refresh tokens or write to provider stores.

Discover executable names before reading arguments for one matching same-user
PID. Require its CSRF token and its own IPv4 loopback listener. Multiple
matching desktop servers are ambiguous, including multiple windows that start
separate servers. Reject them instead of choosing an account. Recheck process,
listener and token ownership before each request.

Prefer HTTPS. Limit certificate verification exemption to an individual request
to the verified `127.0.0.1` listener. HTTP is allowed only on the declared,
PID-owned extension-server port. Use fixed RPC paths and bodies, reject
redirects, limit responses to 1 MiB, requests to three seconds and a full read
to fifteen seconds. Never expose provider errors or process output.

Require `GetUserStatus.userStatus.email` before and after quota collection.
Retain only its provider-scoped SHA-256 fingerprint in MeterUsage preferences;
exclude it from renderer settings and diagnostics. This extends ADR 0011's
opt-in identity exception to Antigravity. Keep CSRF credentials and raw replies
in main-process memory only. Reject changed or missing identity, cancellation,
disconnect and results from an earlier connection, including reconnection to
the same account.

A successful modern response is authoritative. Empty summaries and missing,
invalid, disabled or expired buckets stay unavailable. Use legacy
`GetUserStatus` model fractions only after an explicit unsupported response
(HTTP 404/501 or RPC code 12/`unimplemented`). Do not infer weekly quota or
turn a missing fraction into depleted allowance.

Present modern quota under compact model-group headings. Remove the known
remaining-allowance suffix and shorten explicit Five Hour labels. Keep all
reported buckets, values and resets; assign duration metadata only to explicit
Weekly or 5-hour labels. Unknown model names remain visible. A saved identity
with missing allowance is a saved connection, not proof of a live reading.

Connected allowance has no CLI-local activity attached. Disconnect disables
collection without selecting CLI. **Use CLI** explicitly restores the existing
local source. Clear account quota on source changes, failed identity/data reads
and launch, using the existing connection/coordinator flow.

## Acceptance

Synthetic fixtures establish discovery filtering, transport bounds, quota
projection, account changes, archive clearing and cancellation/save races.
They do not establish native process discovery, installed-app compatibility,
local TLS behavior or live allowance accuracy. Those checks remain required
before claiming Antigravity Desktop support in a released artifact. The
published beta and legacy Swift release are unchanged.
