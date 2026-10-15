# ADR 0021: Save provider group order

- Status: Accepted implementation direction; rendered and native acceptance pending
- Date: 2026-10-11

Electron Settings saves a `providerOrder` list of known provider names. Installed
profiles use JSON encoded as defaults data, as managed accounts do. Isolated
candidate profiles use their existing preferences JSON file.

Stored input is normalized: keep the first occurrence of each known provider,
ignore invalid entries and append missing providers in the default sequence.
IPC writes require a complete, unique list of known providers and come only
from Settings. External drag data is never read.

Usage cards, service health, menu bar and side notch follow the saved order.
Each primary account precedes its additional accounts, which keep their existing
relative order. Collect and Show settings remain independent. OpenRouter stays
excluded from the menu bar. Ordering does not change polling or account identity.

Settings saves once on drop or a keyboard move. A canceled drag or failed save
keeps the last saved order and restores handle focus. Arrow keys and named move
buttons provide keyboard access. A line marks the proposed drop position.

The Swift app retains its existing fixed order. Synthetic tests do not prove
native drag behavior, VoiceOver, focus, or the fixed notch anchors.
