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

# Every input is checked BEFORE anything is built or wiped. A check placed
# down beside the step that uses it still fails correctly, but it fails after
# `rm -rf` has already replaced the previous bundle with a half-assembled,
# unsigned one — which then looks installable and isn't.
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

WIDGET_PROJECT="${ROOT_DIR}/MeterUsageWidget.xcodeproj"

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
    cp "${ROOT_DIR}/Resources/${LOGO}" "${APP_DIR}/Contents/Resources/${LOGO}"
done

# Classic 8-byte package signature. Harmless, and some tooling still looks.
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> Building widget extension"
# The WidgetKit extension MUST be built by Xcode, not hand-wrapped from a
# SwiftPM executable: Xcode's app-extension target applies linker and
# entry-point setup that ExtensionKit requires at load time. A hand-wrapped
# SwiftPM binary registers with pluginkit but crashes on launch with
# "Unrecognized extension type" and is silently dropped from the widget
# gallery (verified 2026-08-24; see Sources/MeterUsageWidget).
APPEX_DIR="${APP_DIR}/Contents/PlugIns/MeterUsageWidget.appex"
WIDGET_BUILD_DIR="${ROOT_DIR}/.build/xcode-widget"
if [ -d "${WIDGET_PROJECT}" ] && command -v xcodebuild >/dev/null 2>&1; then
    WIDGET_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Contents/Info.plist")"
    # Bump past the app's build number: WidgetKit and chronod cache widget
    # metadata per bundle-id + version, and a reused version keeps serving
    # stale descriptors (this bit us when the widget target changed shape).
    WIDGET_BUILD="$(($( /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_DIR}/Contents/Info.plist") + 100))"
    xcodebuild \
        -project "${WIDGET_PROJECT}" \
        -target MeterUsageWidget \
        -configuration Release \
        MARKETING_VERSION="${WIDGET_VERSION}" \
        CURRENT_PROJECT_VERSION="${WIDGET_BUILD}" \
        CONFIGURATION_BUILD_DIR="${WIDGET_BUILD_DIR}" \
        CODE_SIGNING_ALLOWED=NO \
        build >/dev/null
    if [ -d "${WIDGET_BUILD_DIR}/MeterUsageWidget.appex" ]; then
        mkdir -p "${APP_DIR}/Contents/PlugIns"
        cp -R "${WIDGET_BUILD_DIR}/MeterUsageWidget.appex" "${APPEX_DIR}"
        # The AppIntents extractor leaves the legacy mangledTypeName empty on
        # this toolchain (only the V2 name is filled). The runtime resolves
        # intent types for parameter decode through the legacy name, so an
        # empty value makes every parameter arrive nil — the widget then
        # ignores its own Edit-sheet selection. Patch V2 over it.
        python3 - "${APPEX_DIR}/Contents/Resources/Metadata.appintents/extract.actionsdata" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
changed = False
for action in d.get('actions', {}).values():
    if not action.get('mangledTypeName') and action.get('mangledTypeNameV2'):
        action['mangledTypeName'] = action['mangledTypeNameV2']
        changed = True
if changed:
    with open(path, 'w') as f:
        json.dump(d, f)
    print('patched empty mangledTypeName entries')
PY
    else
        echo "warning: xcodebuild produced no appex; building without the widget extension." >&2
    fi
else
    echo "warning: ${WIDGET_PROJECT##*/} or xcodebuild not found; building without the widget extension." >&2
fi

# Presence was checked up top, before anything was wiped. `Info.plist` already
# declares `CFBundleIconFile`, so this only copies.
cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# App Intents metadata: the system's Edit-Widget sheet for the configurable
# widget is driven from indexed AppIntents metadata. Embedding the extension's
# metadata bundle in the app as well matches what full Xcode projects ship,
# and lsregister (run after install) is what makes the index actually refresh.
if [ -d "${APPEX_DIR}/Contents/Resources/Metadata.appintents" ]; then
    cp -R "${APPEX_DIR}/Contents/Resources/Metadata.appintents" "${APP_DIR}/Contents/Resources/Metadata.appintents"
fi

echo "==> Ad-hoc signing"
# Sign the widget extension FIRST, with its entitlements (sandbox + app
# group — the system refuses to load an unsandboxed widget provider). The
# outer app is then signed without --deep: deep signing would re-sign the
# nested appex and strip those entitlements.
ENTITLEMENTS_SRC="${ROOT_DIR}/Resources/MeterUsageWidget.entitlements"
if [ -d "${APPEX_DIR}" ]; then
    codesign --force --sign - --timestamp=none --entitlements "${ENTITLEMENTS_SRC}" "${APPEX_DIR}"
    codesign --verify --strict "${APPEX_DIR}"
fi
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
