#!/usr/bin/env bash
#
# Builds the frozen legacy Swift app into legacy/swift/dist/MeterUsage.app.
#
# Recovery and reference only. The supported app is Electron; install it with
# ./Scripts/make-app.sh from the repository root. This script needs Swift and
# Xcode Command Line Tools and signs ad hoc.
#
# Usage:  ./legacy/swift/Scripts/make-app.sh
# Output: legacy/swift/dist/MeterUsage.app

set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 2
fi

APP_NAME="MeterUsage"
EXECUTABLE="meterusage"

# Resolve paths relative to the repo, never to the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${PACKAGE_DIR}/../.." && pwd)"
SHARED_RESOURCES="${ROOT_DIR}/Resources"
DIST_DIR="${PACKAGE_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
INFO_PLIST_SRC="${PACKAGE_DIR}/Resources/Info.plist"

command -v swift >/dev/null 2>&1 || {
    echo "error: swift not found. Install Xcode or the Command Line Tools." >&2
    exit 1
}

# Every input is checked BEFORE anything is built or wiped.
ICON_SRC="${SHARED_RESOURCES}/AppIcon.icns"
if [ ! -f "${ICON_SRC}" ]; then
    echo "error: Resources/AppIcon.icns is missing." >&2
    echo "       Regenerate it with ./Scripts/make-icon.sh" >&2
    exit 1
fi

echo "==> Building legacy Swift release binary"
swift build -c release --package-path "${PACKAGE_DIR}"

BIN_PATH="$(swift build -c release --package-path "${PACKAGE_DIR}" --show-bin-path)/${EXECUTABLE}"
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

# The provider marks used in the menu bar and settings preview. Drawn as
# template images so they can be tinted by status/headroom at render time.
for LOGO in codex-logo.png grok-logo.png opencode-logo.png antigravity-logo.png; do
    if [ -f "${SHARED_RESOURCES}/${LOGO}" ]; then
        cp "${SHARED_RESOURCES}/${LOGO}" "${APP_DIR}/Contents/Resources/${LOGO}"
    fi
done

# Classic 8-byte package signature. Harmless, and some tooling still looks.
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# App icon
cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
if [ -f "${SHARED_RESOURCES}/AppIcon.png" ]; then
    cp "${SHARED_RESOURCES}/AppIcon.png" "${APP_DIR}/Contents/Resources/AppIcon.png"
fi

echo "==> Ad-hoc signing"
# `-s -` is the ad-hoc identity: no certificate, no team, nothing machine
# specific baked into the bundle.
codesign --force --sign - --timestamp=none "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Contents/Info.plist")"

echo
echo "Built legacy Swift ${APP_NAME} ${VERSION}"
echo "  ${APP_DIR}"
echo
echo "Run it:      open '${APP_DIR}'"
echo
echo "Note: ad-hoc signed builds are not notarized. The first launch may need"
echo "      right-click > Open, or an allow in System Settings > Privacy & Security."
