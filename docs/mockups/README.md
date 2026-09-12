# Concept mockups

Synthetic UI concepts for the next meterusage feature waves. Numbers are invented. Visuals use the shipping hardware-black notch palette.

## Hard constraint: provider marks stay

Do **not** redesign or replace provider icons/logos.

| Asset / mark | Location |
|---|---|
| Codex logo | `Resources/codex-logo.png` |
| Grok logo | `Resources/grok-logo.png` |
| OpenCode Go logo | `Resources/opencode-logo.png` |
| Antigravity logo | `Resources/antigravity-logo.png` |
| App icon | `Resources/AppIcon.png`, `Resources/AppIcon.icns` |
| Render path | `ProviderMark` in `Sources/MeterUsage/Views/MenuBarLabel.swift` |

Menu bar, popover, settings, and side-notch continue to use `ProviderMark`. New UI (including any cross-platform shell) must reuse these assets and the same mark semantics (service-status tint on the mark, headroom tint on the %).

## Waves

| Wave | Concept | Spec | Preview |
|---|---|---|---|
| 1 | Ambient time-to-empty | [01-time-to-empty.md](01-time-to-empty.md) | [01-time-to-empty.png](01-time-to-empty.png) |
| 2 | What burned this window | [02-burn-attribution.md](02-burn-attribution.md) | [02-burn-attribution.png](02-burn-attribution.png) |
| 3 | Smarter pace alerts | [03-pace-alerts.md](03-pace-alerts.md) | [03-pace-alerts.png](03-pace-alerts.png) |

Interactive HTML (all three): [top3.html](top3.html)

Release order and Windows track: [../plans/feature-and-windows-pipeline.md](../plans/feature-and-windows-pipeline.md)
