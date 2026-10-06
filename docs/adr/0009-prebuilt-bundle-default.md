# ADR 0009: Prepare the prebuilt app by default

- Status: Accepted
- Date: 2026-10-06

## Context

Users and installation agents run `Scripts/make-app.sh` after cloning the
repository. That command previously compiled the app, so installation required
Swift and could fail in the user's local toolchain.

## Decision

Run `Scripts/make-app.sh` without arguments to download the published prebuilt
app and prepare `dist/MeterUsage.app`. Require `--build-from-source` to compile
the checkout. Preserve source builds for contributor validation.

Pin the public release version and SHA-256 together in the script. Verify the
download and code signature, then copy and verify the bundle in staging on the
destination filesystem before replacing generated output. Use macOS tools
without a package manager, credentials, or developer-tool installation. Reject
unsupported platforms and report download or verification failures without a
compiler fallback.

When updating the supported release, update the pinned version and digest from
the verified published asset, update the README's direct download links, and
exercise the default preparation path again.

## Verification

Test default preparation with Swift unavailable, explicit source selection,
invalid arguments, unsupported platforms, and failed download, checksum,
bundle, signature, or destination-copy checks. Download, copy, and verification
failures must preserve existing generated output and remove staging files.
Run these synthetic cases through `swift test` as
well as the standalone shell test.
Also download the real pinned asset on macOS, verify its prepared bundle, and
execute its synthetic demo JSON path without compiler access.

Preparing `dist/MeterUsage.app` does not install it, launch the GUI, or prove
Gatekeeper acceptance. Verify those states separately when requested.
