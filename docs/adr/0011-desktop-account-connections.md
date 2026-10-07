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
After consent, a fixed native Keychain helper and read-only Desktop cache/cookie
reader obtain the current account-scoped access token. Background reads cannot
prompt. Do not use refresh tokens, impersonate another client, modify Desktop
stores or issue model requests. Bind allowance to the account and organization;
reject a changed identity, ambiguous cache or unsupported format. This is an
opt-in compatibility integration whose provider interface can change.

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
