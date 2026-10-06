# ADR 0010: Port macOS to TypeScript and Electron

- Status: Accepted architecture; native migration acceptance pending
- Date: 2026-10-06

## Decision

Port the macOS app and headless schema-1 JSON CLI to TypeScript, Electron and
React. Use pnpm, Vite+, Tailwind and Vitest with electron-builder for macOS
packaging. Keep one package and a small validated IPC bridge. Main owns
provider files, existing credentials, subprocesses, persistence, refreshes and
native actions. Renderer windows use sandboxing, context isolation and no Node
integration; main validates the sender and request shape.

Windows implementation, installers, CI, testing and releases are paused because
there is no test machine. Shared source may stay portable. This supersedes the
RN/Tauri and Windows-first direction in the earlier pipeline plan.

## Compatibility

Retain history/archive JSON, schema-1 output and macOS preference keys. Preserve
Swift reference-date archive encoding and UserDefaults Data for managed
accounts. Generated account IDs stay stable through rename and enable changes;
labels are display-only. Keep provider marks/status tint (ADR 0002), measured
burn attribution (0003), fixed whole-point notch anchoring (0004), managed
accounts (0006), reset observation pacing (0008) and verified prebuilt
installation (0009).

Keep `MeterUsage.app`, executable `meterusage`, bundle ID `dev.meterusage.app`
and the `MeterUsage-<version>.zip` asset pattern. Retain the Swift app and source
as the behavior oracle and rollback path until native acceptance passes. Do not
introduce a new durable-data migration or automatic cutover.

## Candidate isolation and acceptance

Select demo/candidate configuration before composition. An explicit candidate
profile requires demo mode and an isolated test directory. Preferences,
history, caches and Electron state use that profile; provider sources and reset
consumers are synthetic. Demo mode blocks live provider discovery, update
installation and login-item changes. Candidate packaging does not install or
publish itself.

Source validation requires executed TypeScript/build/fixture checks and
independent review tied to current inputs. Native acceptance also requires a
macOS bundle digest/signature, headless JSON, launch/relaunch, settings/account
and offline journeys, notifications/login items, sharing/updater behavior and
captures of two different-height notch cards with a fixed top edge and strip.
Record package size, idle RSS and cold/warm scan times. Missing native proof
keeps migration and cutover open; a source-only draft PR cannot claim parity.

## Consequences

Electron adds package and process overhead. Measure that cost on the native
candidate. It supplies the desktop shell without adding a server, remote
networking, auth layer, event sourcing, Rust monitor or another application.
Provider discovery and privacy remain constrained by the existing source
contracts. Correct stale documentation instead of treating it as permission to
read more data.

No workflow changes, release publication, deployment or installed-app
replacement follow from this architecture decision.

## References

- [Migration plan](../plans/macos-electron-migration-plan.md)
- [Contributor commands](../../CONTRIBUTING.md#typescript-electron-candidate)
- [Privacy boundaries](../PRIVACY.md)
- [Superseded platform pipeline](../plans/feature-and-windows-pipeline.md)
- [Electron security guidance](https://www.electronjs.org/docs/latest/tutorial/security)
