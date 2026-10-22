# ADR 0030: Accept account-bound encrypted Grok Bot legacy values

- Status: Accepted bounded correction; live allowance acceptance pending
- Date: 2026-10-16
- Amends: ADR 0028 encrypted-envelope and fixed Keychain-account assumptions

Native metadata for Bot0.71.2 establishes that its active account can contain a
canonical base64 encrypted v10 access value without a scoped envelope. The fixed
Grok Bot Safe Storage service uses the account label Grok Bot Key. The initial
source reader required a scoped envelope and queried the wrong account label.

Read only that fixed service/account pair. Accept canonical encrypted v10
values with either a matching scoped envelope or no envelope. In both forms,
the decrypted JWT's full subject hash must equal the selected active account,
and expiry must exceed sixty seconds. Preserve all store stability, duplicate,
team, cancellation, request and identity checks from ADR 0028. Plaintext and
unsupported encryption remain rejected. Never search other Keychain items,
refresh credentials, change Bot stores or fall back to Cursor on failure.

Native store/Keychain metadata establishes the format and fixed item label.
Synthetic decryption and account-binding checks establish source behavior.
Neither proves access permission or successful live allowance collection.
