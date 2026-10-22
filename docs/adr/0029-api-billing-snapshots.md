# ADR 0029: Read separate API billing snapshots

- Status: Accepted implementation direction; real billing acceptance pending
- Date: 2026-10-16

Add OpenAI API and Anthropic API billing as a separate snapshot field and compact
cards. Preserve existing subscription provider identities, quota/archive state,
menu-bar readings, side-notch entries and schema1 quota JSON. Keep OpenRouter's
existing key/account activity adapter unchanged.

A bundled short-lived helper reads only its selected Admin key from its process
environment. The app has no key-entry field and never receives this credential.
The helper calls fixed documented organization cost endpoints, projects daily
USD amounts and discards identifiers and raw responses. It writes owner-only
files by atomic replacement to the fixed API usage directory. Failures retain
the previous snapshot. There is no background scheduler or credential store.

Cards show the reported UTC period and capture time. Reports become stale after
24 hours or a UTC-month transition. Empty reports stay unknown; measured zeroes
remain zeroes. Anthropic Priority Tier costs remain excluded. Do not present API
costs as subscription allowance or local token estimates.

The API usage guide defines setup and retained fields. Synthetic proof does not
establish a real organization's permissions, report completeness or invoice
accuracy. These require separate live acceptance.
