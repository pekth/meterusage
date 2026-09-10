# Demo mode

Demo mode runs the real app against synthetic, invented data.

---

### ⚡ TL;DR

* 🎭 **True-to-Life UI**: Runs the real views, formatting, and pacing calculations without touching real accounts, credentials, or network services.
* 📸 **Safe for Screenshots**: Ideal for documentation and public sharing without leaking private spend or account tiers.
* 🚀 **One-Command Launch**:
  ```sh
  METERUSAGE_DEMO=1 swift run meterusage
  ```
  *(A **Demo** badge in the header ensures synthetic numbers are never confused with real ones).*

---

## Why Demo Mode Exists

Screenshots — for the README, an issue report, or a blog post — and contributor testing should never require a real account, a signed-in CLI, or exposing personal usage. A maintainer's real popover shows real spend, real session counts, and a real plan tier; none of that belongs in a public repository.

## Launching Demo Mode

The app is a bundle, and macOS `open` does **not** forward shell environment variables to bundled apps by default. Use `--env` to pass it:

```sh
open -a MeterUsage --env METERUSAGE_DEMO=1
```

Or execute the binary directly from the terminal:

```sh
METERUSAGE_DEMO=1 /Applications/MeterUsage.app/Contents/MacOS/MeterUsage
```

From a local source checkout:

```sh
METERUSAGE_DEMO=1 swift run meterusage
```

Quit and relaunch normally without the variable to return to your real data.

## What It Is — and Isn't

It is **not** a mock UI. The production SwiftUI views, AppCoordinator, formatters, and pacing calculations run identically to normal execution. Only the data sources are swapped: real sources inspect local CLIs and session files, while demo sources return fixed, synthetic values from memory.

## Synthetic Data Breakdown

All demo data is invented and deterministic:

- **Service Health**: Reports operational components for Codex and Claude public status pages.
- **Codex Quota**: Plus plan tier, 5-hour and weekly allowance windows, a GPT-5.3-Codex-Spark window, two expiring full-reset credits, and an approximate credit balance.
- **Antigravity Quota**: Multi-group model families:
  - *Gemini Models*: Weekly limit (89% used, 11% left) and 5-hour limit (9% used, 91% left).
  - *Claude and GPT models*: Weekly limit (1% used, 99% left) and 5-hour limit (0% used, 100% left).
- **OpenRouter**: Synthetic monthly dollar spending limit, account balance meter, and 30-day token telemetry.
- **Grok**: Weekly allowance window with countdown and session activity history.
- **OpenCode Go**: 26 sessions, 492 messages, token volume totals, and estimated cost.
- **Claude**: Optional companion-file quota windows and tokens-per-day heatmap.
- **26-Week Heatmaps**: 26-week activity matrices for Codex (sessions) and Claude (tokens) with interactive daily, weekly, and cumulative views.

Percentages span calm green and amber warning bands so screenshots demonstrate color headroom scales clearly without alarmist red styling. Reset countdowns are calculated relative to launch time so screenshots remain natural.

## Safety Guarantees

- **Strict Activation**: The environment variable must be exactly `1`. Values like `true`, `yes`, or `0` remain off.
- **Whole-App Integrity**: Evaluated once at composition root — the dashboard is never partially real and partially fake.
- **Prominent Badge**: A **Demo** badge is displayed in the header to prevent any confusion with live telemetry.
- **Zero Disk & Network Access**: Demo sources perform no network requests, touch no external disk files, and invoke no CLI commands.
