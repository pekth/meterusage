# ADR 0033: Windows desktop source candidate

- Status: Accepted candidate scope; interactive Windows validation and release remain open
- Date: 2026-10-18
- Amends: [ADR 0010](0010-macos-typescript-electron.md) only for the Windows implementation hold

## Context

ADR 0010 selected macOS Electron development and deferred Windows work until a
test machine was available. The shared Electron application now has a Windows
x64 source candidate with platform-specific persistence, CLI discovery,
packaging and a CI workflow definition. This changes the implementation hold,
not the public release status or ADR 0010's macOS migration requirements.

## Decision

Keep the Windows work as an unsigned source candidate. The candidate includes
the tray, side notch, shared usage views and heatmaps, local CLI sources,
OpenRouter, Codex browser sign-in through the installed CLI, and one-time
OpenAI or Anthropic API billing keys. Windows does not offer Claude Desktop,
Antigravity Desktop or Grok Bot Desktop account connections. It does not import
saved macOS Admin keys. The tray stays compact, sharing opens a PNG Save dialog,
and the macOS updater is unavailable.

Windows preferences, history and sanitized billing snapshots use
`%APPDATA%\MeterUsage`; the default resolves under the user's
`AppData\Roaming\MeterUsage`. The candidate does not read macOS UserDefaults
or Keychain data. One-time API keys stay in memory for the requested fetch.

`pnpm package:win` configures unsigned x64 NSIS and portable executables. The
Windows workflow defines typecheck, focused tests, package creation and an
isolated demo/single-instance smoke check. Its definition is not evidence that
CI passed. No public Windows build or release is authorized by this ADR.

## CI validation

On 2026-10-18, [Windows run 39107127936](https://github.com/pekth/meterusage/actions/runs/39107127936)
passed for candidate head `82b7ca2952bc725576879647747ff4fa4018d60b`, using
PR merge checkout `58f48c2b20ca572b9480e8bfa2c0941b73a08d20`:

- Typecheck and 78 tests passed, including three native Windows npm-wrapper
  and process-tree tests.
- Unsigned x64 NSIS and portable executables were built.
- The unpacked packaged demo stayed running in an isolated profile, and a
  second invocation exited successfully while the first remained running.
- Both executables were uploaded as the
  [MeterUsage-Windows-x64-unsigned CI artifact](https://github.com/pekth/meterusage/actions/runs/39107127936/artifacts/12128544404).

The [macOS CI run](https://github.com/pekth/meterusage/actions/runs/39107127916)
also built the Swift package and passed 394 tests using the same PR merge checkout.
These receipts establish CI behavior for the recorded inputs. They do not
establish interactive Windows behavior, installer install/uninstall acceptance,
signing or a public release.

## Consequences and remaining proof

The Windows hold in ADR 0010 is lifted for source implementation only. Before
any Windows release claim, record a successful workflow run for the exact
candidate revision, then complete native Windows checks for startup, settings,
provider and offline paths, storage and relaunch, tray/notch behavior, PNG
sharing, and installer install/uninstall. Signing and artifact publication
require separate review and authorization. Until those receipts exist, describe
Windows as a source candidate and leave native, installer, signing and release
status open.

The public macOS beta remains 0.3.0-beta.3, build 61. The published stable
Swift release remains 0.2.41. This decision does not change either artifact,
the macOS migration gates, data migration or application identity.

## References

- [Windows packaging plan](../plans/feature-and-windows-pipeline.md)
- [Electron development guide](../electron/README.md)
- [Privacy and storage boundaries](../PRIVACY.md)
