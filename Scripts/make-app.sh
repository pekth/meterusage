#!/usr/bin/env bash
#
# Assembles dist/MeterUsage.app from a release build.
#
# Deliberately requires nothing but Xcode's command line tools: no Apple
# Developer account, no team id, no provisioning profile. The bundle is ad-hoc
# signed (`codesign -s -`), which is enough for macOS to run it locally and is
# reproducible for any contributor.
#
# Usage:  ./Scripts/make-app.sh
# Output: dist/MeterUsage.app

set -euo pipefail

APP_NAME="MeterUsage"
EXECUTABLE="meterusage"

# Resolve paths relative to the repo, never to the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
INFO_PLIST_SRC="${ROOT_DIR}/Resources/Info.plist"

command -v swift >/dev/null 2>&1 || {
    echo "error: swift not found. Install Xcode or the Command Line Tools." >&2
    exit 1
}

echo "==> Building release binary"
swift build -c release --package-path "${ROOT_DIR}"

BIN_PATH="$(swift build -c release --package-path "${ROOT_DIR}" --show-bin-path)/${EXECUTABLE}"
[ -x "${BIN_PATH}" ] || {
    echo "error: built executable not found at ${BIN_PATH}" >&2
    exit 1
}

echo "==> Assembling ${APP_NAME}.app"
# Replace rather than merge: a stale executable inside a rebuilt bundle is a
# genuinely confusing failure to debug.
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"
cp "${INFO_PLIST_SRC}" "${APP_DIR}/Contents/Info.plist"

# Classic 8-byte package signature. Harmless, and some tooling still looks.
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# The icon is committed, so a checkout without it means something is wrong —
# a bad merge, a partial clone, a stray `rm`. Fail loudly: silently shipping a
# generic-icon bundle is the kind of regression nobody files a bug about.
# `Info.plist` already declares `CFBundleIconFile`, so this only copies.
if [ ! -f "${ROOT_DIR}/Resources/AppIcon.icns" ]; then
    echo "error: Resources/AppIcon.icns is missing." >&2
    echo "       Regenerate it with ./Scripts/make-icon.sh" >&2
    exit 1
fi
cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing"
# `-s -` is the ad-hoc identity: no certificate, no team, nothing machine
# specific baked into the bundle.
codesign --force --deep --sign - --timestamp=none "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Contents/Info.plist")"

echo
echo "Built ${APP_NAME} ${VERSION}"
echo "  ${APP_DIR}"
echo
echo "Run it:      open '${APP_DIR}'"
echo "Install it:  cp -R '${APP_DIR}' /Applications/"
echo
echo "Note: ad-hoc signed builds are not notarized. The first launch may need"
echo "      right-click > Open, or an allow in System Settings > Privacy & Security."
