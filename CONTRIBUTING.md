# Contributing to meterusage

> ### ⚡ TL;DR
> 1. Fork & clone the repo.
> 2. Enable pre-commit hook: `git config core.hooksPath .githooks`
> 3. Verify: `swift test` & `./Scripts/make-app.sh`
> 4. Keep diffs focused, zero secrets or credentials, synthetic fixtures only.


Fork the repository, make one focused change, run the checks below, and open a
pull request.

## Before you start

meterusage is a macOS 13+ Swift menu-bar app. The package uses Swift tools
version 5.9 and has no third-party package dependencies. Install Xcode Command
Line Tools before building:

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

Run the test commands again after a rebase.

## Commit messages

Keep each commit small. Start with a short imperative line, for example:

```text
Add OpenRouter balance display
```

Do not mix unrelated fixes in the same commit.

## Build and test

GitHub Actions runs `swift build` and `swift test` on macOS 15 for pushes to
`main` and pull requests. Repository owners must enable Actions under
Settings > Actions > General for these checks to run.

### Candidate verification

Before a code pull request, verify the candidate on macOS:

1. From the intended checkout, record `git rev-parse --show-toplevel`,
   `git rev-parse HEAD`, and `git status --short`. Match the revision to the
   candidate being reviewed. A clean checkout of the base revision is not
   proof of an uncommitted patch.
2. If files were copied from another checkout, compare their relative paths
   and SHA-256 hashes against a manifest made at the source checkout. Include
   new test files and confirm intended deletions are absent. Run
   `shasum -a 256 -c <manifest>` from the destination root before testing.
   A missing or mismatched input blocks validation; correct the copy first.
3. Run the commands below from that verified checkout. Record the exact test
   command, any filter, the executed test count, and the failure count. A
   successful exit with zero matching tests is not a pass. Check the relevant
   suite's summary: a separate empty Swift Testing run does not erase a
   nonzero XCTest result. For a new regression test, also show that it fails
   on the old implementation and passes on the candidate.

```sh
swift build
swift test
./Scripts/make-app.sh
```

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

### Verification record

Before reporting completion, give every requested stage a status of
`verified`, `failed`, `pending`, or `not performed`, with its evidence. Keep
unrequested stages out of scope. Building does not authorize installation or
publication, and `Scripts/make-app.sh` performs neither.

| Requested stage | Required evidence |
| --- | --- |
| Source and tests | Candidate revision, dirty-file comparison when needed, test command, executed count, failure count, and log. Reconcile the source again if it changes after testing. |
| Built bundle | Bundle identifier, version/build number, executable SHA-256, and signing verification result for the candidate bundle. |
| Running app | Executable path and PID of the launched candidate, its bundle identity, demo or normal mode, and the actual interaction result. A process alone proves only launch. |
| Installed app | Installed bundle identifier, version/build number, and executable hash matching the verified candidate; if launch was requested, confirm the running process uses that installed bundle. A separate preview does not prove the installed app changed. |
| Native UI | Evidence from the affected interaction. Side-notch changes need the two provider captures described above. Record an explicit capture waiver as a waiver, never as a visual pass. |
| Published release | Version and tag resolving to the verified source, a published GitHub Release, and a downloaded public asset whose SHA-256 matches the verified archive. Reconcile the changelog, README download information, and release notes with that version. |

Keep full paths and operational logs private; use sanitized identifiers and
repository-relative paths in public reports. A demo result covers synthetic
data only. If the requested normal-mode interaction was not tested, mark it
pending. See [`docs/DEMO.md`](docs/DEMO.md) for launch behavior.

When the test host becomes unavailable, name the last verified stage and the
next pending check. Resume from those results only if the candidate still
matches. Do not describe a partial build, installation, or release as complete.

## Where to make changes

- `Sources/MeterUsage/Services/` contains provider readers, pricing, and
  service-status sources.
- `Sources/MeterUsage/Core/` contains coordination and saved preferences.
- `Sources/MeterUsage/Views/` contains the SwiftUI menu-bar interface.
- `Tests/MeterUsageTests/` contains unit tests and synthetic fixtures.

When adding a provider or data source, use the existing `QuotaSource`,
`UsageSource`, `LocalActivitySource`, or `StatusSource` contract in
`Sources/MeterUsage/Services/DataSource.swift`. Keep provider failures isolated
so one unavailable provider does not hide the others. Add or update the model,
coordinator, settings, and tests only when the feature needs them.

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

Run `./Scripts/make-icon.sh` only when the icon design changes. The app bundle
is assembled by `./Scripts/make-app.sh`. Build output under `dist/` is ignored
and should not be force-added.

## Pull requests

A pull request should include:

- the user-visible change and why it is needed;
- the files or provider paths affected;
- the exact checks you ran, including `swift test`;
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
