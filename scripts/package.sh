#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/utils.sh"

print_header "Packaging Application" 50

# Ensure release directory exists
mkdir -p "${RELEASE_DIR}"

ZIP_NAME="${ZIP_NAME_OVERRIDE:-${PROJECT_NAME}.zip}"
ZIP_PATH="${RELEASE_DIR}/${ZIP_NAME}"
IAP_PATH="${APP_PATH}/Contents/Resources/InternetAccessPolicy.plist"
BACKGROUND_AGENT_PLIST="${APP_PATH}/Contents/Library/LaunchAgents/com.sorty.app.background-agent.plist"
BACKGROUND_AGENT_BUNDLE_PROGRAM="Contents/MacOS/Sorty"
BUILD_VARIANT=$(/usr/libexec/PlistBuddy -c "Print :SortyBuildVariant" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)
MAIN_EXECUTABLE="${APP_PATH}/Contents/MacOS/Sorty"

if [ "${BUILD_VARIANT}" = "debug" ]; then
    log_failure "Refusing to package a debug build; rebuild with APP_ICON_VARIANT=release and BUILD_CONFIG=release"
    exit 1
fi

if [ ! -f "${MAIN_EXECUTABLE}" ]; then
    log_failure "Main executable is missing at ${MAIN_EXECUTABLE}"
    exit 1
fi

# A stripped arm64 release executable is currently about 30 MB. Keep a
# generous per-architecture ceiling so normal growth is allowed while an
# accidentally unstripped build (about 71 MB per architecture) is rejected.
EXECUTABLE_SIZE=$(stat -f %z "${MAIN_EXECUTABLE}")
ARCH_COUNT=$(lipo -archs "${MAIN_EXECUTABLE}" 2>/dev/null | wc -w | tr -d ' ')
MAX_EXECUTABLE_SIZE=$((45 * 1024 * 1024 * ARCH_COUNT))
if [ "${EXECUTABLE_SIZE}" -gt "${MAX_EXECUTABLE_SIZE}" ]; then
    log_failure "Main executable is unexpectedly large ($(get_file_size "${MAIN_EXECUTABLE}")); release symbols may not have been stripped"
    exit 1
fi

# 1. Validate Internet Access Policy is bundled
print_step 1 5 "Validating Internet Access Policy"
if [ ! -f "${IAP_PATH}" ]; then
    log_failure "Missing InternetAccessPolicy.plist in app bundle at ${IAP_PATH}"
    exit 1
fi

if /usr/bin/plutil -lint "${IAP_PATH}" >/dev/null 2>&1; then
    log_success "InternetAccessPolicy.plist is bundled and valid"
else
    log_failure "InternetAccessPolicy.plist exists but is invalid"
    exit 1
fi

# 2. Validate background agent launch path before packaging.
print_step 2 5 "Validating Background Agent"
if [ ! -f "${BACKGROUND_AGENT_PLIST}" ]; then
    log_failure "Missing background agent plist at ${BACKGROUND_AGENT_PLIST}"
    exit 1
fi

AGENT_BUNDLE_PROGRAM=$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "${BACKGROUND_AGENT_PLIST}" 2>/dev/null || true)
if [ "${AGENT_BUNDLE_PROGRAM}" != "${BACKGROUND_AGENT_BUNDLE_PROGRAM}" ]; then
    log_failure "Background agent BundleProgram must be ${BACKGROUND_AGENT_BUNDLE_PROGRAM} (found ${AGENT_BUNDLE_PROGRAM:-<missing>})"
    exit 1
fi
log_success "Background agent launch path verified"

# 3. Validate embedded framework linkage before packaging.
print_step 3 5 "Validating App Linkage"
validate_sorty_app_linkage "${APP_PATH}"

# 4. Validate code signature before packaging.
print_step 4 5 "Validating Code Signature"
if codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null 2>&1; then
    log_success "Code signature verified"
else
    log_failure "Code signature is invalid; rebuild or re-sign ${APP_PATH} before packaging"
    exit 1
fi

# 5. Create ZIP
print_step 5 5 "Creating Application Archive (ZIP)"
start_step_timer "zip"
rm -f "${ZIP_PATH}"

if [ ! -d "${APP_PATH}" ]; then
    log_failure "App bundle not found at ${APP_PATH}"
    exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

if [ -f "${ZIP_PATH}" ]; then
    ZIP_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sorty-zip-check.XXXXXX")
    ditto -x -k "${ZIP_PATH}" "${ZIP_CHECK_DIR}"
    validate_sorty_app_linkage "${ZIP_CHECK_DIR}/${PROJECT_NAME}.app"
    codesign --verify --deep --strict --verbose=2 "${ZIP_CHECK_DIR}/${PROJECT_NAME}.app" >/dev/null
    rm -rf "${ZIP_CHECK_DIR}"
    log_success "Created ${ZIP_NAME} ($(get_file_size "${ZIP_PATH}"))"
else
    log_failure "ZIP creation failed"
fi

print_summary "Package Complete" \
    "ZIP" "${ZIP_PATH}" \
    "IAP" "${IAP_PATH}"
