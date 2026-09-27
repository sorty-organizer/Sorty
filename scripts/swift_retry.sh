#!/bin/bash
# Resilient `swift` runner for direct invocations (tests, quality runs).
# Uses how code is used: `make test` shells straight to `swift test`, so it
# never passes through build.sh's recovery. This wrapper runs the command,
# and on Clang module-cache poisoning clears the cache and retries once
# serially. Usage: swift_retry.sh <log-name> <swift> <args...>
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/build_cache.sh
source "${SCRIPT_DIR}/build_cache.sh"

BUILD_LOG_DIR="${BUILD_LOG_DIR:-${WORKSPACE_BUILD_DIR}/logs}"
SORTY_VERBOSE="${SORTY_VERBOSE:-${VERBOSE:-false}}"

LOG_NAME="$1"
shift
STARTED_AT="$(date +%s)"

mkdir -p "${BUILD_LOG_DIR}"
LOG_FILE="${BUILD_LOG_DIR}/${LOG_NAME}.log"

run_logged() {
    if is_truthy "${SORTY_VERBOSE}"; then
        "$@" 2>&1 | tee "${LOG_FILE}"
        return "${PIPESTATUS[0]}"
    fi
    if "$@" >"${LOG_FILE}" 2>&1; then
        return 0
    fi
    return 1
}

if run_logged "$@"; then
    exit 0
fi

if ! swiftpm_module_cache_poison_detected "${LOG_NAME}" "${STARTED_AT}"; then
    log_failure "${LOG_NAME} failed"
    tail -n "${BUILD_TAIL_LINES:-40}" "${LOG_FILE}" || true
    exit 1
fi

log_warning "Clang module cache looks poisoned; clearing it and retrying once serially."
reset_clang_module_caches
SERIAL_ARGS=()
while IFS= read -r arg; do
    SERIAL_ARGS+=("${arg}")
done < <(strip_parallel_job_flags "$@")
SERIAL_ARGS+=(-j 1)

if run_logged "${SERIAL_ARGS[@]}"; then
    exit 0
fi

log_failure "${LOG_NAME} failed on serial retry"
tail -n "${BUILD_TAIL_LINES:-40}" "${LOG_FILE}" || true
exit 1
