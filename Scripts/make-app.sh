#!/usr/bin/env bash
#
# Prepares dist/MeterUsage.app from a verified prebuilt release by default.
#
# Contributors can opt into a source build with --build-from-source.
# Only that mode requires Swift and Xcode Command Line Tools and creates an
# ad-hoc signed build. The default downloads the notarized Developer ID app.
#
# Usage:  ./Scripts/make-app.sh
# Build:  ./Scripts/make-app.sh --build-from-source
# Output: dist/MeterUsage.app

set -euo pipefail

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --build-from-source ]; }; then
    echo "Usage: $0 [--build-from-source]" >&2
    exit 2
fi

APP_NAME="MeterUsage"
EXECUTABLE="meterusage"

# Resolve paths relative to the repo, never to the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
INFO_PLIST_SRC="${ROOT_DIR}/Resources/Info.plist"

if [ "$#" -eq 0 ]; then
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
    RELEASE_VERSION="0.2.41"
    RELEASE_SHA256="12acc43dc79506bc6cd7b2bcb27cabe67dd35bcbcab9f68458faa852869ed075"
    RELEASE_URL="https://github.com/pekth/meterusage/releases/download/v${RELEASE_VERSION}/MeterUsage-${RELEASE_VERSION}-notarized.zip"
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
    echo "Open MeterUsage.app from Applications. The prebuilt app is signed and notarized."
    exit 0
fi

command -v swift >/dev/null 2>&1 || {
    echo "error: swift not found. Install Xcode or the Command Line Tools." >&2
    exit 1
}

# Every input is checked BEFORE anything is built or wiped.
ICON_SRC="${ROOT_DIR}/Resources/AppIcon.icns"
if [ ! -f "${ICON_SRC}" ]; then
    echo "error: Resources/AppIcon.icns is missing." >&2
    echo "       Regenerate it with ./Scripts/make-icon.sh" >&2
    exit 1
fi

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

# The provider marks used in the menu bar and settings preview. Drawn as
# template images so they can be tinted by status/headroom at render time.
for LOGO in codex-logo.png grok-logo.png opencode-logo.png antigravity-logo.png; do
    if [ -f "${ROOT_DIR}/Resources/${LOGO}" ]; then
        cp "${ROOT_DIR}/Resources/${LOGO}" "${APP_DIR}/Contents/Resources/${LOGO}"
    fi
done

# Classic 8-byte package signature. Harmless, and some tooling still looks.
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# App icon
cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
if [ -f "${ROOT_DIR}/Resources/AppIcon.png" ]; then
    cp "${ROOT_DIR}/Resources/AppIcon.png" "${APP_DIR}/Contents/Resources/AppIcon.png"
fi

echo "==> Ad-hoc signing"
# `-s -` is the ad-hoc identity: no certificate, no team, nothing machine
# specific baked into the bundle.
codesign --force --sign - --timestamp=none "${APP_DIR}"
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
