#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MeterUsagePreview"
EXECUTABLE="meterusage"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
INFO_PLIST_SRC="${ROOT_DIR}/Resources/Info.plist"

echo "==> Building release binary in worktree"
swift build -c release --package-path "${ROOT_DIR}"

BIN_PATH="$(swift build -c release --package-path "${ROOT_DIR}" --show-bin-path)/${EXECUTABLE}"
[ -x "${BIN_PATH}" ] || {
    echo "error: built executable not found at ${BIN_PATH}" >&2
    exit 1
}

echo "==> Assembling ${APP_NAME}.app (Isolated Preview)"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"

# Copy provider logo assets
for LOGO in codex-logo.png grok-logo.png opencode-logo.png antigravity-logo.png; do
    if [ -f "${ROOT_DIR}/Resources/${LOGO}" ]; then
        cp "${ROOT_DIR}/Resources/${LOGO}" "${APP_DIR}/Contents/Resources/${LOGO}"
    fi
done

if [ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# Create isolated Info.plist with unique bundle ID and preview name
sed -e 's/dev\.meterusage\.app/dev.meterusage.app.preview/g' \
    -e 's/<string>MeterUsage<\/string>/<string>MeterUsage Preview<\/string>/g' \
    "${INFO_PLIST_SRC}" > "${APP_DIR}/Contents/Info.plist"

printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> Signing preview bundle"
codesign -s - --force --deep "${APP_DIR}"

echo "==> Built preview bundle successfully at: ${APP_DIR}"
