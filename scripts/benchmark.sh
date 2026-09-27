#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# NOTE: This measures raw `swift build/test` (compile+link only), not the full
# `make dev` pipeline (bundle assembly, resources, signing). Flags below mirror
# the Makefile fast loop (same scratch path, -j, index-store setting) so the
# numbers track `make dev` compile time; bundle/signing overhead is excluded
# deliberately for a stable compile-only signal.
CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
PARALLEL_FLAGS="-j ${CORES}"
SWIFT_DEBUG_FLAGS="--disable-sandbox --disable-index-store"
SWIFT_RELEASE_FLAGS="--disable-sandbox --disable-index-store"
# Same product `make dev` builds: measuring the whole package would include
# SortyQuality and test targets that the dev loop never compiles.
BENCH_PRODUCT="--product SortyApp"
BENCH_TEST_FLAGS="--parallel"

# File to touch for incremental build
INCREMENTAL_FILE="Sources/SortyLib/Views/ContentView.swift"

# Output file
RESULTS_FILE="${WORKSPACE_BUILD_DIR}/benchmark-results.json"

# Parse arguments
COMPARE_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --compare)
            COMPARE_FILE="$2"
            shift 2
            ;;
        --compare=*)
            COMPARE_FILE="${1#--compare=}"
            shift
            ;;
        *)
            echo "Usage: $0 [--compare <previous-results.json>]"
            exit 1
            ;;
    esac
done

# High-resolution timer using perl (sub-second precision)
now_ms() {
    perl -MTime::HiRes=time -e 'printf "%.3f\n", time'
}

elapsed_seconds() {
    local start=$1
    local end=$2
    perl -e "printf '%.2f', $end - $start"
}

