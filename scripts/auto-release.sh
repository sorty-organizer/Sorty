#!/bin/bash
# Auto-release script - creates a new release with automatic version bumping
# Usage:
#   ./scripts/auto-release.sh              # Patch bump (1.0.0 -> 1.0.1)
#   ./scripts/auto-release.sh minor        # Minor bump (1.0.0 -> 1.1.0)
#   ./scripts/auto-release.sh major        # Major bump (1.0.0 -> 2.0.0)
#   ./scripts/auto-release.sh 1.2.3        # Specific version
#   ./scripts/auto-release.sh --dry-run    # Show what would happen

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/utils.sh"

# Parse arguments
DRY_RUN=false
BUMP_TYPE="patch"
SPECIFIC_VERSION=""

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        patch|minor|major)
            BUMP_TYPE="$arg"
            ;;
        [0-9]*.[0-9]*.[0-9]*)
            SPECIFIC_VERSION="$arg"
            ;;
        --help|-h)
            echo "Usage: $0 [patch|minor|major|VERSION] [--dry-run]"
            echo ""
            echo "Arguments:"
            echo "  patch       Increment patch version (default): 1.0.0 -> 1.0.1"
            echo "  minor       Increment minor version: 1.0.0 -> 1.1.0"
            echo "  major       Increment major version: 1.0.0 -> 2.0.0"
            echo "  VERSION     Set specific version (e.g., 1.2.3)"
            echo "  --dry-run   Show what would happen without making changes"
            exit 0
            ;;
    esac
done

# Get current version from Info.plist
INFOPLIST="${PROJECT_DIR}/Info.plist"
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFOPLIST" 2>/dev/null || echo "1.0.0")

# Calculate new version
calculate_new_version() {
    local current="$1"
    local bump_type="$2"
    
    # Split version into parts
    IFS='.' read -r major minor patch <<< "$current"
    major=${major:-0}
    minor=${minor:-0}
    patch=${patch:-0}
    
    case $bump_type in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
    esac
    
    echo "${major}.${minor}.${patch}"
}

if [ -n "$SPECIFIC_VERSION" ]; then
    NEW_VERSION="$SPECIFIC_VERSION"
else
    NEW_VERSION=$(calculate_new_version "$CURRENT_VERSION" "$BUMP_TYPE")
fi

print_header "Auto-Release" 50

print_summary "Release Configuration" \
    "Current Version" "$CURRENT_VERSION" \
    "New Version" "$NEW_VERSION" \
    "Bump Type" "${SPECIFIC_VERSION:+custom}${SPECIFIC_VERSION:-$BUMP_TYPE}" \
    "Dry Run" "$DRY_RUN"

if [ "$DRY_RUN" == "true" ]; then
    echo ""
    log_item "Dry run mode - no changes will be made"
    echo ""
    echo "Would perform the following steps:"
    echo "  1. Bump version: $CURRENT_VERSION -> $NEW_VERSION"
    echo "  2. Run tests"
    echo "  3. Build app"
    echo "  4. Create ZIP and DMG packages"
    echo "  5. Generate appcast"
    echo "  6. Commit version bump"
    echo "  7. Create tag v$NEW_VERSION"
    echo "  8. Push to origin"
    exit 0
fi

# Ensure clean working directory (warn but allow uncommitted changes)
if ! git diff --quiet HEAD 2>/dev/null; then
    log_warn "⚠️  You have uncommitted changes. These will be included in the release commit."
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 1: Prepare release (No mandatory file edits)
print_step 1 6 "Preparing release v${NEW_VERSION}"

# Update CHANGELOG if script exists
if [ -f "${SCRIPT_DIR}/update_changelog.sh" ]; then
    "${SCRIPT_DIR}/update_changelog.sh" "${NEW_VERSION}"
    log_success "Updated CHANGELOG.md"
fi

# Only bump version if user explicitly wants to update source files (optional)
if [[ "$*" == *"--update-source"* ]]; then
    "${SCRIPT_DIR}/bump_version.sh" "$NEW_VERSION"
else
    log_item "Source files will keep their current placeholders (bundle will be tagged dynamically)"
fi

# Step 2: Run tests
print_step 2 6 "Running tests"
if ! swift test --parallel; then
    log_failure "Tests failed. Aborting release."
    exit 1
fi
log_success "All tests passed"

# Step 3: Build
print_step 3 6 "Building application"
export SKIP_TESTS=true  # Already ran tests
export APP_ICON_VARIANT="${APP_ICON_VARIANT:-release}"
"${SCRIPT_DIR}/build.sh"

# Step 4: Package
print_step 4 6 "Creating release package"
"${SCRIPT_DIR}/package.sh"
bash "${SCRIPT_DIR}/package-dmg.sh"

# Step 5: Generate appcast (if script exists)
print_step 5 6 "Generating appcast"
if [ -f "${SCRIPT_DIR}/generate_appcast.sh" ]; then
    "${SCRIPT_DIR}/generate_appcast.sh" || log_item "Appcast generation skipped"
else
    log_item "No appcast script found, skipping"
fi

# Step 6: Commit and Tagging release
print_step 6 6 "Committing and Tagging release"

# 6a. Commit changes (Changelog, Version Bumps)
git add "${PROJECT_DIR}/CHANGELOG.md" 2>/dev/null || true
git add "${PROJECT_DIR}/Info.plist" 2>/dev/null || true
git add "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj/project.pbxproj" 2>/dev/null || true

if ! git diff --cached --quiet; then
    git commit -m "chore: release notes and version bump for v${NEW_VERSION}"
    log_success "Committed release changes"
else
    log_item "No changes to commit"
fi

# 6b. Create tag on the commit we just made
TAG_NAME="v${NEW_VERSION}"
if git tag -l | grep -q "^${TAG_NAME}$"; then
    log_warn "Tag ${TAG_NAME} already exists"
else
    git tag -a "${TAG_NAME}" -m "Release ${NEW_VERSION}"
    log_success "Created tag ${TAG_NAME}"
fi

echo ""
print_divider "═" 50
echo ""

print_summary "Release Complete ✨" \
    "Version" "$NEW_VERSION" \
    "Tag" "$TAG_NAME" \
    "ZIP" "${RELEASE_DIR}/Sorty.zip" \
    "DMG" "${RELEASE_DIR}/Sorty.dmg"

echo ""
echo "Next steps:"
echo "  1. Push the release:  git push origin main --tags"
echo "  2. Create GitHub release (optional)"
echo ""
echo "Or run: git push origin main --tags"
