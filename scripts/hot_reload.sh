#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Hot reload changes Sorty's dependency graph, compiler flags, and ABI. Sharing
# SwiftPM outputs with normal builds can leave InjectionLite code in `make now`.
BUILD_DIR="${SORTY_HOT_BUILD_DIR:-${BUILD_DIR}-hot-reload}"
HOT_RELOAD_LOG_DIR="${BUILD_LOG_DIR:-${WORKSPACE_BUILD_DIR}/logs}"
HOT_RELOAD_COMMAND_DIR="${BUILD_DIR}/hot-reload/commands"
HOT_RELOAD_APP="${RELEASE_DIR}/${PROJECT_NAME}.app"
HOT_RELOAD_PREPARER="${BUILD_DIR}/debug/SortyHotReloadPreparer"
HOT_RELOAD_PLIST="/tmp/InjectionLite_Sorty_macOS_builds.plist"

run_hot_reload_command() {
    local log_name="$1"
    shift

    local log_file="${HOT_RELOAD_LOG_DIR}/${log_name}.log"
    if "$@" >"${log_file}" 2>&1; then
        return 0
    fi

    log_failure "${log_name} failed"
    log_item "Last 40 log lines (${log_file}):"
    tail -n 40 "${log_file}" || true
    return 1
}

run_hot_reload_build() {
    local log_name="$1"
    run_hot_reload_command "${log_name}" env \
        SORTY_BUILD_DIR="${BUILD_DIR}" \
        SORTY_HOT_RELOAD=true \
        SORTY_EMBEDDED_BUILD=true \
        APP_ICON_VARIANT=debug \
        SKIP_TESTS=true \
        BUILD_CONFIG=debug \
        "${SCRIPT_DIR}/build.sh"
}

print_runtime_success() {
    printf '\r  %b%s %s%b\r\n' "${GREEN}" "${SYM_CHECK}" "$1" "${NC}"
}

print_runtime_warning() {
    printf '\r  %b! %s%b\r\n' "${YELLOW}" "$1" "${NC}"
}

print_runtime_item() {
    printf '\r  • %s\r\n' "$1"
}

print_runtime_line() {
    printf '\r%s\r\n' "$1"
}

format_hot_reload_runtime_output() {
    local skips_spotlight_continuation=false
    local line

    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        line="${line#🔥 }"
        case "${line}" in
            *"InjectionLite: Watching for source changes"*)
                print_runtime_success "Watching Sorty and ~/Library for source changes"
                ;;
            "NotificationManager: Using native macOS notifications")
                print_runtime_success "Native notifications ready"
                ;;
            *"failed to scan "*"Watch with Sorty.workflow: -10811"*)
                print_runtime_warning "Spotlight could not index Watch with Sorty.workflow (-10811)"
                skips_spotlight_continuation=true
                ;;
            *"from spotlight"*)
                if [ "${skips_spotlight_continuation}" = "true" ]; then
                    skips_spotlight_continuation=false
                else
                    print_runtime_line "${line}"
                fi
                ;;
            *"⚡ Compiled in "*)
                line="${line#*⚡ }"
                print_runtime_success "${line}"
                ;;
            *"⚠️ Size of type "*" changed from "*)
                line="${line#*⚠️ }"
                print_runtime_warning "${line}"
                ;;
            *"⚠️ Size of a type changed over injection"*"blocked"*)
                print_runtime_warning "Type layout changed. Quit this session and rebuild with make hot."
                ;;
            *"⚠️ Logs dir not initialised."*)
                print_runtime_warning "Compile log is not ready. Edit a file and rebuild."
                ;;
            *"⚠️ Could not locate command for "*)
                local source_path="${line#*⚠️ Could not locate command for }"
                source_path="${source_path%%. Try editing*}"
                source_path="${source_path//\\/}"
                print_runtime_warning "No compile command for ${source_path##*/}"
                print_runtime_item "Edit the file and rebuild. Whole Module mode is unsupported."
                ;;
            "⚠️ "*)
                print_runtime_warning "${line#⚠️ }"
                ;;
            "⚠ "*)
                print_runtime_warning "${line#⚠ }"
                ;;
            "⚡ "*)
                print_runtime_success "${line#⚡ }"
                ;;
            *)
                skips_spotlight_continuation=false
                if [ -n "${line}" ]; then
                    print_runtime_line "${line}"
                fi
                ;;
        esac
    done
}

stream_hot_reload_frames() {
    local buffer=""
    local character=""

    while IFS= read -r -n 1 character; do
        if [ -z "${character}" ] || [ "${character}" = $'\r' ]; then
            if [ -n "${buffer}" ]; then
                printf '%s\n' "${buffer}"
                buffer=""
            fi
        elif [ "${character}" = $'\b' ]; then
            buffer="${buffer%?}"
        elif [ "${character}" != $'\004' ]; then
            buffer+="${character}"
        fi
    done

    if [ -n "${buffer}" ]; then
        printf '%s\n' "${buffer}"
    fi
}

print_header "${PROJECT_NAME} Hot Reload" 50
print_summary "Session" \
    "Version" "$(get_version) ($(get_build_number))" \
    "Config" "debug/spm" \
    "Output" "${HOT_RELOAD_APP}"

mkdir -p "${HOT_RELOAD_LOG_DIR}"

print_step 1 4 "Preparing Runtime"
run_hot_reload_command "hot_reload_runtime" \
    swift build \
        --scratch-path "${BUILD_DIR}" \
        --disable-dependency-cache \
        -c debug \
        --product SortyHotReloadPreparer \
        --disable-sandbox
log_success "Runtime ready"

print_step 2 4 "Recording Compile Commands"
run_hot_reload_build "hot_reload_initial_build"
"${HOT_RELOAD_PREPARER}" "${BUILD_DIR}" >"${HOT_RELOAD_LOG_DIR}/hot_reload_objects.log"
log_success "Compile commands recorded"

print_step 3 4 "Relinking App"
run_hot_reload_build "hot_reload_relink"
swift "${SCRIPT_DIR}/prepare_hot_reload.swift" \
    "${PROJECT_DIR}" \
    "${HOT_RELOAD_COMMAND_DIR}" \
    "${HOT_RELOAD_PLIST}" \
    >"${HOT_RELOAD_LOG_DIR}/hot_reload_commands.log"
log_success "App ready for hot reload"

print_step 4 4 "Watching Source Files"
log_success "Hot reload active. Quit Sorty or press Control-C to stop."
echo ""

runtime_status=0
script -q /dev/null env \
    INJECTION_DIRECTORIES="${PROJECT_DIR},${HOME}/Library" \
    "${HOT_RELOAD_APP}/Contents/MacOS/${PROJECT_NAME}" 2>&1 |
    stream_hot_reload_frames |
    format_hot_reload_runtime_output || runtime_status=$?

if [ "${runtime_status}" -ne 0 ]; then
    log_failure "Hot reload session ended unexpectedly (status ${runtime_status})."
    log_item "Check Sorty's crash report in Console. Run make hot to start a fresh process."
    exit "${runtime_status}"
fi
