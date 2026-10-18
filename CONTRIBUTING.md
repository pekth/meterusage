# Contributing to meterusage

> ### Quick start
> 1. Fork & clone the repo.
> 2. Enable pre-commit hook: `git config core.hooksPath .githooks`
> 3. For Electron, use the declared Node/pnpm versions, then run
>    `pnpm install --frozen-lockfile`, `pnpm typecheck`, `pnpm test` and `pnpm build`.
> 4. Keep diffs focused, zero secrets or credentials, synthetic fixtures only.


Fork the repository, make one focused change, run the checks below, and open a
pull request.

## Edition routing

New features target the [Electron implementation](docs/electron/README.md).
The [legacy Swift app](docs/swift/README.md) is frozen for new features and kept
for critical maintenance, transition compatibility and rollback. Both source
trees remain until the [retirement conditions](docs/adr/0024-electron-primary-swift-retirement.md#retirement-conditions)
pass. Validate both affected paths when a shared contract changes.
`Scripts/make-app.sh` prepares the published Swift app by default and never
builds Electron. Isolated demo/test profiles are required for candidate QA;
shared normal profiles do not support safe side-by-side use.

## Before you start

Electron development uses the Node and pnpm versions declared in `package.json`.
Follow [the Electron commands](#typescript-electron-candidate). Electron's macOS
packaging still needs Swift for its Keychain helper and asset exporter.

The published app is a macOS 13+ Swift menu-bar app. A TypeScript/Electron
candidate is under development; see the candidate commands below. The package uses Swift tools
version 5.9 and has no third-party package dependencies. Swift source builds need Xcode Command Line Tools:

```sh
xcode-select --install
```

Provider CLIs and account access are optional. Unit tests must run without a
signed-in provider or a live account.

## Fork and create a branch

1. Fork `https://github.com/pekth/meterusage` on GitHub.
2. Clone your fork and enter the checkout:

   ```sh
   git clone https://github.com/YOUR_GITHUB_USER/meterusage.git
   cd meterusage
   ```

3. Enable the repository pre-commit hook:

   ```sh
   git config core.hooksPath .githooks
   ```

4. Create a branch with a short name that describes the change:

   ```sh
   git switch -c add-provider-setting
   ```

Keep the branch focused. Do not include unrelated formatting or generated
files.

## Keep your fork current

Add the main repository as `upstream` once:

```sh
git remote add upstream https://github.com/pekth/meterusage.git
```

Before new work, update your branch and resolve conflicts locally:

```sh
git fetch upstream
git rebase upstream/main
```

After a rebase, rerun checks affected by changed inputs and refresh independent
review. Reuse matching checks for unchanged artifacts and inputs.

## Commit messages

Keep each commit small. Start with a short imperative line, for example:

```text
Add OpenRouter balance display
```

Do not mix unrelated fixes in the same commit.

<a id="build-and-test"></a>
## Legacy Swift build and test

GitHub Actions runs `swift build` and `swift test` on macOS 15 for pushes to
`main` and pull requests. Repository owners must enable Actions under
Settings > Actions > General for these checks to run.

For Swift source changes, run these checks before a pull request:

```sh
swift build
swift test
./Scripts/make-app.sh --build-from-source
```

`make-app.sh` downloads a prebuilt release by default, without Swift. Always
pass `--build-from-source` when validating your source changes. Test the script's
download and failure paths with `bash Tests/Scripts/make-app-tests.sh`; those
tests use synthetic tools and bundles without network or compiler access.

Use demo mode to inspect the real UI without provider credentials:

```sh
METERUSAGE_DEMO=1 swift run meterusage
```

Demo data is synthetic. Use it for screenshots and manual checks.

For a UI-affecting change, exercise the affected path and record what was
inspected. Automated tests, release builds, and code-sign verification do not
prove runtime UI behavior. Report untested paths explicitly. For release
acceptance, check the popover, Settings, relaunch persistence, and offline or
retry behavior only when the change can affect them.

For a side notch layout or motion change, capture the panel for at least two
providers whose cards differ in height, confirm the top edge and the strip do
not move, and include the captures in the pull request. See
[`docs/SIDE-NOTCH.md`](docs/SIDE-NOTCH.md) and
[`docs/adr/0004`](docs/adr/0004-side-notch-anchor-invariant.md).

See [`docs/DEMO.md`](docs/DEMO.md) for the data and privacy rules.

## TypeScript Electron candidate

The source manifest retains 0.2.41. The public Electron beta is 0.3.0-beta.3,
build 61, with the version explicitly set during packaging. See the
[beta guide](docs/BETA.md) for the signed artifact, known cosmetic footer issue
and incomplete native acceptance, and the [Electron guide](docs/electron/README.md)
for source choices and parity gaps.


Use the Node and pnpm versions declared in `package.json`. Provider accounts
are optional; synthetic tests and demo mode require no login. Shared checks
can run on Linux. macOS packaging, system symbol export and native acceptance
require macOS with the existing Swift and signing tools. The Windows source
candidate uses `pnpm package:win` to produce unsigned x64 NSIS and portable
executables. Its workflow is configured for typecheck, focused tests, packaging
and an isolated packaged-demo/single-instance smoke check; no completed
workflow receipt is claimed here. Native Windows UI/provider checks, installer
acceptance and signing remain open. See [ADR 0033](docs/adr/0033-windows-desktop-candidate.md).

`pnpm package:mac` also compiles the fixed Claude Desktop Keychain helper and
bundles it as an app resource. `pnpm build:desktop-helper` targets arm64 and
macOS 13 explicitly, matching the candidate bundle. Verify the packaged helper's
architecture and deployment target with `file` and `vtool -show-build` on macOS.
The same build command prepares an unpackaged native candidate. Do not invoke the helper during synthetic
QA; it reads an actual Keychain item. Desktop connections are disabled in demo
mode. Live connection acceptance remains separate from source checks.

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
meterusage_demo_root="$(node -p 'require("node:fs").realpathSync(require("node:os").tmpdir())')"
node dist/main/cli.cjs json --force --demo --candidate-profile "$meterusage_demo_root/meterusage-cli-demo"
```

The candidate profile must be an empty test directory on first use. It may be
reused for relaunch checks after the candidate creates its marker. All demo
preferences, caches, history and Electron state stay in that profile.
Use the canonical temporary root above. On macOS, `/tmp` and `/var` can be
symlink aliases; candidate mode rejects paths that follow a symlink.

On macOS, build and launch a separate candidate without installing it:

```sh
pnpm package:mac
./release/mac-arm64/MeterUsage.app/Contents/MacOS/meterusage --demo --candidate-profile /private/tmp/meterusage-native-demo
```

`package:mac` exports the existing SF Symbol stand-ins, builds the app and
packages an Apple silicon ZIP with publication disabled. It does not install
or replace an app. Locally packaged output is not the verified public beta
artifact. Keep the stable release and beta download routes separate.
Windows packaging and a CI workflow are implemented in the candidate source.
They do not establish successful CI, native acceptance, signing or a release.
See the [platform pipeline](docs/plans/feature-and-windows-pipeline.md).

electron-builder resolves `pnpm` from PATH when collecting production
dependencies. If an existing launcher incorrectly loads a standalone pnpm
executable as JavaScript, verify the executable directly, then put a `pnpm`
symlink to it in a separate candidate-local directory at the start of PATH.
Keep host launchers and installed dependencies unchanged. This PATH correction
still requires a new native packaging check.

Changes live in `src/domain/` (shared calculations), `src/main/` (provider
readers, persistence, coordination and native shell), `src/shared/` (IPC DTOs),
`src/renderer/` (React UI) and `tests/` (synthetic fixtures). Provider paths,
credentials and raw responses must stay out of renderer imports. Settings may
show a reduced directory label chosen by the user.

TypeScript tests and builds do not prove native parity. Before cutover, record
candidate identity/digest/signature, headless JSON, launch and relaunch,
settings/account isolation, offline failures, notification/login behavior,
sharing and updater paths. Capture two different-height provider cards on
macOS and confirm the top edge and strip stay fixed. Use only synthetic reset
credits. Keep the published app and its data untouched during candidate QA.
Retained Swift sources are the behavior oracle and rollback path. Run affected
Swift checks when those inputs change; reuse matching receipts otherwise.

See [ADR 0010](docs/adr/0010-macos-typescript-electron.md) and
[the migration plan](docs/plans/macos-electron-migration-plan.md).

## Where to make changes

New providers and data sources belong in Electron. Use the `src/` and `tests/`
map in [Electron development](#typescript-electron-candidate).

### Legacy Swift maintenance

Use these paths only for critical fixes, transition compatibility and rollback:

- `Sources/MeterUsage/Services/` contains provider readers, pricing, and
  service-status sources.
- `Sources/MeterUsage/Core/` contains coordination and saved preferences.
- `Sources/MeterUsage/Views/` contains the SwiftUI menu-bar interface.
- `Tests/MeterUsageTests/` contains unit tests and synthetic fixtures.

When maintaining a legacy provider or data source, use the existing `QuotaSource`,
`UsageSource`, `LocalActivitySource`, or `StatusSource` contract in
`Sources/MeterUsage/Services/DataSource.swift`. Keep provider failures isolated
so one unavailable provider does not hide the others. Add or update the model,
coordinator, settings, and tests only when the maintenance change needs them.

### Shared contribution rules

New providers must have synthetic demo data and tests. Normal tests and
screenshots must not require a live login.

Update `README.md` or the relevant document under `docs/` when a feature changes
setup, provider behavior, privacy boundaries, or user-visible output.

For fixture data, use `testuser` or `example` in paths and invent all other
values. Do not copy real transcripts, API responses, account identifiers, or
credentials into tests, screenshots, issues, or pull requests.

## Privacy and security

meterusage reads local provider data and, for some providers, calls documented
aggregate usage endpoints. Read [`docs/PRIVACY.md`](docs/PRIVACY.md) before
changing a data source or adding logging. That document defines the project
boundary: do not display or log tokens, account identifiers, hostnames, absolute
user paths, or raw transcripts.

The pre-commit hook scans staged changes for credential-shaped data and personal
paths. If it blocks a commit, remove the sensitive content and check the diff.
Do not bypass the hook until you have confirmed that a match is a false
positive.

## Generated assets

Run `./Scripts/make-icon.sh` only when the icon design changes. Build the legacy
Swift app bundle with `./Scripts/make-app.sh --build-from-source`. For Electron
packaging, follow [Electron development](#typescript-electron-candidate).
Generated output under `dist/` and `release/` is ignored and should not be
force-added.

## Pull requests

A pull request should include:

- the user-visible change and why it is needed;
- the files or provider paths affected;
- the exact checks you ran, including the affected Swift or TypeScript checks;
- any privacy, network, or credential-handling impact; and
- demo-mode screenshots when a UI change needs visual review, plus captured
  side notch frames when the change touches panel layout or motion.

Keep screenshots in demo mode so they contain no real account data. Preserve
the MIT license and do not claim affiliation with Anthropic or OpenAI.

## Reporting a problem

Use GitHub Issues for bugs and feature ideas. Include the macOS version, the
meterusage version or commit, the provider involved, and a short reproduction.
Redact credentials and personal paths. Describe a live credential by its type
and location only; never paste it.
