# Agent and contributor guidance

Use this file with [`CONTRIBUTING.md`](CONTRIBUTING.md) when working on the
public repository.

## Installing for users

- When asked to install MeterUsage, use the prebuilt app ZIP described in
  [`README.md`](README.md). From a Git checkout or source archive, run
  `./Scripts/make-app.sh` to download and verify it in `dist/MeterUsage.app`,
  then install that bundle within the user's requested scope.
- Installation does not require Node, Swift or Xcode Command Line Tools. Do
  not install developer tools for app installation. `Scripts/make-app.sh`
  never compiles the app.
- If the prebuilt download, checksum, signature, or platform check fails,
  report that error. Do not fall back to compiling the app.
- Verify the installed bundle and running app separately. Preparing a bundle
  in `dist/` is not proof of installation or launch.

## Project rules

- Keep changes focused and explain user-visible behavior in the pull request.
- Run `pnpm typecheck`, `pnpm test` and `pnpm build` before submitting code
  changes. Report the actual validation host.
- The Swift app is frozen under [`legacy/swift/`](legacy/swift/README.md) for
  recovery and reference. Do not add features there. Only a change inside
  `legacy/swift/` needs `swift build --package-path legacy/swift` and
  `swift test --package-path legacy/swift`, run on macOS 13 or later (over SSH
  when developing on Linux). CI does not build it.
- During release work, verify each requested state separately: tested source,
  built and signed bundle, installed and running app, Git tag, published GitHub
  Release, uploaded asset, and manual runtime checks. Do not infer one state
  from another. `Scripts/make-app.sh` does not install the app, and a Git tag
  does not create a GitHub Release.
- Use synthetic fixtures and demo data only. Never commit credentials, private
  keys, real account data, raw transcripts, or personal absolute paths.
- Read [`docs/PRIVACY.md`](docs/PRIVACY.md) before changing data sources,
  logging, or provider integrations.
- For side notch layout or motion changes, capture the panel for two providers
  whose cards differ in height, and confirm the top edge and the strip do not
  move before release. See [`docs/adr/0004`](docs/adr/0004-side-notch-anchor-invariant.md).
- Update `README.md` or the relevant file under `docs/` when behavior or setup
  changes.

## Docs

- Facts and known gaps: [`docs/KB.md`](docs/KB.md). Decisions: [`docs/adr/`](docs/adr/README.md). Update them in the same change when a documented fact or decision changes.
- Keep public docs free of credentials, personal data, private repository references, and absolute local paths.
- Issue forms in `.github/ISSUE_TEMPLATE/` apply the `bug`, `feature`, and `chore` labels.
