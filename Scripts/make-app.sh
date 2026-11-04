#!/usr/bin/env bash
#
# Prepares dist/MeterUsage.app from a verified prebuilt release.
#
# This script never compiles the app and keeps the published signature
# unchanged. The frozen legacy Swift source build lives in
# legacy/swift/Scripts/make-app.sh.
#
# Usage:  ./Scripts/make-app.sh
# Output: dist/MeterUsage.app

set -euo pipefail

if [ "$#" -eq 1 ] && [ "$1" = --build-from-source ]; then
    echo "error: --build-from-source moved to ./legacy/swift/Scripts/make-app.sh (legacy Swift only)." >&2
    exit 2
fi
if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 2
fi

APP_NAME="MeterUsage"
EXECUTABLE="meterusage"

# Resolve paths relative to the repo, never to the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"

[ "$(uname -s)" = Darwin ] || {
    echo "error: MeterUsage requires macOS." >&2
    exit 1
}
OS_VERSION="$(sw_vers -productVersion)"
[ "${OS_VERSION%%.*}" -ge 13 ] || {
    echo "error: MeterUsage requires macOS 13 or later." >&2
    exit 1
}
if [ "$(uname -m)" != arm64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != 1 ]; then
    echo "error: The prebuilt release requires an Apple silicon Mac." >&2
    exit 1
fi

# Pin the reviewed release and digest together; never fall back to a build.
RELEASE_VERSION="0.3.0-beta.18"
RELEASE_SHA256="030ca8726e8ca032489fdcf4fc1eabcb10faa7737ba71325e4c89134dce700e3"
RELEASE_URL="https://github.com/tilorahdotco/meterusage/releases/download/v${RELEASE_VERSION}/MeterUsage-${RELEASE_VERSION}-mac-arm64.zip"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meterusage-download.XXXXXX")"
STAGING_DIR=""
trap 'rm -rf "${TEMP_DIR}" "${STAGING_DIR:-}"' EXIT
ARCHIVE="${TEMP_DIR}/MeterUsage.zip"
DOWNLOADED_APP="${TEMP_DIR}/unpacked/${APP_NAME}.app"

echo "==> Downloading MeterUsage ${RELEASE_VERSION} (no Swift required)"
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 120 "${RELEASE_URL}" -o "${ARCHIVE}"
printf '%s  %s\n' "${RELEASE_SHA256}" "${ARCHIVE}" | shasum -a 256 -c -
ditto -x -k "${ARCHIVE}" "${TEMP_DIR}/unpacked"
[ -x "${DOWNLOADED_APP}/Contents/MacOS/${EXECUTABLE}" ] || {
    echo "error: The download does not contain an executable MeterUsage.app." >&2
    exit 1
}
codesign --verify --deep --strict "${DOWNLOADED_APP}"

# Finish copying and verifying on the destination filesystem first.
mkdir -p "${DIST_DIR}"
STAGING_DIR="$(mktemp -d "${DIST_DIR}/.meterusage-stage.XXXXXX")"
STAGED_APP="${STAGING_DIR}/${APP_NAME}.app"
ditto "${DOWNLOADED_APP}" "${STAGED_APP}"
codesign --verify --deep --strict "${STAGED_APP}"
rm -rf "${APP_DIR}"
mv "${STAGED_APP}" "${APP_DIR}"
echo "Prepared ${APP_DIR}. Drag it to Applications to install."
echo "First launch: right-click > Open, or allow it in System Settings > Privacy & Security."