format_duration() {
    local seconds=$1
    local mins
    mins=$(perl -e "use POSIX; print floor($seconds / 60)")
    local secs
    secs=$(perl -e "printf '%.2f', $seconds - $mins * 60")
    if [ "$mins" -gt 0 ]; then
        echo "${mins}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

# ─── Begin ───

print_header "Sorty Build Benchmark" 50

HOSTNAME_STR=$(hostname -s 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_REF=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
SWIFT_VERSION=$(swift --version 2>/dev/null | head -1)

print_summary "Environment" \
    "Host" "${HOSTNAME_STR}" \
    "Cores" "${CORES}" \
    "Swift" "${SWIFT_VERSION}" \
    "Git" "${GIT_BRANCH}@${GIT_REF}" \
    "Timestamp" "${TIMESTAMP}"

mkdir -p "${BUILD_DIR}"

TOTAL_STEPS=4

# Arrays to collect results
declare -a SCENARIO_NAMES
declare -a SCENARIO_DURATIONS
declare -a SCENARIO_STATUSES

run_scenario() {
    local step_num=$1
    local name=$2
    local description=$3
    shift 3

    print_step "$step_num" "$TOTAL_STEPS" "$description"
    local start
    start=$(now_ms)
    local status="success"

    if "$@" > /dev/null 2>&1; then
        log_success "$description"
    else
        log_failure "$description"
        status="failure"
    fi

    local end
    end=$(now_ms)
    local duration
    duration=$(elapsed_seconds "$start" "$end")
    local formatted
    formatted=$(format_duration "$duration")
    log_item "Duration: ${formatted}"

    SCENARIO_NAMES+=("$name")
    SCENARIO_DURATIONS+=("$duration")
    SCENARIO_STATUSES+=("$status")
}

# ─── Scenario 1: Clean debug build ───

clean_debug_build() {
    swift package --scratch-path "${BUILD_DIR}" clean 2>/dev/null || true
    rm -rf "${BUILD_DIR}/debug" 2>/dev/null || true
    # shellcheck disable=SC2086
    swift build --scratch-path "${BUILD_DIR}" -c debug ${PARALLEL_FLAGS} ${SWIFT_DEBUG_FLAGS} ${BENCH_PRODUCT}
}

run_scenario 1 "clean_debug" "Clean debug build" clean_debug_build

# ─── Scenario 2: Incremental single-file build ───

incremental_build() {
    touch "${PROJECT_DIR}/${INCREMENTAL_FILE}"
    # shellcheck disable=SC2086
    swift build --scratch-path "${BUILD_DIR}" -c debug ${PARALLEL_FLAGS} ${SWIFT_DEBUG_FLAGS} ${BENCH_PRODUCT}
}

run_scenario 2 "incremental" "Incremental build (touch ${INCREMENTAL_FILE})" incremental_build

# ─── Scenario 3: Full test build+run ───

test_build_run() {
    # shellcheck disable=SC2086
    swift test --scratch-path "${BUILD_DIR}" ${PARALLEL_FLAGS} ${BENCH_TEST_FLAGS} ${SWIFT_DEBUG_FLAGS}
}

run_scenario 3 "test" "Full test build + run" test_build_run

# ─── Scenario 4: Release build ───

release_build() {
    # shellcheck disable=SC2086
    swift build --scratch-path "${BUILD_DIR}" -c release ${PARALLEL_FLAGS} ${SWIFT_RELEASE_FLAGS} ${BENCH_PRODUCT}
}

run_scenario 4 "release" "Release build" release_build

# ─── Results ───

echo ""
print_header "Benchmark Results" 50

printf "  ${BLUE}%-25s  %-12s  %-8s${NC}\n" "Scenario" "Duration" "Status"
print_divider "─" 50
for i in "${!SCENARIO_NAMES[@]}"; do
    local_name="${SCENARIO_NAMES[$i]}"
    local_dur="${SCENARIO_DURATIONS[$i]}"
    local_status="${SCENARIO_STATUSES[$i]}"
    local_formatted=$(format_duration "$local_dur")

    if [ "$local_status" = "success" ]; then
        status_color="${GREEN}"
    else
        status_color="${RED}"
    fi
    printf "  %-25s  %-12s  ${status_color}%-8s${NC}\n" "$local_name" "$local_formatted" "$local_status"
done
echo ""

TOTAL_DUR=$(get_total_duration)
log_item "Total benchmark time: ${TOTAL_DUR}"

# ─── Write JSON ───

# Build JSON manually (no jq dependency)
JSON="{"
JSON+="\"timestamp\":\"${TIMESTAMP}\","
JSON+="\"git_ref\":\"${GIT_REF}\","
JSON+="\"git_branch\":\"${GIT_BRANCH}\","
JSON+="\"hostname\":\"${HOSTNAME_STR}\","
JSON+="\"cores\":${CORES},"
JSON+="\"swift_version\":\"${SWIFT_VERSION}\","
JSON+="\"scenarios\":{"

for i in "${!SCENARIO_NAMES[@]}"; do
    if [ "$i" -gt 0 ]; then
        JSON+=","
    fi
    JSON+="\"${SCENARIO_NAMES[$i]}\":{\"duration_seconds\":${SCENARIO_DURATIONS[$i]},\"status\":\"${SCENARIO_STATUSES[$i]}\"}"
done

JSON+="}}"

echo "$JSON" > "${RESULTS_FILE}"
log_success "Results saved to ${RESULTS_FILE}"

# ─── Compare (optional) ───

if [ -n "${COMPARE_FILE}" ]; then
    echo ""
    print_header "Comparison" 50

    if [ ! -f "${COMPARE_FILE}" ]; then
        log_failure "Comparison file not found: ${COMPARE_FILE}"
        exit 1
    fi

    printf "  ${BLUE}%-25s  %-12s  %-12s  %-10s${NC}\n" "Scenario" "Previous" "Current" "Delta"
    print_divider "─" 60

    for i in "${!SCENARIO_NAMES[@]}"; do
        local_name="${SCENARIO_NAMES[$i]}"
        local_dur="${SCENARIO_DURATIONS[$i]}"

        # Extract previous duration from JSON using grep+sed (no jq dependency)
        prev_dur=$(grep -o "\"${local_name}\":{\"duration_seconds\":[0-9.]*" "${COMPARE_FILE}" 2>/dev/null \
            | grep -o '[0-9.]*$' || echo "")

        if [ -z "$prev_dur" ]; then
            printf "  %-25s  %-12s  %-12s  %-10s\n" "$local_name" "n/a" "$(format_duration "$local_dur")" "n/a"
            continue
        fi

        delta=$(perl -e "printf '%.2f', $local_dur - $prev_dur")
        pct=$(perl -e "if ($prev_dur > 0) { printf '%+.1f%%', (($local_dur - $prev_dur) / $prev_dur) * 100 } else { print 'n/a' }")

        # Color: green if faster (negative delta), red if slower, yellow if same
        if perl -e "exit($local_dur < $prev_dur ? 0 : 1)"; then
            delta_color="${GREEN}"
        elif perl -e "exit($local_dur > $prev_dur ? 0 : 1)"; then
            delta_color="${RED}"
        else
            delta_color="${YELLOW}"
        fi

        printf "  %-25s  %-12s  %-12s  ${delta_color}%-10s${NC}\n" \
            "$local_name" \
            "$(format_duration "$prev_dur")" \
            "$(format_duration "$local_dur")" \
            "${delta}s (${pct})"
    done
    echo ""
fi

echo ""
log_success "Benchmark complete"
