# Sorty Makefile
# Optimized for build speed and performance

.PHONY: build run debug test test-fast test-full clean help install quick now daily hot dev build-profile cache-status cache-prune release friend-zip release-patch release-minor release-major prerelease rebuild build-ci-universal benchmark harness harness-accent quality-report ci ci-report

# Default target
all: build

# Auto-detect CPU cores for parallel builds
CORES := $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)
PARALLEL_FLAGS := -j $(CORES)
SORTY_BUILD_DIR ?= $(HOME)/Library/Caches/Sorty/build
SWIFTPM_SCRATCH_FLAG := --scratch-path "$(SORTY_BUILD_DIR)"
SWIFTPM_CACHE_FLAG := --disable-dependency-cache

# Package.swift owns compiler and linker settings so builds and tests share one
# incremental compilation signature instead of invalidating each other.
SWIFT_DEBUG_FLAGS := --disable-sandbox
SWIFT_RELEASE_FLAGS := --disable-sandbox
# Keep local app identity stable across rebuilds so macOS continues granting the
# replacement binary access to Keychain credentials created by the prior build.
FAST_LOOP_FLAGS := FAST_DEV_MODE=true ENABLE_FINDER_EXTENSION=true ENABLE_ADHOC_SIGNING=true ENABLE_SPARKLE_SIGNING=false PRESERVE_APP_BUNDLE=true SKIP_GIT_INJECT=true
VERBOSE ?= false
BUILD_SCRIPT_ENV := SORTY_VERBOSE=$(VERBOSE) SORTY_BUILD_DIR="$(SORTY_BUILD_DIR)"

# Disable index store for local debug builds (saves ~10-15% compile time)
export SWIFTPM_DISABLE_INDEXING ?= 1

build:
	@chmod +x scripts/build.sh
	@$(BUILD_SCRIPT_ENV) BUILD_FLAGS="$(PARALLEL_FLAGS)" ./scripts/build.sh

build-ci-universal:
	@echo "CI-style xcodebuild (universal)..."
	@chmod +x scripts/build.sh scripts/package.sh
	@$(BUILD_SCRIPT_ENV) BUILD_METHOD=xcodebuild SKIP_TESTS=true BUILD_ARCHS="arm64 x86_64" XCODE_EXTRA_FLAGS="COMPILER_INDEX_STORE_ENABLE=NO DEBUG_INFORMATION_FORMAT=dwarf ENABLE_CODE_COVERAGE=NO" ./scripts/build.sh
	@ZIP_NAME_OVERRIDE="Sorty-universal.zip" ./scripts/package.sh

run: build
	@echo "🚀 Launching Sorty..."
	@open releases/Sorty.app

# builds with debug symbols and verbose logging
debug:
	@echo "🛠️  Building in DEBUG mode with $(CORES) parallel jobs..."
	@$(BUILD_SCRIPT_ENV) APP_ICON_VARIANT=debug BUILD_CONFIG=debug BUILD_FLAGS="$(PARALLEL_FLAGS) $(SWIFT_DEBUG_FLAGS)" ./scripts/build.sh
	@echo "🚀 Launching Debug Build..."
	@open releases/Sorty.app

# Fastest development build - parallel, no tests, debug mode
dev:
	@echo "⚡ Fast development build ($(CORES) parallel jobs)..."
	@$(BUILD_SCRIPT_ENV) $(FAST_LOOP_FLAGS) APP_ICON_VARIANT=debug SKIP_TESTS=true BUILD_CONFIG=debug BUILD_FLAGS="$(PARALLEL_FLAGS) $(SWIFT_DEBUG_FLAGS)" ./scripts/build.sh

# runs the complete test suite with parallel execution
test:
	@echo "🧪 Running unit tests in parallel ($(CORES) jobs)..."
	@swift test $(SWIFTPM_SCRATCH_FLAG) $(SWIFTPM_CACHE_FLAG) $(PARALLEL_FLAGS) --parallel --disable-sandbox

# Quick test run - excludes slow UI/integration tests
test-fast:
	@echo "🧪 Running fast unit tests only..."
	@swift test $(SWIFTPM_SCRATCH_FLAG) $(SWIFTPM_CACHE_FLAG) $(PARALLEL_FLAGS) --parallel --disable-sandbox --filter SortyTests

