# ADR 0025: Card Settings and explicit diagnostic reports

Status: Accepted implementation direction

The compact side-notch strip contains provider usage only. Each expanded card
already offers Settings, and the menu-bar context menu provides another entry.
Remove the duplicate strip gear and its slot. This amends ADR 0019's gear
placement without changing card-side or top-edge anchoring, ring dimensions,
provider ordering or hover behavior.

Electron Settings → Diagnostics restores the existing support-report contract.
Only an explicit live Settings action sends a main-generated sanitized summary.
The renderer cannot select report content or destination. Reuse the existing
private Linear relay with bounded requests/replies, verified receipts and
duplicate-safe retries. Never attach raw logs or provider credentials.

See [reporting](../REPORTING.md). Transport fixtures and synthetic browser checks
are separate from native visual acceptance and live support delivery.
