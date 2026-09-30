#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [ ! -f "${APP_PATH}/Contents/MacOS/Sorty" ]; then
    echo "Release app missing. Build and package the release ZIP first." >&2
    exit 1
fi
BUILD_VARIANT=$(/usr/libexec/PlistBuddy -c 'Print :SortyBuildVariant' "${APP_PATH}/Contents/Info.plist")
if [ "${BUILD_VARIANT}" != "release" ]; then
    echo "DMG packaging requires a release app." >&2
    exit 1
fi
codesign --verify --deep --strict "${APP_PATH}"

# Keep Python dependencies and intermediate images out of the checkout.
DMG_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sorty-dmg.XXXXXX")
trap 'rm -rf "${DMG_WORK_DIR}"' EXIT
python3 -m venv "${DMG_WORK_DIR}/venv"
"${DMG_WORK_DIR}/venv/bin/python" -m pip install --disable-pip-version-check 'dmgbuild==1.6.7'

# The source is 928 × 1128; the Finder window uses half-sized logical pixels.
sips -z 564 464 "${PROJECT_DIR}/Assets/DMG/dmg-background.png" \
    --out "${DMG_WORK_DIR}/background.png" >/dev/null
"${DMG_WORK_DIR}/venv/bin/dmgbuild" \
    -s "${SCRIPT_DIR}/dmg-settings.py" \
    -D "app=${APP_PATH}" -D "background=${DMG_WORK_DIR}/background.png" \
    "Sorty" "${DMG_WORK_DIR}/Sorty.dmg"
hdiutil verify "${DMG_WORK_DIR}/Sorty.dmg"
mv -f "${DMG_WORK_DIR}/Sorty.dmg" "${RELEASE_DIR}/Sorty.dmg"
echo "Created ${RELEASE_DIR}/Sorty.dmg"
