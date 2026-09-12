# Feature + Windows release pipeline

Ship the three HUD concepts in small macOS releases while proving a Windows path. Prefer React Native / Expo **only if** a tray + floating HUD spike works; otherwise Tauri 2 + React.

## Non-negotiable: provider icons/logos stay

Across every wave and any cross-platform shell:

- Keep shipping assets under `Resources/*-logo.png` and `AppIcon.*`.
- Keep `ProviderMark` semantics (mark = service status tint; `%` / rings = headroom).
- Do not invent replacement brand marks for Codex, Claude, OpenRouter, Grok, Antigravity, or OpenCode Go.
- New platforms must load the same logo files (or lossless copies), not SF-Symbol-only stand-ins where a real logo already ships.

See [../mockups/README.md](../mockups/README.md).

## Platforms

- **In:** macOS (current Swift app) + Windows (new shell after spike).
- **Out for now:** Linux tray redesign.

## Dual track

```text
Track A (macOS features)          Track B (cross-platform)
─────────────────────────         ─────────────────────────
A0 OpenRouter budget fix          B0 Spike: RN tray/HUD vs Tauri+React
A1 Wave 1 Ambient ETA  ──0.3.x──  B0a ADR with winner + idle RSS gate
A2 Wave 2 Burn attribution ──0.4.x──  B1 Shared domain contracts
A3 Wave 3 Pace alerts ──0.5.x──   B2 Windows path/provider adapters
                                  B3 Windows MVP (tray + flyout)
                                  B4 Port Waves 1–3 to shared UI
                                  B5 macOS migrate or dual-run + sunset
```

Track B must not block Track A unless a shared schema break is unavoidable. Version CLI JSON when ETA / burn / alert fields are added.

## Wave → mockup map

| Release (suggested) | Wave | Spec |
|---|---|---|
| 0.3.x | Ambient time-to-empty | [../mockups/01-time-to-empty.md](../mockups/01-time-to-empty.md) |
| 0.4.x | Burn attribution | [../mockups/02-burn-attribution.md](../mockups/02-burn-attribution.md) |
| 0.5.x | Pace alerts + failover | [../mockups/03-pace-alerts.md](../mockups/03-pace-alerts.md) |

One concept per macOS release. No mega-PR that mixes all three.

## Platform spike gate (Track B0)

Build two short throwaways (≤5 engineering days total):

1. React Native for Windows (and macOS if attempted) — system tray icon + always-on-top detail card.
2. Tauri 2 + React — same tray + card.

Record idle RSS, install size, tray click reliability, and whether **existing logo PNGs** render cleanly in the tray/flyout.

**Decision rule**

- Choose RN/Expo if tray + HUD + idle footprint are acceptable on Windows **and** macOS.
- Otherwise choose **Tauri 2 + React** (React-family UI, first-class tray).
- Write `docs/adr/0002-cross-platform-shell.md` with the verdict before B1.

Windows MVP may ship tray + flyout first; pixel-identical side notch can follow.

## Privacy

Unchanged: local numeric metadata only; no prompts/code; path redaction via `Privacy`; documented network endpoints only (`docs/PRIVACY.md`). Windows adapters must use the same rules.

## Out of scope

- Linux StatusNotifier redesign
- Team / FinOps / seat reclaim
- Notarized Mac or signed Store builds inside Waves 1–3
- MITM proxies or credential vaults
- Redesigning provider logos
