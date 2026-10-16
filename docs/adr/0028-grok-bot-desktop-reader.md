# ADR 0028: Read Grok Bot Desktop allowance after consent

- Status: Source implemented; native and live-provider acceptance pending
- Date: 2026-10-16
- Amends: ADR 0027 for new connections; saved Cursor sources remain compatible

New Grok connections use **Connect Grok Bot Desktop (Beta)**. The user signs in
through Bot first, then permits MeterUsage's read-only access. MeterUsage does
not add an xAI sign-in flow, invoke app code, impersonate Bot or refresh tokens.

The compatibility trace is pinned to installed Bot 0.71.2, Electron 42.1.0.
Static SHA-256 identities inside the app archive:

- `main-app.cjs`: `90ec55edf69be56c6cfd4fffa98fc45210acccf913b6c41402b5b6cca6fd538e`
- `main-core.cjs`: `6422c2c4755d1722a9b6e842fb7117cf8eecce62d6c6a0bbdea53728999a9558`
- `proto.cjs`: `7727f3027a1bc01890cd07ed2aa4bba0f7b77a9962db110ce94056841bd2f168`

Require version 1 of `Grok Bot/sand-secrets.json` under Application Support.
Select the string-valued `cursor-accounts` container, its active scope, and only
that account's `cursor-access-token` and optional `cursor-selected-team-id`.
Reject duplicate keys, symlinks, unsupported versions and changed files. Bound
the read to 4 MiB, including growth after stat. Never decode a refresh token or
another account's credential value. Require `scoped:v1` envelopes and bounded
Electron `v10` encryption. Reuse the existing Claude PBKDF2/AES decryptor.

The helper adds one fixed mode for `Grok Bot Safe Storage` / `Grok Bot` while
preserving its Claude default pair. This pair is derived from matching Electron
42.1.0 source, which uses app name plus ` Safe Storage` as service and app name
as account. Explicit Connect may show Keychain UI; background polling cannot.
No arbitrary Keychain service/account selection or enumeration is permitted.

Require the full JWT subject hash to match the active and envelope scopes, with
expiry beyond sixty seconds. Validate the optional team as a safe nonnegative
integer. Include both account and team in a provider-scoped opaque fingerprint.
Recheck identity, team and store after requests, including transport failures.
A cancellation or revoked connection prevents every subsequent private read.
Failed preference saves disable collection and restore source metadata safely.

POST empty Connect JSON only to
`https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus` with
`Connect-Protocol-Version: 1`, bearer auth, optional `x-cursor-team-id` and
MeterUsage's own User-Agent. Refuse redirects, bound responses to 1 MiB and
requests to thirty seconds. Project finite 0-100 quota and optional reported
reset. Reject pooled enterprise allowance and contradictory included-limit
flags. A live trial may show quota, but its expiry is not a reset. Do not infer
cadence or create a second reading for Cursor's shared pool.

Persist only the internal source marker and opaque identity. Missing source
metadata defaults to the legacy Cursor reader for existing saved connections.
New successful connections save Bot source. No failed Bot request falls back
to Cursor. Connected sources retain account-bound archive clearing and omit
local CLI history. Disconnect changes only MeterUsage state.

Synthetic tests cover parser/decryption, transport bounds, consent, lifecycle,
races, rollback and saved Cursor behavior. Store existence/native format, derived
Keychain naming, packaged helper behavior and server acceptance of JSON without
Bot's internal metadata remain unverified. The published release is unchanged.
See [privacy](../PRIVACY.md) and [setup](../DESKTOP-CONNECTIONS.md).
