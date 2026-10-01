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

# Give Finder both 1x and 2x representations at the same logical size.
# A half-sized PNG alone gets enlarged and softens the gradient and dot field.
sips -s format tiff -z 564 464 -s dpiWidth 72 -s dpiHeight 72 \
    "${PROJECT_DIR}/Assets/DMG/dmg-background.png" \
    --out "${DMG_WORK_DIR}/background-1x.tiff" >/dev/null
sips -s format tiff -s dpiWidth 144 -s dpiHeight 144 \
    "${PROJECT_DIR}/Assets/DMG/dmg-background.png" \
    --out "${DMG_WORK_DIR}/background-2x.tiff" >/dev/null
tiffutil -cathidpicheck "${DMG_WORK_DIR}/background-1x.tiff" \
    "${DMG_WORK_DIR}/background-2x.tiff" -out "${DMG_WORK_DIR}/background.tiff"
"${DMG_WORK_DIR}/venv/bin/dmgbuild" \
    -s "${SCRIPT_DIR}/dmg-settings.py" \
    -D "app=${APP_PATH}" -D "background=${DMG_WORK_DIR}/background.tiff" \
    "Sorty" "${DMG_WORK_DIR}/Sorty.dmg"
hdiutil verify "${DMG_WORK_DIR}/Sorty.dmg"
mv -f "${DMG_WORK_DIR}/Sorty.dmg" "${RELEASE_DIR}/Sorty.dmg"
echo "Created ${RELEASE_DIR}/Sorty.dmg"
