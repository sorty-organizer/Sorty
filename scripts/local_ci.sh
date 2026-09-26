#!/bin/bash
#
# Sorty Local CI
# ==============
# Runs the same checks as the GitHub Actions CI workflow (swift.yml)
# locally on your machine for faster feedback.
#
# Usage:
#   ./scripts/local_ci.sh [options]
#
# Options:
#   --report           Report result to GitHub as a commit status (requires `gh` CLI)
#   --skip-security    Skip gitleaks security scan
#   --skip-tests       Skip unit tests (build-only check)
#   --verbose          Show full command output
#   --help             Show this help message
#
# The script mirrors the CI pipeline:
#   1. Security scan (gitleaks)
#   2. SPM build (swift build)
#   3. Unit tests (swift test --parallel)
#   4. App bundle build (scripts/build.sh)
#
# If --report is passed and any step fails, a "failure" commit status is
# posted to GitHub for the current HEAD, so the PR shows it as a failed check.
# On success, a "success" status is posted for visibility only. Blacksmith
# GitHub Actions still run as the PR and release gate.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Configuration
# ============================================================================

REPORT_TO_GITHUB=false
SKIP_SECURITY=false
SKIP_TESTS=false
VERBOSE=false

STEPS_PASSED=0
STEPS_FAILED=0
TOTAL_STEPS=0
FAILED_STEP=""

CI_CONTEXT="local-ci"
CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

# ============================================================================
# Argument Parsing
# ============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --report)
            REPORT_TO_GITHUB=true
            shift
            ;;
        --skip-security)
            SKIP_SECURITY=true
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            head -28 "$0" | tail -24
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage information."
            exit 1
            ;;
    esac
done

# ============================================================================
# Helpers
# ============================================================================

run_step() {
    local step_name="$1"
    shift
    ((TOTAL_STEPS++))

    echo ""
    echo -e "${BLUE}━━━ Step ${TOTAL_STEPS}: ${step_name} ━━━${NC}"

    local step_start=$(date +%s)

    if [ "$VERBOSE" = true ]; then
        if "$@"; then
            local step_end=$(date +%s)
            echo -e "  ${GREEN}${SYM_CHECK} ${step_name}${NC} ($(( step_end - step_start ))s)"
            ((STEPS_PASSED++))
            return 0
        else
            local step_end=$(date +%s)
            echo -e "  ${RED}${SYM_CROSS} ${step_name}${NC} ($(( step_end - step_start ))s)"
            ((STEPS_FAILED++))
            FAILED_STEP="$step_name"
            return 1
        fi
    else
        local log_file=$(mktemp)
        if "$@" > "$log_file" 2>&1; then
            local step_end=$(date +%s)
            echo -e "  ${GREEN}${SYM_CHECK} ${step_name}${NC} ($(( step_end - step_start ))s)"
            ((STEPS_PASSED++))
            rm -f "$log_file"
            return 0
        else
            local step_end=$(date +%s)
            echo -e "  ${RED}${SYM_CROSS} ${step_name}${NC} ($(( step_end - step_start ))s)"
            echo ""
            echo -e "${RED}Output (last 30 lines):${NC}"
            tail -30 "$log_file"
            ((STEPS_FAILED++))
            FAILED_STEP="$step_name"
            rm -f "$log_file"
            return 1
        fi
    fi
}

report_status() {
    local state="$1"   # success | failure | pending
    local description="$2"

    if [ "$REPORT_TO_GITHUB" != true ]; then
        return 0
    fi

    if ! command -v gh &> /dev/null; then
        echo -e "${YELLOW}${SYM_WARN} Cannot report to GitHub: 'gh' CLI not installed${NC}"
        echo -e "  Install with: brew install gh"
        return 0
    fi

    local sha
    sha=$(git rev-parse HEAD 2>/dev/null)
    if [ -z "$sha" ]; then
        echo -e "${YELLOW}${SYM_WARN} Cannot report to GitHub: not a git repository${NC}"
        return 0
    fi

    # Detect repo from git remote
    local repo
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
    if [ -z "$repo" ]; then
        echo -e "${YELLOW}${SYM_WARN} Cannot report to GitHub: unable to detect repository${NC}"
        return 0
    fi

    echo -e "  ${BLUE}→ Reporting '${state}' to GitHub for ${sha:0:7}...${NC}"
    gh api \
        --method POST \
        "/repos/${repo}/statuses/${sha}" \
        -f state="${state}" \
        -f description="${description}" \
        -f context="${CI_CONTEXT}" \
        > /dev/null 2>&1 || echo -e "${YELLOW}${SYM_WARN} Failed to report status to GitHub${NC}"
}

