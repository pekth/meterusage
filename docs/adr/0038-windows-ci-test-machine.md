# ADR 0038: Resume Windows with CI as the test machine

- Status: Accepted; stages 1–4 implemented; unsigned 0.3.0-beta.13 published 2026-11-01; real-machine acceptance pending
- Date: 2026-11-01
- Amends: [ADR 0010](0010-macos-typescript-electron.md) ("Windows
  implementation, installers, CI, testing and releases are paused because there
  is no test machine")

## Context

ADR 0010 paused Windows until a test machine existed. There is still no
Windows PC. The maintainer has directed Windows work to resume, on the basis
that the app is Electron, with a GitHub Actions `windows-latest` runner as the
test machine. The goal is parity with macOS: CLI providers, desktop account
connections and automatic updates. The result ships as an unsigned GitHub
pre-release; there is no Authenticode certificate.

## Decision

Resume Windows work in separate, focused changes:

1. Platform foundation and a Windows CI job that packages the app and
   smoke-tests the packaged build.
2. A Windows updater: its own installer asset, the same GitHub SHA-256 digest
   check and the existing automatic-install deferral.
3. Windows desktop account connections: DPAPI-protected Chromium keys,
   read-only `node:sqlite` and Windows paths, with synthetic fixtures.
4. An unsigned Windows pre-release and user docs, published only after the CI
   smoke run passes. GitHub's `latest` stays on the stable release.

The CI runner is the only Windows test machine. Stage 1 also sets these
platform rules:

- **Data location.** App data lives in `%APPDATA%\MeterUsage` (roaming
  AppData). MeterUsage uses `%APPDATA%` only when it lies inside the user
  profile and otherwise falls back to `%USERPROFILE%\AppData\Roaming`. Redirected
  roaming folders outside the profile are not supported.
- **Preferences.** Windows has no `defaults` domain. Installed Windows apps keep
  known keys in `preferences.json` through the same validated, atomic writer
  that demo and test profiles use. A file that cannot be parsed is renamed to
  `preferences.json.damaged-<time>` and defaults apply; a read error such as an
  antivirus lock is not treated as damage. Atomic JSON replacement retries a
  briefly locked rename and never leaves its temporary file.
- **File trust.** Windows `stat` has no owner, and its mode bits only reflect the
  read-only attribute, so POSIX owner and `0o077`/`0o022` checks would reject
  every file. On Windows the per-user ACLs that the profile folder passes down
  are the trust boundary. Symlink, file type, link count, size and
  change-during-read checks still apply. Windows has no `O_NOFOLLOW`, so the API
  billing reader rejects a link with `lstat` before opening the file and then
  requires the opened file to have the same file ID.
- **CLI discovery and spawning.** MeterUsage searches the npm global folder,
  `~/.cargo/bin`, `~/.bun/bin` (OpenCode only), `~/.local/bin` and `PATH`, which
  is split on `;`, unquoted and matched without regard to case. Like Windows,
  it searches folder by folder, preferring `.exe` over a `.cmd`/`.bat` shim in
  the same folder. On Windows every spawned binary and searched folder must be a
  drive-letter or UNC path: a macOS path such as `/bin/ps` would otherwise
  resolve to `C:\bin\ps.exe`, a folder any local account can create. Node refuses to spawn
  shims without a shell, so a shim runs through the fixed
  `%SystemRoot%\System32\cmd.exe /d /s /c` only when the shim path and every
  argument contain no `"`, `%`, `!`, `^` or line breaks and no argument ends in
  a backslash. Any other argument fails with a fixed error. Every spawn hides
  its console window. Timeouts and cancellation end the whole process tree with
  `taskkill /t /f`, so a shim cannot leave its CLI running. If `taskkill`
  fails, MeterUsage ends the direct child and releases its pipes so the request
  still settles.
- **Desktop connections.** Claude Desktop, Grok Bot Desktop and Antigravity
  Desktop connections use macOS-only helpers (Keychain, `ps`, `sandbox-exec`).
  Windows shows them as unsupported and refuses to connect until Windows
  readers exist. API billing hides **Use saved key**, a legacy macOS Keychain
  item; the one-time Admin key works. Codex connection is offered. Codex
  passes quoted keyring configuration arguments, so it currently needs a native
  `codex.exe`; an npm shim cannot run it. [ADR 0040](0040-windows-desktop-connections.md)
  adds Windows readers for these connections and runs npm shims through node
  directly.
- **Shell.** Windows uses the colored app icon in the notification area, with
  usage in its tooltip. The wide text tray image needs a macOS status item and
  is not rendered on Windows. The flyout anchors to the taskbar edge. Clicking
  the tray icon while the flyout is open closes it. **Copy card image** puts the
  rendered card on the clipboard because Windows has no native share sheet.
  Settings has no default Electron menu bar. Notifications use the AppUserModelID
  `dev.meterusage.app`.
- **Updates.** Until the Windows updater lands, Windows builds make no release
  check and offer no installation. [ADR 0039](0039-windows-updater.md)
  replaces this with a digest-verified installer updater.

## What CI proves and what it does not

The Windows job runs typecheck, the test suite minus files whose fixtures are
POSIX-only, Windows-only tests (real NTFS, `cmd.exe` shim, process-tree and
Claude transcript-path checks), the production build, an
unsigned `electron-builder --win` package, and a smoke run of the packaged
`MeterUsage.exe`. In the smoke run:

- headless `json` with a synthetic demo profile and with the runner's real
  (empty) profile exits cleanly and prints a valid schema-1 report;
- a demo GUI launch keeps running with a visible window, and a relaunch of the
  same profile with onboarding complete shows the usage flyout and side notch
  window;
- screenshots are uploaded as workflow artifacts for human review.

CI does **not** prove: real provider accounts or CLIs; desktop connections
against real Claude Desktop, Grok Bot, Cursor or Antigravity installs; DPAPI with
real user keys; installer, uninstaller, upgrade or relaunch behavior;
SmartScreen; login items; notifications reaching the Action Center;
multi-monitor, high-DPI or taskbar-position behavior; tray clicks, keyboard
or screen-reader use; sleep and resume; or behavior on Windows 10, ARM64 or
domain-managed machines. Release notes must list these as unverified until
someone tests them on a real Windows machine.

The full test suite also runs on the runner for information only. Many
existing tests assume POSIX permissions, symlinks or `/tmp` paths and are not
yet portable; a failure there does not fail the job.

## Consequences

- Windows support claims stay limited to what the CI job records.
- macOS behavior is unchanged: the same defaults domain, data folder, checks,
  tray image and updater.
- Unsigned builds trigger SmartScreen warnings. Release notes must say so.
- Linux remains unsupported for the desktop shell.
