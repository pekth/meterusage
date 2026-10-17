# Demo mode

Demo mode uses the real app views with invented data. Use it for screenshots
and UI inspection without exposing real accounts. The [current beta gallery](SCREENSHOTS.md)
shows Electron build 61. Old product captures have been removed.

## Electron browser preview

From the beta source checkout, after installing its declared dependencies:

```sh
node_modules/.bin/vp dev --mode demo --host 127.0.0.1
```

Open the printed address with `?surface=flyout`, `?surface=settings` or
`?surface=notch`. This dedicated demo mode uses the actual renderer and an
in-memory preview bridge. It has no native IPC, provider access or live network
transport. Native-only actions return an error. It does not validate Keychain,
window positioning, login items, sharing or other macOS behavior.

Provider marks exported during macOS packaging are needed for every icon to
render. Use those matching generated resources when capturing on Linux. Do not
substitute unrelated marks. Browser fonts and framing can differ from macOS.

## Electron candidate

After `pnpm build`, synthetic headless inspection uses:

```sh
meterusage_demo_root="$(node -p 'require("node:fs").realpathSync(require("node:os").tmpdir())')"
node dist/main/cli.cjs json --demo --candidate-profile "$meterusage_demo_root/meterusage-cli-demo"
```

For a packaged app on macOS, execute its binary directly:

```sh
./release/mac-arm64/MeterUsage.app/Contents/MacOS/meterusage --demo --candidate-profile /private/tmp/meterusage-native-demo
```

The profile must be empty on first use and use a canonical path. Symlink aliases,
including macOS `/tmp` and `/var`, are rejected. Reuse the same marked profile
for relaunch checks. Preferences, caches, history and Electron state stay there.
Live provider discovery, login-item changes and update installation are disabled.
Demo reset confirmation consumes only synthetic fixture credits.

## Swift legacy demo

From the retained Swift source on macOS:

```sh
METERUSAGE_DEMO=1 swift run meterusage
```

The environment value must be exactly `1`. Swift demo mode swaps provider
sources at composition; it does not establish current Electron appearance.
Quit and relaunch normally to return to real data. Do not run legacy and beta
normal profiles together.

## Data and proof

Demo sources supply example allowances, reset windows, account balances and
local token/session activity. Local history and account allowance are separate
measurements in the real app. A Claude demo heatmap does not imply access to
Claude Desktop chat history. Missing provider-reported values stay unknown.

Public captures must use synthetic data and identify it as demo data. Browser
captures prove renderer output only. Native anchoring acceptance still needs
Mac captures for two providers with different card heights, as defined in
[ADR 0004](adr/0004-side-notch-anchor-invariant.md).
