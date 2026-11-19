#!/bin/bash
# Generate a signed Sparkle ZIP enclosure and an optional delta in CI.
# Usage: ./scripts/generate_appcast_ci.sh
# Requires: SPARKLE_PRIVATE_KEY environment variable (Sparkle private key from generate_keys)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/render_appcast.sh"

print_header "Generating Signed Appcast" 50

APPCAST_FILE="${APPCAST_FILE_OVERRIDE:-${RELEASE_DIR}/appcast.xml}"
ZIP_NAME="${ZIP_NAME_OVERRIDE:-${PROJECT_NAME}.zip}"
ZIP_PATH="${RELEASE_DIR}/${ZIP_NAME}"

if [ ! -f "$ZIP_PATH" ]; then
    log_failure "ZIP file not found at $ZIP_PATH"
    exit 1
fi

APP_PLIST="${RELEASE_DIR}/${PROJECT_NAME}.app/Contents/Info.plist"

# Prefer the merged release app's version/build so appcast metadata matches
# what validate_sparkle.sh reads from releases/Sorty.app.
if [ -f "${APP_PLIST}" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PLIST}" 2>/dev/null || true)
    BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PLIST}" 2>/dev/null || true)
    MINIMUM_SYSTEM_VERSION=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${APP_PLIST}" 2>/dev/null || true)
fi

VERSION="${APPCAST_VERSION:-${VERSION:-$(get_version)}}"
BUILD_NUM="${APPCAST_BUILD_NUM:-${BUILD_NUM:-$(get_build_number)}}"
DATE=$(date -R)
SIZE=$(stat -f%z "$ZIP_PATH")

# Get download URL from GitHub releases
REPOSITORY="${APPCAST_REPOSITORY:-${GITHUB_REPOSITORY:-shirishpothi/${PROJECT_NAME}}}"
RELEASE_TAG="${APPCAST_RELEASE_TAG:-v${VERSION}}"
RELEASE_URL="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}/${ZIP_NAME}"
RELEASE_NOTES_URL="${APPCAST_RELEASE_NOTES_URL:-https://github.com/${REPOSITORY}/releases/tag/${RELEASE_TAG}}"
APPCAST_ITEM_TITLE="${APPCAST_ITEM_TITLE:-Version ${VERSION}}"
APPCAST_CHANNEL="${APPCAST_CHANNEL:-}"
APPCAST_LINK="${APPCAST_LINK:-https://github.com/${REPOSITORY}}"

# Use the Sparkle tools from the same build that produced the app.
SIGN_UPDATE_TOOL=$(
    find \
        "${BUILD_DIR}/artifacts" \
        "${BUILD_DIR}/DerivedData/SourcePackages/artifacts" \
        "${WORKSPACE_BUILD_DIR}/artifacts" \
        "${WORKSPACE_BUILD_DIR}/DerivedData/SourcePackages/artifacts" \
        -name "sign_update" \
        -type f \
        -not -path "*/old_dsa_scripts/*" \
        2>/dev/null | head -1
)

if [ ! -x "$SIGN_UPDATE_TOOL" ] || [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
    log_failure "Appcast generation requires Sparkle sign_update and SPARKLE_PRIVATE_KEY."
    exit 1
fi

# Pass the key through stdin only to sign_update.
export -n SPARKLE_PRIVATE_KEY
sign_archive() {
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE_TOOL" --ed-key-file - -p "$1"
}

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${APP_PLIST}" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${PROJECT_DIR}/Info.plist")
if ! SIGNATURE=$(sign_archive "$ZIP_PATH") || [[ ! "$SIGNATURE" =~ ^[A-Za-z0-9+/]{86}==$ ]]; then
    log_failure "Could not sign update. Check that SPARKLE_PRIVATE_KEY matches SUPublicEDKey."
    exit 1
fi
ENCLOSURE_EXTRA_ATTR="sparkle:edSignature=\"$SIGNATURE\" length=\"$SIZE\""