test-full:
	@echo "🧪 Running unit tests with coverage..."
	@swift test $(SWIFTPM_SCRATCH_FLAG) $(SWIFTPM_CACHE_FLAG) --enable-code-coverage $(PARALLEL_FLAGS) --disable-sandbox
	@echo "✅ All tests completed. Coverage reports available in $(SORTY_BUILD_DIR)/debug/codecov"

# Profile build times to identify slow-compiling files
build-profile:
	@chmod +x scripts/profile_build.sh
	@./scripts/profile_build.sh

cache-status:
	@$(BUILD_SCRIPT_ENV) ./scripts/build_cache.sh status

cache-prune:
	@$(BUILD_SCRIPT_ENV) BUILD_CACHE_FORCE_PRUNE=true ./scripts/build_cache.sh prune

# skips all checks and builds/runs immediately
now:
	@$(BUILD_SCRIPT_ENV) $(FAST_LOOP_FLAGS) APP_ICON_VARIANT=debug SKIP_TESTS=true BUILD_CONFIG=debug BUILD_FLAGS="$(PARALLEL_FLAGS) $(SWIFT_DEBUG_FLAGS)" ./scripts/build.sh
	@open releases/Sorty.app

# Optimized local app for daily use and launch profiling. Keep the same signing
# identity as the development loop, but exclude hot reload even if inherited.
daily:
	@$(BUILD_SCRIPT_ENV) $(FAST_LOOP_FLAGS) SORTY_HOT_RELOAD=false APP_ICON_VARIANT=release SKIP_TESTS=true BUILD_CONFIG=release BUILD_FLAGS="$(PARALLEL_FLAGS) $(SWIFT_RELEASE_FLAGS)" ./scripts/build.sh
	@open releases/Sorty.app

# Build and launch Sorty with its in-process InjectionLite hot-reload runtime.
hot:
	@chmod +x scripts/build.sh scripts/hot_reload.sh scripts/hot_reload_frontend.sh
	@$(BUILD_SCRIPT_ENV) $(FAST_LOOP_FLAGS) BUILD_FLAGS="$(PARALLEL_FLAGS) $(SWIFT_DEBUG_FLAGS)" \
		./scripts/hot_reload.sh

# Local CI-style diagnostics. Blacksmith GitHub Actions remain the release/PR gate.
ci:
	@echo "🔄 Running local CI-style diagnostics ($(CORES) cores)..."
	@echo "   Blacksmith GitHub Actions remain the source of truth for PR/release gates."
	@chmod +x scripts/local_ci.sh
	@./scripts/local_ci.sh

# Legacy local CI + report result to GitHub as a commit status.
ci-report:
	@echo "🔄 Running legacy local CI checks + reporting to GitHub..."
	@echo "   This status does not skip Blacksmith checks."
	@chmod +x scripts/local_ci.sh
	@./scripts/local_ci.sh --report

clean:
	@echo "🧹 Cleaning build artifacts..."
	@swift package $(SWIFTPM_SCRATCH_FLAG) $(SWIFTPM_CACHE_FLAG) clean
	@rm -rf .build
	@rm -rf "$(SORTY_BUILD_DIR)"
	@rm -rf releases/
	@echo "✨ Clean complete"

# Clean rebuild - force a full rebuild after cleaning caches
rebuild: clean
	@echo "🔁 Full rebuild after clean..."
	@$(BUILD_SCRIPT_ENV) BUILD_FLAGS="$(PARALLEL_FLAGS)" ./scripts/build.sh

# Install app to /Applications
install: build
	@echo "📦 Installing Sorty to /Applications..."
	@cp -R releases/Sorty.app /Applications/Sorty.app
	@echo "✅ Installed! You can now find Sorty in your Applications folder."

# Create a release zip for GitHub (manual)
release:
	@echo "📦 Creating release package..."
	@APP_ICON_VARIANT=release $(MAKE) build
	@ZIP_NAME_OVERRIDE="Sorty-macOS.zip" ./scripts/package.sh
	@echo "✅ Release package created: releases/Sorty-macOS.zip"
	@echo ""
	@echo "📋 Next steps:"
	@echo "   1. Create a new release on GitHub"
	@echo "   2. Upload releases/Sorty-macOS.zip"
	@echo "   3. Remind users to run: xattr -cr /Applications/Sorty.app"