# ============================================================================
# CI Steps (mirrors .github/workflows/swift.yml)
# ============================================================================

step_security() {
    if [ "$SKIP_SECURITY" = true ]; then
        echo -e "  ${BLUE}○${NC} Security scan (skipped)"
        return 0
    fi

    if ! command -v gitleaks &> /dev/null; then
        echo -e "  ${YELLOW}${SYM_WARN} gitleaks not installed — skipping security scan${NC}"
        echo -e "  Install with: brew install gitleaks"
        return 0
    fi

    cd "$PROJECT_DIR"
    gitleaks detect --source . --no-banner
}

step_build() {
    cd "$PROJECT_DIR"
    swift build --scratch-path "$BUILD_DIR" --disable-dependency-cache --disable-index-store --disable-sandbox -j "$CORES"
}

step_test() {
    if [ "$SKIP_TESTS" = true ]; then
        echo -e "  ${BLUE}○${NC} Unit tests (skipped)"
        return 0
    fi

    cd "$PROJECT_DIR"
    swift test --scratch-path "$BUILD_DIR" --disable-dependency-cache --disable-index-store --disable-sandbox --parallel -j "$CORES"
}

step_app_build() {
    cd "$PROJECT_DIR"
    SKIP_TESTS=true \
    SKIP_GIT_INJECT=true \
    BUILD_CONFIG=debug \
    APP_ICON_VARIANT=ci \
    SORTY_BUILD_DIR="${BUILD_DIR}" \
    BUILD_FLAGS="--disable-index-store -j ${CORES}" \
    ./scripts/build.sh
}

# ============================================================================
# Main
# ============================================================================

main() {
    print_header "Sorty Local CI" 60

    echo -e "Configuration:"
    echo -e "  • Cores:         ${CORES}"
    echo -e "  • Security:      $([ "$SKIP_SECURITY" = true ] && echo "skip" || echo "enabled")"
    echo -e "  • Tests:         $([ "$SKIP_TESTS" = true ] && echo "skip" || echo "enabled")"
    echo -e "  • Report:        $([ "$REPORT_TO_GITHUB" = true ] && echo "yes (→ GitHub)" || echo "no")"
    echo -e "  • Commit:        $(git rev-parse --short HEAD 2>/dev/null || echo "N/A")"

    local ci_start=$(date +%s)

    # Report pending status
    report_status "pending" "Local CI running..."

    # Step 1: Security scan (mirrors security-checks job)
    local failed=false
    run_step "Security Scan (gitleaks)" step_security || failed=true

    # Step 2: SPM build (mirrors build-and-test "Build & Test" step)
    if [ "$failed" = false ]; then
        run_step "SPM Build (swift build)" step_build || failed=true
    fi

    # Step 3: Unit tests (mirrors build-and-test "Build & Test" step)
    if [ "$failed" = false ]; then
        run_step "Unit Tests (swift test)" step_test || failed=true
    fi

    # Step 4: App bundle build (mirrors build-and-test "Build app via script" step)
    if [ "$failed" = false ]; then
        run_step "App Bundle Build (build.sh)" step_app_build || failed=true
    fi

    # ================================================================
    # Summary
    # ================================================================
    local ci_end=$(date +%s)
    local ci_duration=$(( ci_end - ci_start ))

    echo ""
    print_divider "═" 60
    echo ""

    if [ "$failed" = true ]; then
        echo -e "  ${RED}${SYM_CROSS} LOCAL CI FAILED${NC}  (${ci_duration}s)"
        echo -e "  ${RED}Failed at: ${FAILED_STEP}${NC}"
        echo ""
        echo -e "  ${STEPS_PASSED} passed, ${STEPS_FAILED} failed out of ${TOTAL_STEPS} steps"
        report_status "failure" "Local CI failed: ${FAILED_STEP}"
    else
        echo -e "  ${GREEN}${SYM_CHECK} LOCAL CI PASSED${NC}  (${ci_duration}s)"
        echo ""
        echo -e "  ${STEPS_PASSED} passed out of ${TOTAL_STEPS} steps"
        report_status "success" "Local CI passed (${ci_duration}s)"
    fi

    echo ""
    print_divider "═" 60
    echo ""

    if [ "$failed" = true ]; then
        exit 1
    fi
}

main "$@"
