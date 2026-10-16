# ADR 0027: Read Grok Bot allowance through closed Cursor

- Status: Implemented in source; native and live-provider acceptance pending
- Date: 2026-10-16
- Amends: ADR 0011's unavailable Grok connection; retains existing CLI choice

Offer opt-in **Connect via Cursor (Beta)** without a CLI requirement. The user
signs in to Cursor, checks Bot allowance, then quits Cursor. MeterUsage never
stops Cursor. Expiry requires reopening Cursor, then quit/reconnect. This is a
compatibility interface, not a universal Grok Desktop, X or shared-pool contract.

Open the original Cursor SQLite store with `immutable=1&mode=ro`. SQLite must
perform zero reader writes, including sidecar bookkeeping, regardless of other
processes. Do not copy credential stores or files to temporary disk. Reject
nonempty WAL/journal files rather than silently ignoring uncheckpointed data.
Use pre/post process and filesystem guards, and reject unavailable, ambiguous
or changed evidence. These observations detect races, not mutual exclusion;
they cannot prove Cursor never ran between observations. Operating-system
read access-time updates are outside SQLite's byte-write guarantee.

Select only `ItemTable` key `cursorAuth/accessToken`. Parse the JWT's final
pipe-separated subject component and require expiry more than 60 seconds away.
Keep account identity case-sensitive. Construct the established session cookie,
verify the subject through fixed `https://cursor.com/api/auth/me`, then POST
`{}` to fixed `https://cursor.com/api/dashboard/get-sand-usage-status` with
`Origin: https://cursor.com`. Refuse redirects, cap responses at 1 MiB and each
request at 30 seconds. No refresh or inference requests are permitted.

Persist only an opaque account fingerprint/source preference and projected
quota. Tokens and store fingerprints stay in main-process memory. Revalidate
account and store before allowance and after attempts. Disconnect, cancellation
and source replacement prevent stale publication and further private reads.
Reuse existing coordinator backoff and account archive clearing. Never attach
local CLI history to connected-account quota.

`includedLimitZero` overrides the legacy included-limit flag. Trials require a
future `sandTrialExpiresAt`; trial expiry is not a reset. Retain only reported
usage percent and optional reset timestamp without inferring a reset cadence.

Synthetic reader, protocol, lifecycle, IPC and UI tests are required. Native
Cursor format, packaged Electron SQLite behavior, GUI setup and live provider
support remain unverified. The published Swift release and beta build 54 are
unchanged. See [setup](../DESKTOP-CONNECTIONS.md) and [privacy](../PRIVACY.md).