friend-zip:
	@echo "📦 Creating friend-test ZIP in Downloads..."
	@chmod +x scripts/build.sh scripts/package.sh
	@$(BUILD_SCRIPT_ENV) APP_ICON_VARIANT=debug SKIP_TESTS=true BUILD_CONFIG=debug BUILD_FLAGS="$(PARALLEL_FLAGS) $(SWIFT_DEBUG_FLAGS)" ./scripts/build.sh
	@ZIP_NAME_OVERRIDE="Sorty-friend-test.zip" ./scripts/package.sh
	@mkdir -p "$(HOME)/Downloads"
	@cp -f "releases/Sorty-friend-test.zip" "$(HOME)/Downloads/Sorty-friend-test.zip"
	@echo "✅ Ready to share: $(HOME)/Downloads/Sorty-friend-test.zip"
	@echo "   If macOS blocks it after download, unzip it and run: xattr -cr /Applications/Sorty.app"

# Automated releases with version bumping
release-patch:
	@echo "🚀 Creating patch release..."
	@chmod +x scripts/auto-release.sh
	@./scripts/auto-release.sh patch

release-minor:
	@echo "🚀 Creating minor release..."
	@chmod +x scripts/auto-release.sh
	@./scripts/auto-release.sh minor

release-major:
	@echo "🚀 Creating major release..."
	@chmod +x scripts/auto-release.sh
	@./scripts/auto-release.sh major

# Pre-release validation - comprehensive checks before release
prerelease:
	@echo "🔍 Running pre-release validation..."
	@chmod +x scripts/prerelease_check.sh
	@./scripts/prerelease_check.sh

# Benchmark build times and save results
benchmark:
	@echo "📊 Running build benchmarks..."
	@chmod +x scripts/benchmark.sh
	@./scripts/benchmark.sh

# Compare benchmarks against a saved baseline
benchmark-compare:
	@echo "📊 Comparing against baseline..."
	@chmod +x scripts/benchmark.sh
	@./scripts/benchmark.sh --compare .build/benchmark-baseline.json

# Save current benchmark as baseline
benchmark-save:
	@echo "📊 Saving current results as baseline..."
	@chmod +x scripts/benchmark.sh
	@./scripts/benchmark.sh
	@cp .build/benchmark-results.json .build/benchmark-baseline.json
	@echo "✅ Baseline saved to .build/benchmark-baseline.json"

# Preview harness for rapid iteration
harness:
	@echo "🔬 Building preview harness ($(CORES) parallel jobs)..."
	@$(BUILD_SCRIPT_ENV) $(FAST_LOOP_FLAGS) SKIP_TESTS=true BUILD_CONFIG=debug SORTY_HARNESS_MODE=1 BUILD_FLAGS="$(PARALLEL_FLAGS) $(SWIFT_DEBUG_FLAGS)" ./scripts/build.sh
	@SORTY_HARNESS_MODE=1 open releases/Sorty.app

harness-accent:
	@echo "🔬 Harness → Accent prototypes..."
	@$(BUILD_SCRIPT_ENV) $(FAST_LOOP_FLAGS) SKIP_TESTS=true BUILD_CONFIG=debug SORTY_HARNESS_MODE=1 BUILD_FLAGS="$(PARALLEL_FLAGS) $(SWIFT_DEBUG_FLAGS)" ./scripts/build.sh
	@SORTY_HARNESS_MODE=1 SORTY_ACCENT_PROTOTYPE=1 open releases/Sorty.app

QUALITY_CORPUS ?= QualityCorpus/private

quality-report:
	@swift run $(SWIFTPM_SCRATCH_FLAG) $(SWIFTPM_CACHE_FLAG) --disable-sandbox SortyQuality --corpus "$(QUALITY_CORPUS)"

