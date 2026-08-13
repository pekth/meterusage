#!/usr/bin/env bash
#
# Regenerates the app icon from source.
#
# The icon is not hand-drawn art: `make-icon.swift` renders it from the same
# geometry the menu-bar glyph uses (MeterGlyph in MenuBarLabel.swift), so the
# two stay the same object. Both the 1024x1024 master and the .icns are
# committed — this script only needs running when the design changes.
#
#   ./Scripts/make-icon.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="${ROOT_DIR}/Resources/AppIcon.png"
ICNS="${ROOT_DIR}/Resources/AppIcon.icns"
ICONSET="$(mktemp -d)/AppIcon.iconset"

echo "==> Rendering master"
swift "${ROOT_DIR}/Scripts/make-icon.swift" "${MASTER}"

echo "==> Building iconset"
mkdir -p "${ICONSET}"

# The 256px repo mark. Two committed copies stay in sync from the one master:
# assets/logo.png is the well-known path tools scan for a project logo (t3code
# and others auto-detect it), and docs/images/icon.png is what the README shows.
for LOGO in "${ROOT_DIR}/assets/logo.png" "${ROOT_DIR}/docs/images/icon.png"; do
    mkdir -p "$(dirname "${LOGO}")"
    sips -Z 256 "${MASTER}" --out "${LOGO}" >/dev/null
done
# The sizes `iconutil` expects. Each @2x is its @1x doubled, so both come from
# the same master rather than from each other.
for size in 16 32 128 256 512; do
    sips -Z "${size}" "${MASTER}" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    sips -Z "$((size * 2))" "${MASTER}" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "${ICONSET}" --output "${ICNS}"
rm -rf "$(dirname "${ICONSET}")"

echo
echo "Wrote ${ICNS}"
