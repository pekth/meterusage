# ADR 0009: API connections keep keys only for the app session

- Status: Superseded by [ADR 0011](0011-persistent-api-connections.md) for credential storage
- Date: 2026-09-27

The environment-only setup in ADRs 0007 and 0008 leaves normal app launches
without a connection flow. Add Connect, masked key entry, Test connection,
Replace key, and Disconnect below each enabled API provider in Settings.

Keep entered keys in `APIKeySession` memory. Do not write them to preferences,
files, Keychain, logs, or diagnostics. Clear unfinished key entry when Settings
closes. Keep validated and retryable connection credentials until disconnect,
replacement, or quit. An app restart requires entry again unless the user's
launcher explicitly supplies the existing Admin-key environment variables.

Test the same usage and cost readers used by polling. Show Connected only
after both reports succeed. Report sanitized failures and the last successful
reading time. Disconnect clears the active key and visible reading, suppresses
environment fallback for this session, and discards late responses associated
with a disconnected or replaced credential.

Requests go directly from the user's Mac to the provider. No MeterUsage server,
browser cookies, or provider login tokens are involved. Anthropic documents
OAuth through its official CLI, which stores credentials locally; this change
adds only key entry. No persistent credential storage is introduced.
