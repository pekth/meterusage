# ADR 0012: Isolate live Codex validation in the existing UI

- Status: Accepted implementation direction; native UI acceptance pending
- Date: 2026-10-09

## Decision

Add `--codex-test-profile` for an isolated live Codex candidate. This amends
ADR 0010's demo-only restriction for candidate profiles. Keep the existing UI,
IPC, coordinator and Codex browser connection. No separate test application
stands in for visible account allowance.

Require an absolute test directory, refuse protected or symlink paths, and
reject conflicts with demo flags. Preferences use profile JSON instead of
installed macOS defaults. App data and Electron state use the test directory;
OS home remains unchanged for Keychain and helper discovery.

Start disconnected. Compose only an account-bound Codex allowance source.
Do not read local activity or other providers, fall back to legacy sources,
request status feeds, redeem resets or send model prompts. The official helper
owns keyring authentication under the existing connection policy. Normal quit
retains a completed connection for relaunch and inspection.

Block candidate update checks and installation, login-item changes and
notifications even if stored preferences enable them. Normal and demo modes
retain their existing collection behavior. This decision adds no end-user
terminal step to primary setup.

## Acceptance

Synthetic tests cover isolation and rejected inputs. Native proof requires
launching the packaged candidate, human browser sign-in and real allowance in
the app UI. Provider-dashboard accuracy and cross-device coverage require
separate checks. The Swift rollback, Windows hold, installed-app replacement
hold and release gates remain unchanged.