help:
	@echo "Sorty Build System (Optimized)"
	@echo "=============================="
	@echo "Available commands:"
	@echo "  make build       - Compile and update the .app bundle (runs unit tests)"
	@echo "  make run         - Build and launch the app"
	@echo "  make debug       - Build in DEBUG mode and launch"
	@echo "  make dev         - Fastest development build (debug + parallel + no tests)"
	@echo "  make hot         - Build and launch self-contained Swift hot reload"
	@echo "  make now         - Build fast and launch immediately (skips tests, parallel)"
	@echo "  make daily       - Build optimized app and launch (no hot reload or tests)"
	@echo "  make build-ci-universal - CI-style universal xcodebuild + Sorty-universal.zip"
	@echo ""
	@echo ""
	@echo "Local diagnostics:"
	@echo "  make ci          - Run local CI-style diagnostics"
	@echo "  make ci-report   - Legacy local status report; does not skip Blacksmith"
	@echo ""
	@echo "Build Profiling:"
	@echo "  make build-profile - Identify slow-compiling files and functions"
	@echo "  make cache-status  - Show build cache size and fingerprint state"
	@echo "  make cache-prune   - Force scheduled cache validation and pruning"
	@echo ""
	@echo "Testing:"
	@echo "  make test        - Run unit tests in parallel"
	@echo "  make test-fast   - Run only fast unit tests (excludes slow UI tests)"
	@echo "  make test-full   - Run unit tests with coverage (UI tests disabled)"
	@echo "  make quality-report - Score the private organization quality corpus"
	@echo ""
	@echo "Release:"
	@echo "  make release-patch   - Auto-release with patch version bump (1.0.0 -> 1.0.1)"
	@echo "  make release-minor   - Auto-release with minor version bump (1.0.0 -> 1.1.0)"
	@echo "  make release-major   - Auto-release with major version bump (1.0.0 -> 2.0.0)"
	@echo "  make release         - Create local release zip for diagnostics"
	@echo "  make friend-zip      - Build a friend-test ZIP in ~/Downloads"
	@echo "  make prerelease      - Run local pre-release diagnostics"
	@echo ""
	@echo "Preview Harness (fast iteration):"
	@echo "  make harness          - Build and launch harness mode"
	@echo "  make harness-accent   - Launch the six accent color prototypes"
	@echo ""
	@echo "Benchmarking:"
	@echo "  make benchmark         - Measure all build times"
	@echo "  make benchmark-save    - Save benchmark as baseline"
	@echo "  make benchmark-compare - Compare against saved baseline"
	@echo ""
	@echo "Utility:"
	@echo "  make clean       - Remove all build artifacts and releases"
	@echo "  make rebuild     - Clean, then full rebuild (slowest, but fresh)"
	@echo "  make install     - Copy built app to /Applications"
	@echo "  make help        - Show this help message"
	@echo ""
	@echo "Verbosity:"
	@echo "  Default output is concise. Use VERBOSE=true for full logs"
	@echo "  Example: make build VERBOSE=true"
	@echo ""
	@echo "Build runtime behavior:"
	@echo "  AUTO_CLOSE_SORTY_ON_BUILD=true (default) closes idle Sorty instances after build"
	@echo "  BUILD_CACHE_VALIDATE_INPUTS=true clears stale compiled outputs after toolchain/build input changes"
	@echo "  AUTO_PRUNE_BUILD_CACHE=true (default) prunes stale build data on a schedule"
	@echo "  BUILD_CACHE_MAX_SIZE_MB=8192 triggers pruning above this size"
	@echo "  BUILD_CACHE_TARGET_SIZE_MB=6144 aims to shrink build cache near this size"
	@echo "  BUILD_CACHE_STALE_DAYS=7 marks old cache data eligible for cleanup"
	@echo "  BUILD_CACHE_PRUNE_INTERVAL_SECONDS=86400 limits full prune checks to once per day"
	@echo "  KEYCHAIN_UNLOCK_TIMEOUT_SECONDS=43200 keeps keychain unlocked for signing (~12h)"
	@echo ""
	@echo "Parallel Jobs: $(CORES) cores detected"
	@echo ""
	@echo "Optimization Notes:"
	@echo "  - All builds now use parallel compilation ($(CORES) jobs)"
	@echo "  - Debug builds use -Onone with batch mode for speed"
	@echo "  - Release builds use -O with whole-module optimization"
	@echo "  - Tests run in parallel for faster execution"
