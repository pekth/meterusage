# ADR 0016: Isolate Claude allowance validation in the existing UI

- Status: Candidate implementation; independent review and native acceptance pending
- Date: 2026-10-10

## Decision

Add `--claude-test-profile` for a separate Claude candidate. This extends
ADR 0012's isolated validation pattern to the Claude flow accepted in ADR 0011.
It does not enable Claude in a Codex profile or change its saved consent.

Reuse the absolute-directory, protected-path, symlink and Electron singleton
checks. Use a distinct marker. Reject another provider test flag, demo flags
and candidate-profile selection. Store preferences, archives and Electron
state in the test directory. Retain OS home for the existing Desktop reader.

Start without consent. Reuse Settings, its explicit consent dialog, the fixed
Keychain helper and read-only Desktop cache/cookie reader. A connection call
without a consent callback must deny Claude access. Compose only account-bound
Claude allowance, with no local or companion fallback. Block Codex access and
cleanup, other provider collection, status feeds and reset redemption.
Candidate update, login-item and notification guards remain in force.

Keep the approved account/organization fingerprint across normal quit so
relaunch can test noninteractive collection. Disconnect disables access and
clears allowance without modifying Claude Desktop. No new credential source,
refresh tokens, client impersonation or model request is permitted.

## Acceptance

Synthetic fixtures cover isolation, consent, connection, relaunch and
disconnect. Packaged native acceptance must verify the helper, user-owned
permission flow, current Desktop format, fresh allowance, relaunch without
prompts and removal of allowance on disconnect. Account switches and denied
access need their own approved checks. Synthetic proof cannot establish live
provider compatibility or cross-device coverage. Installed-app replacement,
release and Windows holds remain unchanged.
