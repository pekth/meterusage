# ADR 0011: Add opt-in desktop account connections

- Status: Accepted implementation direction; native and provider acceptance pending
- Date: 2026-10-07

The macOS Electron candidate serves users who run desktop and cloud assistants
without using a terminal. Account allowance must come from the account service;
local activity alone cannot represent usage on another device. Windows remains
paused under ADR 0010.

Use the existing main-process source/coordinator boundary and validated IPC.
First-run setup and Settings offer browser sign-in for Codex and explicit
consent for Claude Desktop access. Keep additional configuration-directory
accounts under an advanced disclosure.

Codex owns a separate generated helper profile with OS keyring storage only.
The candidate checks effective storage before authentication. It discovers an
existing desktop helper rather than downloading or bundling another executable.
Missing or incompatible helpers fail closed. Native helper discovery and
protocol compatibility remain acceptance requirements.

Claude is an explicit change to the candidate's previous credential boundary.
The 2026-10-20 source amendment replaces OAuth cache selection with a Desktop
web-session reader. A new Connect explanation and approval are required;
previous untagged identities cannot enable it. Consent persists only as a
`web-v1:` opaque account/organization hash in the existing preference.

After consent, the fixed native Keychain helper supplies the key for main-process
decryption of only the fixed session and organization cookies. Background reads cannot prompt. Schema 24, encrypted
v10 host binding, Secure root cookies, HttpOnly session and exact expiry are
required. Fixed read-only SQLite SELECTs run in a sandbox denying writes under
the canonical Desktop store root. Bounded reads never copy the database.
Unsupported stores, sandbox failures and conflicting values fail closed.

GET `https://claude.ai/api/bootstrap` must verify the nested account UUID and
unique intended organization membership before a UUID-bound organization usage
GET. The captured cookie authenticates only those routes. Bootstrap and local
account/org/session stability are checked after usage. Do not use GET
`/api/account`, bearer tokens, OAuth cache fallback, refresh tokens, chats,
provider-store writes or inference. Redirect rejection, no-store, cancellation,
30-second requests and a 1 MiB decoded response limit apply. Membership does
not imply allowance entitlement. Native and live-provider acceptance remain
pending; this is an opt-in compatibility interface that can change.

This amends ADR 0005's prohibition on reading account identity only for this
opt-in main-process connection. Account identity is not displayed or retained
in plaintext. Existing additional-account slot rules remain unchanged.

Grok consumer collection has no verified automatic contract in this change.
Show it as unavailable. Manual entry is not fulfillment of automatic setup.
Existing integrations keep their documented boundaries.

Do not attribute local CLI tokens to a separately connected account or add
account allowance to local totals. Disconnect clears only MeterUsage-owned
connection state and authentication. Clear account quota on connection changes
and reject old source results. Native GUI, Keychain, live provider data and
packaged acceptance are required before claiming this works for desktop users.

The published Swift app, release installer and installed-app cutover remain
under ADR 0010 and ADR 0009. This decision does not authorize a release.
