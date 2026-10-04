# ADR 0007: Muse usage comes from native local history

- Status: Accepted
- Date: 2026-10-03

## Decision

Add Muse CLI as an opt-in usage provider. Read only schema fields, sequence
numbers, timestamps, and event kinds from its native `session.jsonl` files.
Count run-started events as user messages and assistant-message-committed events
as assistant messages. Task events do not add messages. Retained frames are
skipped, so inherited fork content is not counted again.

The data root is the absolute `XDG_DATA_HOME`, or `~/.local/share` when unset
or relative. The source does not query Muse's session index, which can be empty
while native session logs exist. It does not spawn Muse or send model requests.

## Evidence and limits

Muse Code 1.4.2 native log shapes were checked using synthetic echo output.
Its exported MSP schema documents `usage/read` as a read of the host's last
observation, with no model call. A fresh host returned an empty result.

Quota, token totals, and cost stay unavailable in this integration. No private
billing API or credential file is used to fill those gaps. The quota-only JSON
report has no Muse entry, and the menu bar has no Muse percentage.

## References

- `Sources/MeterUsage/Services/MuseUsageSource.swift`
- `Tests/MeterUsageTests/MuseUsageSourceTests.swift`
- [`PRIVACY.md`](../PRIVACY.md)
