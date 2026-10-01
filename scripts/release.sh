#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/utils.sh"

print_header "Starting Release Process" 60

# Default settings
SKIP_ALL_TESTS=false

# Argument Parsing
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --no-tests)
        SKIP_ALL_TESTS=true
        shift
        ;;
        *)
        echo "Unknown option: $1"
        echo "Usage: $0 [--no-tests]"
        exit 1
        ;;
    esac
done

if [ "$SKIP_ALL_TESTS" == "true" ]; then
    export SKIP_TESTS=true
    log_warn "⚠️  Skipping ALL tests at user request."
else
    # Configure build script environment
    export ENABLE_UI_TESTS=false
    # Unit tests run by default in build.sh unless SKIP_TESTS is set.
fi

# Release builds should always use the release icon unless explicitly overridden.
export APP_ICON_VARIANT="${APP_ICON_VARIANT:-release}"

# --- Step 1: Build & Test ---
"${SCRIPT_DIR}/build.sh"

# --- Step 2: Package ---
"${SCRIPT_DIR}/package.sh"
bash "${SCRIPT_DIR}/package-dmg.sh"

# --- Step 3: Notarize (Optional) ---
if [ -n "$NOTARIZATION_USERNAME" ] || [ -n "$KEYCHAIN_PROFILE" ]; then
    "${SCRIPT_DIR}/notarize.sh"
else
    log_item "Skipping notarization (no credentials found)"
fi

# --- Step 4: Appcast (Optional) ---
if [ -f "${SCRIPT_DIR}/generate_appcast.sh" ]; then
    "${SCRIPT_DIR}/generate_appcast.sh"
fi

echo ""
log_success "Release workflow completed successfully!"
echo "Artifacts are in: ${RELEASE_DIR}"