generate_delta() (
    local binary_delta="${SIGN_UPDATE_TOOL%/*}/BinaryDelta"
    local work_dir old_app old_plist old_framework old_build framework_build
    local delta_name delta_path delta_size delta_signature old_sparkle_size differences

    [ -x "$binary_delta" ] || return 1
    work_dir=$(mktemp -d) || return 1
    trap 'rm -rf "$work_dir"' EXIT
    ditto -x -k "$APPCAST_DELTA_BASE_ZIP" "$work_dir/base" >&2 || return 1

    old_app="$work_dir/base/${PROJECT_NAME}.app"
    old_plist="$old_app/Contents/Info.plist"
    old_framework="$old_app/Contents/Frameworks/Sparkle.framework"
    old_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$old_plist") || return 1
    framework_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$old_framework/Resources/Info.plist") || return 1
    [[ "$old_build" =~ ^[0-9]+$ && "$BUILD_NUM" =~ ^[0-9]+$ && "$framework_build" =~ ^[0-9]+$ ]] || return 1
    # Sparkle build 2041 and later support version 4 delta archives.
    [ "$framework_build" -ge 2041 ] && [ "$old_build" -lt "$BUILD_NUM" ] || return 1
    [ "$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$old_plist")" = "$PUBLIC_KEY" ] || return 1
    [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$old_plist")" = "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PLIST")" ] || return 1
    codesign --verify --deep --strict "$old_app" >&2 || return 1

    delta_name="${PROJECT_NAME}-${BUILD_NUM}-from-${old_build}.delta"
    delta_path="$work_dir/$delta_name"
    "$binary_delta" create --version 4 "$old_app" "${APP_PLIST%/Contents/Info.plist}" "$delta_path" >&2 || return 1
    delta_size=$(stat -f%z "$delta_path") || return 1
    # Use Sparkle's size threshold so large patches use the full archive instead.
    [ "$delta_size" -gt 0 ] && [ "$delta_size" -le $((SIZE * 7 / 8)) ] || return 1

    "$binary_delta" apply "$old_app" "$work_dir/Patched.app" "$delta_path" >&2 || return 1
    codesign --verify --deep --strict "$work_dir/Patched.app" >&2 || return 1
    # Compare file contents, permissions, and symlinks without following the links.
    differences=$(/usr/bin/rsync -nrlpc --delete --itemize-changes \
        "${APP_PLIST%/Contents/Info.plist}/" "$work_dir/Patched.app/") || return 1
    # A delta may retain timestamps from the old bundle for unchanged files.
    differences=$(awk '$1 !~ /^\.[fdL]\.\.[tT]\.+$/' <<< "$differences") || return 1
    if [ -n "$differences" ]; then
        printf 'Reconstructed app differs from the release bundle:\n%s\n' "$differences" >&2
        return 1
    fi

    old_sparkle_size=$(stat -Lf%z "$old_framework/Sparkle") || return 1
    delta_signature=$(sign_archive "$delta_path") || return 1
    [[ "$delta_signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] || return 1
    mv "$delta_path" "$RELEASE_DIR/$delta_name" || return 1
    echo "Verified delta from build $old_build: $delta_size bytes ($SIZE bytes full)." >&2

    cat <<EOF
      <sparkle:deltas>
        <enclosure url="${RELEASE_URL%/*}/${delta_name}"
                   sparkle:version="${BUILD_NUM}"
                   sparkle:shortVersionString="${VERSION}"
                   sparkle:deltaFrom="${old_build}"
                   sparkle:deltaFromSparkleExecutableSize="${old_sparkle_size}"
                   sparkle:edSignature="${delta_signature}"
                   length="${delta_size}" type="application/octet-stream"/>
      </sparkle:deltas>
EOF
)

APPCAST_DELTAS_XML=""
if [ -f "${APPCAST_DELTA_BASE_ZIP:-}" ] && ! APPCAST_DELTAS_XML=$(generate_delta); then
    log_warning "No usable delta from the previous release. Offering the signed ZIP."
fi

render_appcast "${APPCAST_FILE}"

log_success "Generated signed appcast at ${APPCAST_FILE}"
log_item "Version: ${VERSION} (${BUILD_NUM})"
log_item "Download URL: ${RELEASE_URL}"
log_item "Size: ${SIZE} bytes"
