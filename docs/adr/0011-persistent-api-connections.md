# ADR 0011: Keep API connections in macOS Keychain

- Status: Accepted
- Date: 2026-09-27
- Supersedes: credential storage in [ADR 0009](0009-session-only-api-connections.md)

Session-only keys make users reconnect after every restart or update. Save
keys entered for OpenAI and Anthropic in native macOS Keychain items. Keep the
existing masked entry, connection tests, and direct provider requests.

Use generic-password items under `com.meterusage.api-keys`, with stable
`openAI` and `anthropic` accounts. Keep the default macOS application access
control and disable synchronization. Do not read another app's credentials or
copy keys into preferences, plaintext files, diagnostics, or logs. Never
restore a saved key into the entry field.

Save or replace the Keychain item before changing the active credential. Delete
it before reporting Disconnect. Failed writes leave the previous connection
intact. Failed reads show an error and allow retry without new key entry. Saved
keys take precedence over launcher environment keys; use the latter only when
no item exists, and never persist them automatically. Disconnect suppresses
launcher fallback until the next launch. Provider failures retain the key so
a later refresh can retry. Revisions reject late results after replacement or
disconnect.

Use an injected memory store in normal unit tests. Demo mode never creates a
Keychain store. Native storage checks use isolated synthetic items and delete
only those items afterward.

Updates preserve items, but ad-hoc signed binaries have a changing designated
requirement. macOS may ask for access approval after an update. Do not weaken
access controls to avoid this prompt. The old process has no supported export
of its memory-only key, so the first upgrade requires one final entry in the
app. Restarting does not revoke the provider's key.

Recovery clarification: distinguish a missing key from a saved-key read error.
An unreadable saved key offers Restore saved connection and never opens the
entry field. A failed save retains the submitted value privately in memory
and offers Retry saving key. Saving or explicit Disconnect clears that pending
value. Keep the app open until saving succeeds; pending memory is not durable.
