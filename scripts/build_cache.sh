#!/bin/bash
set -e
set -o pipefail

if [ -z "${PROJECT_DIR:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    # shellcheck source=scripts/config.sh
    source "${SCRIPT_DIR}/config.sh"
elif ! declare -f is_truthy >/dev/null 2>&1; then
    # shellcheck source=scripts/utils.sh
    source "${PROJECT_DIR}/scripts/utils.sh"
fi

BUILD_LOG_DIR="${BUILD_LOG_DIR:-${WORKSPACE_BUILD_DIR:-${PROJECT_DIR}/.build}/logs}"
AUTO_PRUNE_BUILD_CACHE="${AUTO_PRUNE_BUILD_CACHE:-true}"
BUILD_CACHE_VALIDATE_INPUTS="${BUILD_CACHE_VALIDATE_INPUTS:-true}"
BUILD_CACHE_MAX_SIZE_MB="${BUILD_CACHE_MAX_SIZE_MB:-4096}"
BUILD_CACHE_TARGET_SIZE_MB="${BUILD_CACHE_TARGET_SIZE_MB:-3072}"
BUILD_CACHE_STALE_DAYS="${BUILD_CACHE_STALE_DAYS:-30}"
BUILD_CACHE_PRUNE_INTERVAL_SECONDS="${BUILD_CACHE_PRUNE_INTERVAL_SECONDS:-86400}"
BUILD_CACHE_FORCE_PRUNE="${BUILD_CACHE_FORCE_PRUNE:-false}"
BUILD_CACHE_PRUNE_DEPENDENCIES_WHEN_OVERSIZED="${BUILD_CACHE_PRUNE_DEPENDENCIES_WHEN_OVERSIZED:-false}"
BUILD_CACHE_FINGERPRINT_VERSION="${BUILD_CACHE_FINGERPRINT_VERSION:-3}"
BUILD_CACHE_LOCK_STALE_SECONDS="${BUILD_CACHE_LOCK_STALE_SECONDS:-3600}"
BUILD_CACHE_TOOLCHAIN_REFRESH_SECONDS="${BUILD_CACHE_TOOLCHAIN_REFRESH_SECONDS:-86400}"

BUILD_CACHE_STATE_DIR="${BUILD_DIR}/.sorty-cache"
BUILD_CACHE_STATE_FILE="${BUILD_CACHE_STATE_DIR}/state"
BUILD_CACHE_LAST_PRUNE_FILE="${BUILD_CACHE_STATE_DIR}/last-prune"
BUILD_CACHE_LOCK_DIR="${BUILD_CACHE_STATE_DIR}/maintenance.lock"
BUILD_CACHE_TOOLCHAIN_FILE="${BUILD_CACHE_STATE_DIR}/toolchain-fingerprint"
# Last measured BUILD_DIR size (MB). Written on every full `du` walk so fresh
# builds can reuse it until the next scheduled prune.
BUILD_CACHE_SIZE_FILE="${BUILD_CACHE_STATE_DIR}/last-size"

build_cache_now() {
    date +%s
}

build_cache_path_mtime() {
    local path="$1"
    stat -f %m "${path}" 2>/dev/null || stat -c %Y "${path}" 2>/dev/null || echo 0
}

# How get_directory_size_mb is used: prune decisions need an exact BUILD_DIR
# size, but a full `du` walk on every build dominates maintenance time. Only
# the top-level BUILD_DIR walk is expensive, so per-candidate subpaths stay
# exact while BUILD_DIR reuses the last measured size until the prune interval
# elapses (or pruning is forced). Pass "fresh" to force a full walk (status).
get_directory_size_mb() {
    local dir_path="$1"
    local mode="${2:-cached}"
    local measured_size
    local cached_size
    if [ ! -e "${dir_path}" ]; then
        echo "0"
        return
    fi

    if [ "${dir_path}" != "${BUILD_DIR}" ] || [ "${mode}" = "fresh" ]; then
        measured_size="$(du -sm "${dir_path}" 2>/dev/null | awk '{print $1+0}')"
        if [ "${dir_path}" = "${BUILD_DIR}" ]; then
            mkdir -p "${BUILD_CACHE_STATE_DIR}"
            printf '%s\n' "${measured_size}" > "${BUILD_CACHE_SIZE_FILE}"
        fi
        printf '%s\n' "${measured_size}"
        return
    fi

    if is_truthy "${BUILD_CACHE_FORCE_PRUNE}" || build_cache_should_prune; then
        measured_size="$(du -sm "${dir_path}" 2>/dev/null | awk '{print $1+0}')"
        mkdir -p "${BUILD_CACHE_STATE_DIR}"
        printf '%s\n' "${measured_size}" > "${BUILD_CACHE_SIZE_FILE}"
        printf '%s\n' "${measured_size}"
        return
    fi

    cached_size="$(cat "${BUILD_CACHE_SIZE_FILE}" 2>/dev/null || echo "")"
    if [[ "${cached_size}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "${cached_size}"
        return
    fi

    # No measurement yet and no prune due: assume small. The exact size is
    # measured at the next scheduled prune; explicit callers pass "fresh".
    echo "0"
}

prune_path_if_exists() {
    local path="$1"
    [ -e "${path}" ] || return 0
    rm -rf "${path}"
}

build_cache_hash_stream() {
    shasum -a 256 | awk '{print $1}'
}

build_cache_hash_files() {
    local rel_path
    local existing_files=()
    for rel_path in "$@"; do
        if [ -f "${PROJECT_DIR}/${rel_path}" ]; then
            existing_files+=("${rel_path}")
        else
            printf '%s missing\n' "${rel_path}"
        fi
    done
    # One hashing process for the whole batch, retaining paths and missing inputs.
    if [ "${#existing_files[@]}" -gt 0 ]; then
        (cd "${PROJECT_DIR}" && shasum -a 256 -- "${existing_files[@]}")
    fi
}

build_cache_dependency_hash() {
    local dependency_files=("Package.swift" "Package.resolved")

    if [ -d "${PROJECT_DIR}/Packages" ]; then
        while IFS= read -r package_file; do
            dependency_files+=("${package_file#${PROJECT_DIR}/}")
        done < <(find "${PROJECT_DIR}/Packages" -name "Package.swift" -type f | sort)
    fi

    build_cache_hash_files "${dependency_files[@]}" | build_cache_hash_stream
}

# Fast-path dependency key: hashing three files is milliseconds. The deep
# Packages/* scan in build_cache_dependency_hash only runs when this key moves.
build_cache_fast_dependency_hash() {
    build_cache_hash_files \
        "Package.swift" \
        "Package.resolved" \
        "Sorty.xcodeproj/project.pbxproj" | build_cache_hash_stream
}

build_cache_input_hash() {
    build_cache_hash_files \
        "Package.swift" \
        "Package.resolved" \
        "Sorty.xcodeproj/project.pbxproj" \
        "Info.plist" \
        "Sorty.entitlements" \
        "SortyFinderSync/Info.plist" \
        "SortyFinderSync/SortyFinderSync.entitlements" \
        "scripts/build.sh" \
        "scripts/build_cache.sh" \
        "scripts/config.sh" \
        "scripts/utils.sh" | build_cache_hash_stream
}

build_cache_toolchain_hash() {
    local developer_dir swiftc_path swiftc_mtime cache_key now
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
    swiftc_path="${developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    if [ ! -x "${swiftc_path}" ]; then
        swiftc_path="$(command -v swiftc 2>/dev/null || true)"
    fi
    swiftc_mtime="$(build_cache_path_mtime "${swiftc_path}")"
    cache_key="$({
        printf 'developer-dir=%s\n' "${developer_dir:-unavailable}"
        printf 'swiftc=%s\n' "${swiftc_path:-unavailable}"
        printf 'swiftc-mtime=%s\n' "${swiftc_mtime}"
    } | build_cache_hash_stream)"
    now="$(build_cache_now)"

    local cached_key cached_at cached_hash refresh_seconds
    cached_key="$(sed -n 's/^key=//p' "${BUILD_CACHE_TOOLCHAIN_FILE}" 2>/dev/null | head -1)"
    cached_at="$(sed -n 's/^checked_at=//p' "${BUILD_CACHE_TOOLCHAIN_FILE}" 2>/dev/null | head -1)"
    cached_hash="$(sed -n 's/^hash=//p' "${BUILD_CACHE_TOOLCHAIN_FILE}" 2>/dev/null | head -1)"
    refresh_seconds="${BUILD_CACHE_TOOLCHAIN_REFRESH_SECONDS}"
    if ! [[ "${refresh_seconds}" =~ ^[0-9]+$ ]]; then
        refresh_seconds=86400
    fi

    if [ "${cached_key}" = "${cache_key}" ] &&
        [[ "${cached_at}" =~ ^[0-9]+$ ]] &&
        [ $((now - cached_at)) -lt "${refresh_seconds}" ] &&
        [ -n "${cached_hash}" ]; then
        printf '%s\n' "${cached_hash}"
        return
    fi

    local xcodebuild_path xcrun_path toolchain_hash
    xcodebuild_path="${developer_dir}/usr/bin/xcodebuild"
    xcrun_path="${developer_dir}/usr/bin/xcrun"
    toolchain_hash="$({
        printf 'swiftc=%s\n' "${swiftc_path:-unavailable}"
        printf 'swift-version='
        if [ -x "${swiftc_path}" ]; then
            "${swiftc_path}" -version 2>/dev/null || printf 'unavailable\n'
        else
            printf 'unavailable\n'
        fi
        printf 'xcode-version='
        if [ -x "${xcodebuild_path}" ]; then
            "${xcodebuild_path}" -version 2>/dev/null || printf 'unavailable\n'
        else
            printf 'unavailable\n'
        fi
        printf 'macos-sdk='
        if [ -x "${xcrun_path}" ]; then
            "${xcrun_path}" --sdk macosx --show-sdk-path 2>/dev/null || printf 'unavailable\n'
        else
            printf 'unavailable\n'
        fi
    } | build_cache_hash_stream)"

    mkdir -p "${BUILD_CACHE_STATE_DIR}"
    local temp_file="${BUILD_CACHE_TOOLCHAIN_FILE}.$$"
    {
        printf 'key=%s\n' "${cache_key}"
        printf 'checked_at=%s\n' "${now}"
        printf 'hash=%s\n' "${toolchain_hash}"
    } > "${temp_file}"
    mv "${temp_file}" "${BUILD_CACHE_TOOLCHAIN_FILE}"
    printf '%s\n' "${toolchain_hash}"
}

build_cache_state_value() {
    local key="$1"
    [ -f "${BUILD_CACHE_STATE_FILE}" ] || return 0
    sed -n "s/^${key}=//p" "${BUILD_CACHE_STATE_FILE}" | head -1
}

build_cache_write_state() {
    local compatibility_fingerprint="$1"
    local input_hash="$2"
    local dependency_hash="$3"
    local toolchain_hash="$4"
    local fast_hash="$5"
    if [ -z "${fast_hash}" ]; then
        fast_hash="$(build_cache_state_value "fast_dependency_hash")"
    fi

    mkdir -p "${BUILD_CACHE_STATE_DIR}"
    {
        printf 'fingerprint=%s\n' "${compatibility_fingerprint}"
        printf 'compatibility_fingerprint=%s\n' "${compatibility_fingerprint}"
        printf 'state_version=%s\n' "${BUILD_CACHE_FINGERPRINT_VERSION}"
        printf 'input_hash=%s\n' "${input_hash}"
        printf 'dependency_hash=%s\n' "${dependency_hash}"
        printf 'toolchain_hash=%s\n' "${toolchain_hash}"
        printf 'fast_dependency_hash=%s\n' "${fast_hash}"
        printf 'build_method=%s\n' "${BUILD_METHOD:-spm}"
        printf 'build_config=%s\n' "${BUILD_CONFIG:-release}"
        printf 'build_archs=%s\n' "$(build_cache_fingerprint_archs)"
        printf 'updated_at=%s\n' "$(build_cache_now)"
    } > "${BUILD_CACHE_STATE_FILE}"
}

build_cache_fingerprint_archs() {
    if [ "${BUILD_METHOD:-spm}" = "xcodebuild" ]; then
        echo "${BUILD_ARCHS:-native}"
    else
        echo "spm-native"
    fi
}

build_cache_compiled_output_paths() {
    printf '%s\n' \
        "${BUILD_DIR}/.sorty-cache/cold" \
        "${BUILD_DIR}/ModuleCache" \
        "${BUILD_DIR}/DerivedData" \
        "${BUILD_DIR}/FinderSyncDerivedData" \
        "${BUILD_DIR}/debug" \
        "${BUILD_DIR}/release"

    if [ -d "${BUILD_DIR}" ]; then
        find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 -type d -name '*-apple-macosx' -print 2>/dev/null || true
    fi
}

reset_cached_build_products() {
    local path
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        prune_path_if_exists "${path}"
    done < <(build_cache_compiled_output_paths)

    rm -f \
        "${BUILD_DIR}/.lock" \
        "${BUILD_DIR}/build.db" \
        "${BUILD_DIR}/build.db-journal" \
        "${BUILD_DIR}/build.db-shm" \
        "${BUILD_DIR}/build.db-wal"
}

reset_cached_dependency_products() {
    prune_path_if_exists "${BUILD_DIR}/checkouts"
    prune_path_if_exists "${BUILD_DIR}/repositories"
    prune_path_if_exists "${BUILD_DIR}/artifacts"
}

validate_binary_artifact_cache() {
    [ "${BUILD_METHOD:-spm}" = "spm" ] || return 0

    local sparkle_checkout="${BUILD_DIR}/checkouts/Sparkle"
    local sparkle_artifact="${BUILD_DIR}/artifacts/sparkle/Sparkle/Sparkle.xcframework"

    if [ -d "${sparkle_checkout}" ] &&
        [ -e "${BUILD_DIR}/artifacts" ] &&
        [ ! -f "${sparkle_artifact}/Info.plist" ]; then
        log_item "Sparkle binary artifact cache is incomplete; clearing SwiftPM dependency cache"
        reset_cached_build_products
        reset_cached_dependency_products
    fi
}

validate_build_cache_fingerprint() {
    if ! is_truthy "${BUILD_CACHE_VALIDATE_INPUTS}"; then
        log_detail "Skipping build cache validation (BUILD_CACHE_VALIDATE_INPUTS=${BUILD_CACHE_VALIDATE_INPUTS})"
        return 0
    fi

    local toolchain_hash compatibility_fingerprint fast_hash input_hash dependency_hash
    toolchain_hash="$(build_cache_toolchain_hash)"
    compatibility_fingerprint="${toolchain_hash}"
    fast_hash="$(build_cache_fast_dependency_hash)"
    # The fixed input list is cheap (no directory scan); the deep Packages/*
    # dependency scan below is the expensive one, so only it is gated.
    input_hash="$(build_cache_input_hash)"

    local previous_fingerprint previous_toolchain stored_fast stored_dependency
    previous_fingerprint="$(build_cache_state_value "compatibility_fingerprint")"
    previous_toolchain="$(build_cache_state_value "toolchain_hash")"
    stored_fast="$(build_cache_state_value "fast_dependency_hash")"
    stored_dependency="$(build_cache_state_value "dependency_hash")"

    if [ -n "${stored_fast}" ] && [ "${stored_fast}" = "${fast_hash}" ] && [ -n "${stored_dependency}" ]; then
        # Fast path: dependency inputs unchanged since last state, so reuse the
        # recorded deep hash instead of re-scanning Packages/*.
        dependency_hash="${stored_dependency}"
    else
        dependency_hash="$(build_cache_dependency_hash)"
    fi

    if [ -z "${previous_fingerprint}" ]; then
        # State written by fingerprint v2 did not store the compatibility key.
        # Migrate it in place when its toolchain still matches rather than
        # throwing away otherwise valid compiled products.
        if [ -n "${previous_toolchain}" ] && [ "${previous_toolchain}" = "${toolchain_hash}" ]; then
            build_cache_write_state "${compatibility_fingerprint}" "${input_hash}" "${dependency_hash}" "${toolchain_hash}" "${fast_hash}"
            log_detail "Migrated build cache state without discarding compatible outputs"
            return 0
        fi

        build_cache_write_state "${compatibility_fingerprint}" "${input_hash}" "${dependency_hash}" "${toolchain_hash}" "${fast_hash}"
        log_detail "Initialized build cache compatibility fingerprint"
        return 0
    fi

    if [ "${previous_fingerprint}" = "${compatibility_fingerprint}" ]; then
        build_cache_write_state "${compatibility_fingerprint}" "${input_hash}" "${dependency_hash}" "${toolchain_hash}" "${fast_hash}"
        return 0
    fi

    if [ "${previous_fingerprint#*:}" = "${toolchain_hash}" ]; then
        build_cache_write_state "${compatibility_fingerprint}" "${input_hash}" "${dependency_hash}" "${toolchain_hash}" "${fast_hash}"
        log_detail "Migrated build cache state without discarding compatible outputs"
        return 0
    fi

    log_item "Build toolchain changed; clearing incompatible compiled outputs"
    reset_cached_build_products
    build_cache_write_state "${compatibility_fingerprint}" "${input_hash}" "${dependency_hash}" "${toolchain_hash}" "${fast_hash}"
}

build_cache_acquire_lock() {
    mkdir -p "${BUILD_CACHE_STATE_DIR}"
    if mkdir "${BUILD_CACHE_LOCK_DIR}" 2>/dev/null; then
        return 0
    fi

    local stale_seconds lock_mtime now
    stale_seconds="${BUILD_CACHE_LOCK_STALE_SECONDS}"
    if ! [[ "${stale_seconds}" =~ ^[0-9]+$ ]]; then
        stale_seconds=3600
    fi
    lock_mtime="$(build_cache_path_mtime "${BUILD_CACHE_LOCK_DIR}")"
    now="$(build_cache_now)"
    if [[ "${lock_mtime}" =~ ^[0-9]+$ ]] && [ $((now - lock_mtime)) -gt "${stale_seconds}" ]; then
        rm -rf "${BUILD_CACHE_LOCK_DIR}"
        if mkdir "${BUILD_CACHE_LOCK_DIR}" 2>/dev/null; then
            return 0
        fi
    fi

    log_detail "Another build cache maintenance pass is running; skipping this pass"
    return 1
}

build_cache_release_lock() {
    rmdir "${BUILD_CACHE_LOCK_DIR}" 2>/dev/null || true
}

build_cache_should_prune() {
    if is_truthy "${BUILD_CACHE_FORCE_PRUNE}"; then
        return 0
    fi

    local interval="${BUILD_CACHE_PRUNE_INTERVAL_SECONDS}"
    if ! [[ "${interval}" =~ ^[0-9]+$ ]]; then
        interval=86400
    fi
    if [ "${interval}" -eq 0 ]; then
        return 0
    fi
    if [ ! -f "${BUILD_CACHE_LAST_PRUNE_FILE}" ]; then
        return 0
    fi

    local last_prune now
    last_prune="$(cat "${BUILD_CACHE_LAST_PRUNE_FILE}" 2>/dev/null || echo 0)"
    now="$(build_cache_now)"
    if ! [[ "${last_prune}" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    [ $((now - last_prune)) -ge "${interval}" ]
}

build_cache_record_prune() {
    mkdir -p "${BUILD_CACHE_STATE_DIR}"
    build_cache_now > "${BUILD_CACHE_LAST_PRUNE_FILE}"
}

# Scratch roots that can hold regenerable intermediates. The Makefile symlinks
# PROJECT_DIR/.build at SORTY_BUILD_DIR, so both names may describe the same
# directory; string-dedupe here (a repeated pass over one root is harmless).
build_cache_scratch_roots() {
    local root
    local seen=""
    for root in "${BUILD_DIR}" "${WORKSPACE_BUILD_DIR:-}"; do
        [ -n "${root}" ] || continue
        case ":${seen}:" in
            *":${root}:"*) continue ;;
        esac
        seen="${seen}:${root}"
        [ -d "${root}" ] || continue
        printf '%s\n' "${root}"
    done
}

# Never delete the config being built or the debug loop cache: the just-built
# product lives in ${BUILD_DIR}/${BUILD_CONFIG}, and debug/ is always hot.
build_cache_is_protected_config_name() {
    local name="$1"
    [ "${name}" = "debug" ] && return 0
    [ "${name}" = "${BUILD_CONFIG:-release}" ] && return 0
    return 1
}

# Keep the most recently used output for each compiler input. String catalogs
# have separate roots because an app uses several tables in the same build.
# The build.sh hit paths touch the hit directory, keeping LRU order accurate.
build_cache_prune_resource_caches_to_mru() {
    local resource_cache cache_path newest_path
    for resource_cache in "${BUILD_CACHE_STATE_DIR}/assets" "${BUILD_CACHE_STATE_DIR}/metal" "${BUILD_CACHE_STATE_DIR}/strings/"*; do
        [ -d "${resource_cache}" ] || continue
        newest_path=""
        while IFS=$'\t' read -r _ cache_path; do
            [ -n "${cache_path}" ] || continue
            if [ -z "${newest_path}" ]; then
                newest_path="${cache_path}"
                continue
            fi
            rm -rf "${cache_path}"
        done < <(
            while IFS= read -r cache_path; do
                printf '%s\t%s\n' "$(build_cache_path_mtime "${cache_path}")" "${cache_path}"
            done < <(find "${resource_cache}" -mindepth 1 -maxdepth 1 -type d ! -name '.compile-*' -print 2>/dev/null || true) | sort -rn
        )
    done
}

prune_stale_build_cache_paths() {
    local stale_days="$1"
    [ -d "${BUILD_DIR}" ] || return 0

    local root disposable inactive dep_store dep_entry current_config
    current_config="${BUILD_CONFIG:-release}"
    while IFS= read -r root; do
        [ -n "${root}" ] || continue
        # Xcode-managed trees are only stale when another method owns the build.
        if [ "${BUILD_METHOD:-spm}" != "xcodebuild" ]; then
            for disposable in DerivedData xcode-derived; do
                if [ -d "${root}/${disposable}" ]; then
                    find "${root}/${disposable}" -prune -type d -mtime +"${stale_days}" -exec rm -rf {} + 2>/dev/null || true
                fi
            done
        fi
        # Regenerable intermediates: the whole dir goes only once fully stale.
        for disposable in test-export xcode-packages; do
            if [ -d "${root}/${disposable}" ]; then
                find "${root}/${disposable}" -prune -type d -mtime +"${stale_days}" -exec rm -rf {} + 2>/dev/null || true
            fi
        done

        find "${root}" -mindepth 2 -maxdepth 2 -type d \
            \( -name debug -o -name release \) ! -name debug ! -name "${current_config}" \
            -mtime +"${stale_days}" -exec rm -rf {} + 2>/dev/null || true

        # Inactive top-level config outputs, sparing debug and the just-built config.
        for inactive in release debug; do
            if build_cache_is_protected_config_name "${inactive}"; then
                continue
            fi
            if [ -d "${root}/${inactive}" ]; then
                find "${root}/${inactive}" -prune -type d -mtime +"${stale_days}" -exec rm -rf {} + 2>/dev/null || true
            fi
        done

        # Dependency stores are only reclaimed when explicitly opted in, so a
        # default prune never forces a full package refetch.
        if is_truthy "${BUILD_CACHE_PRUNE_DEPENDENCIES_WHEN_OVERSIZED}"; then
            for dep_store in checkouts repositories artifacts; do
                [ -d "${root}/${dep_store}" ] || continue
                while IFS= read -r dep_entry; do
                    [ -n "${dep_entry}" ] || continue
                    find "${dep_entry}" -prune -mtime +"${stale_days}" -exec rm -rf {} + 2>/dev/null || true
                done < <(find "${root}/${dep_store}" -mindepth 1 -maxdepth 1 -print 2>/dev/null || true)
            done
        fi
    done < <(build_cache_scratch_roots)

    # Scripted builds disable indexing. Old editor indexes are regenerable;
    # keep compiler objects, dependency artifacts, and incremental databases.
    case " ${BUILD_FLAGS:-} ${XCODE_EXTRA_FLAGS:-} " in
        *" --disable-index-store "*|*" COMPILER_INDEX_STORE_ENABLE=NO "*)
            find "${BUILD_DIR}" -type d \
                \( -name checkouts -o -name repositories -o -name artifacts \) -prune -o \
                -type d \( -name index -o -name Index.noindex \) \
                -prune -exec rm -rf {} + 2>/dev/null || true
            ;;
    esac
    if [ -d "${BUILD_CACHE_STATE_DIR}/bundle-fingerprints" ]; then
        find "${BUILD_CACHE_STATE_DIR}/bundle-fingerprints" -type f \
            -mtime +"${stale_days}" -delete 2>/dev/null || true
    fi

    local current_finder_arch_key="${BUILD_ARCHS:-$(uname -m)}"
    current_finder_arch_key="${current_finder_arch_key// /-}"
    if [ -d "${BUILD_DIR}/FinderSyncDerivedData" ]; then
        find "${BUILD_DIR}/FinderSyncDerivedData" -mindepth 1 -maxdepth 1 -type d \
            ! -name "${current_finder_arch_key}" -mtime +"${stale_days}" -exec rm -rf {} + 2>/dev/null || true
    fi

    if [ -d "${BUILD_LOG_DIR}" ]; then
        find "${BUILD_LOG_DIR}" -type f -mtime +"${stale_days}" -exec rm -f {} + 2>/dev/null || true
    fi

    local resource_cache
    for resource_cache in assets metal; do
        if [ -d "${BUILD_CACHE_STATE_DIR}/${resource_cache}" ]; then
            find "${BUILD_CACHE_STATE_DIR}/${resource_cache}" -mindepth 1 -maxdepth 1 -type d \
                -mtime +"${stale_days}" -exec rm -rf {} + 2>/dev/null || true
        fi
    done
    # Cap content caches to the most recently used entry per kind.
    build_cache_prune_resource_caches_to_mru
}

build_cache_prune_candidate_paths() {
    # Keep the most recently used output for each resource compiler.
    local asset_path newest_asset resource_cache
    for resource_cache in assets metal; do
        newest_asset=""
        if [ ! -d "${BUILD_CACHE_STATE_DIR}/${resource_cache}" ]; then
            continue
        fi
        while IFS=$'\t' read -r _ asset_path; do
            if [ -z "${newest_asset}" ]; then
                newest_asset="${asset_path}"
                continue
            fi
            printf '%s\n' "${asset_path}"
        done < <(
            while IFS= read -r asset_path; do
                printf '%s\t%s\n' "$(build_cache_path_mtime "${asset_path}")" "${asset_path}"
            done < <(find "${BUILD_CACHE_STATE_DIR}/${resource_cache}" -mindepth 1 -maxdepth 1 -type d -print) | sort -rn
        )
    done

    # Regenerable intermediates across every scratch root, oldest first via the
    # mtime sort in prune_inactive_build_outputs_to_target. The active debug/
    # and current-config outputs are never candidates.
    local root disposable inactive config_path config_base dep_store dep_entry
    while IFS= read -r root; do
        [ -n "${root}" ] || continue
        if [ "${BUILD_METHOD:-spm}" != "xcodebuild" ]; then
            for disposable in DerivedData xcode-derived; do
                [ -e "${root}/${disposable}" ] && printf '%s\n' "${root}/${disposable}"
            done
        fi
        for disposable in test-export xcode-packages; do
            [ -e "${root}/${disposable}" ] && printf '%s\n' "${root}/${disposable}"
        done
        while IFS= read -r config_path; do
            [ -n "${config_path}" ] || continue
            config_base="$(basename "${config_path}")"
            if build_cache_is_protected_config_name "${config_base}"; then
                continue
            fi
            printf '%s\n' "${config_path}"
        done < <(find "${root}" -mindepth 2 -maxdepth 2 -type d \
            \( -name debug -o -name release \) -print 2>/dev/null || true)
        for inactive in release debug; do
            if build_cache_is_protected_config_name "${inactive}"; then
                continue
            fi
            [ -e "${root}/${inactive}" ] && printf '%s\n' "${root}/${inactive}"
        done
        # Dependency entries are LRU candidates only when explicitly opted in.
        if is_truthy "${BUILD_CACHE_PRUNE_DEPENDENCIES_WHEN_OVERSIZED}"; then
            for dep_store in checkouts repositories artifacts; do
                [ -d "${root}/${dep_store}" ] || continue
                while IFS= read -r dep_entry; do
                    [ -n "${dep_entry}" ] || continue
                    printf '%s\n' "${dep_entry}"
                done < <(find "${root}/${dep_store}" -mindepth 1 -maxdepth 1 -print 2>/dev/null || true)
            done
        fi
    done < <(build_cache_scratch_roots)

    local current_finder_arch_key="${BUILD_ARCHS:-$(uname -m)}"
    current_finder_arch_key="${current_finder_arch_key// /-}"
    local finder_path
    if [ -d "${BUILD_DIR}/FinderSyncDerivedData" ]; then
        while IFS= read -r finder_path; do
            [ "$(basename "${finder_path}")" = "${current_finder_arch_key}" ] && continue
            printf '%s\n' "${finder_path}"
        done < <(find "${BUILD_DIR}/FinderSyncDerivedData" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null || true)
    fi
}

prune_inactive_build_outputs_to_target() {
    local target_size_mb="$1"
    local candidate_path candidate_size_mb
    local remaining_size_mb="${2:-$(get_directory_size_mb "${BUILD_DIR}")}"

    while IFS=$'\t' read -r _ candidate_path; do
        [ -n "${candidate_path}" ] || continue
        [ -e "${candidate_path}" ] || continue
        [ "${remaining_size_mb}" -gt "${target_size_mb}" ] || break
        candidate_size_mb=$(get_directory_size_mb "${candidate_path}")
        log_detail "Pruning inactive build output ${candidate_path#${BUILD_DIR}/}"
        prune_path_if_exists "${candidate_path}"
        remaining_size_mb=$((remaining_size_mb - candidate_size_mb))
    done < <(
        while IFS= read -r candidate_path; do
            [ -e "${candidate_path}" ] || continue
            printf '%s\t%s\n' "$(build_cache_path_mtime "${candidate_path}")" "${candidate_path}"
        done < <(build_cache_prune_candidate_paths) | sort -n
    )
}

prune_oversized_build_cache() {
    if ! is_truthy "${AUTO_PRUNE_BUILD_CACHE}"; then
        log_detail "Skipping build cache pruning (AUTO_PRUNE_BUILD_CACHE=${AUTO_PRUNE_BUILD_CACHE})"
        return 0
    fi

    if ! build_cache_should_prune; then
        return 0
    fi

    local max_size_mb="${BUILD_CACHE_MAX_SIZE_MB}"
    local target_size_mb="${BUILD_CACHE_TARGET_SIZE_MB}"
    local stale_days="${BUILD_CACHE_STALE_DAYS}"

    if ! [[ "${max_size_mb}" =~ ^[0-9]+$ ]]; then
        max_size_mb=4096
    fi
    if ! [[ "${target_size_mb}" =~ ^[0-9]+$ ]]; then
        target_size_mb=3072
    fi
    if ! [[ "${stale_days}" =~ ^[0-9]+$ ]]; then
        stale_days=30
    fi
    if [ "${target_size_mb}" -gt "${max_size_mb}" ]; then
        target_size_mb="${max_size_mb}"
    fi

    mkdir -p "${BUILD_DIR}"
    prune_stale_build_cache_paths "${stale_days}"

    local initial_size_mb
    initial_size_mb=$(get_directory_size_mb "${BUILD_DIR}")
    if [ "${initial_size_mb}" -le "${max_size_mb}" ]; then
        build_cache_record_prune
        log_detail "Build cache size ${initial_size_mb}MB is under ${max_size_mb}MB"
        return 0
    fi

    log_item "Pruning build cache (${initial_size_mb}MB > ${max_size_mb}MB)"

    prune_inactive_build_outputs_to_target "${target_size_mb}" "${initial_size_mb}"
    local current_size_mb
    current_size_mb=$(get_directory_size_mb "${BUILD_DIR}")

    if [ "${current_size_mb}" -gt "${target_size_mb}" ] && is_truthy "${BUILD_CACHE_PRUNE_DEPENDENCIES_WHEN_OVERSIZED}"; then
        log_item "Opt-in dependency pruning enabled; clearing reusable package artifacts"
        reset_cached_dependency_products
        current_size_mb=$(get_directory_size_mb "${BUILD_DIR}")
    fi

    local reclaimed_mb=$((initial_size_mb - current_size_mb))
    if [ "${reclaimed_mb}" -gt 0 ]; then
        log_item "Reclaimed ${reclaimed_mb}MB from build cache (now ${current_size_mb}MB)"
    fi

    if [ "${current_size_mb}" -gt "${max_size_mb}" ]; then
        log_warning "Build cache remains large (${current_size_mb}MB); active compiled outputs and dependency artifacts were preserved."
    fi

    build_cache_record_prune
}

manage_build_cache() {
    mkdir -p "${BUILD_DIR}"

    if ! build_cache_acquire_lock; then
        return 0
    fi

    validate_build_cache_fingerprint || true
    validate_binary_artifact_cache || true
    prune_oversized_build_cache || true
    build_cache_release_lock
}

# --- Clang module-cache poisoning -------------------------------------------
# How it is used: parallel SwiftPM jobs share one Clang module cache
# (<config>/ModuleCache). Under parallel load its Foundation/AppKit entries
# can go bad, and every later job then fails with missing members on valid
# API (`RunLoop.main`, `Bundle.main`, `UserDefaults.standard`,
# `Thread.current`, …). Serial builds pass on the same sources, which is the
# tell. Clearing the cache and retrying once serially always recovers.

# True when a build log shows the poisoning signature. Kept narrow on purpose:
# a genuine typo (`Bundle.mian`) names a different member and never matches.
# The log must also be fresh (written during the current invocation) so a
# stale log from an earlier run — or verbose mode, which streams instead of
# logging — can never trigger a spurious retry.
swiftpm_module_cache_poison_detected() {
    local log_name="$1"
    local since_epoch="${2:-0}"
    local log_file="${BUILD_LOG_DIR}/${log_name}.log"

    [ -f "${log_file}" ] || return 1
    if [ "$(build_cache_path_mtime "${log_file}")" -lt "${since_epoch}" ]; then
        return 1
    fi

    grep -Eq "has no member '(main|current|standard)'" "${log_file}" ||
        grep -Eq "cannot infer contextual base in reference to member 'common'" "${log_file}" ||
        {
            # A corrupted SDK module can replace a C struct field with an
            # availability attribute, as seen in PostHog's crash reporter.
            grep -Eq "error: expected identifier" "${log_file}" &&
                grep -Eq "note: expanded from macro 'major'" "${log_file}" &&
                grep -Eq 'AvailabilityInternalLegacy\.h' "${log_file}"
        }
}

# Called only after a successful compile with the shared module-cache flags.
# Remove legacy copies for that configuration once the replacement is usable.
finish_swiftpm_cache_migration() {
    local config="$1"
    shift
    local flags=" $* "
    case "${flags}" in
        *" -module-cache-path -Xswiftc ${BUILD_DIR}/ModuleCache "*)
            [ -d "${BUILD_DIR}/ModuleCache" ] || return 0
            prune_path_if_exists "${BUILD_DIR}/${config}/ModuleCache"
            ;;
    esac
    case "${flags}" in
        *" -debug-info-format none "*)
            # SwiftPM leaves old dSYMs behind when switching symbol formats.
            find -H "${BUILD_DIR}/${config}" -maxdepth 1 -type d -name 'SortyApp.dSYM' \
                -exec rm -rf {} + 2>/dev/null || true
            ;;
    esac
}

reset_clang_module_caches() {
    local root
    while IFS= read -r root; do
        [ -n "${root}" ] || continue
        prune_path_if_exists "${root}/ModuleCache"
        prune_path_if_exists "${root}/debug/ModuleCache"
        prune_path_if_exists "${root}/release/ModuleCache"
        prune_path_if_exists "${root}/DerivedData/ModuleCache.noindex"
    done < <(build_cache_scratch_roots)
    log_detail "Cleared Clang module caches"
}

# Prints "$@" minus SwiftPM build-parallelism flags so a retry runs serially.
# Test-execution parallelism (--parallel) is preserved; only build jobs drop.
strip_parallel_job_flags() {
    local arg skip_next=false
    for arg in "$@"; do
        if [ "${skip_next}" = "true" ]; then
            skip_next=false
            continue
        fi
        case "${arg}" in
            -j)
                skip_next=true
                ;;
            -j[0-9]*|--jobs=*)
                ;;
            --jobs)
                skip_next=true
                ;;
            *)
                printf '%s\n' "${arg}"
                ;;
        esac
    done
}

print_build_cache_status() {
    local size_mb
    size_mb=$(get_directory_size_mb "${BUILD_DIR}" fresh)
    local input_hash dependency_hash toolchain_hash current_fingerprint stored_fingerprint
    input_hash="$(build_cache_input_hash)"
    dependency_hash="$(build_cache_dependency_hash)"
    toolchain_hash="$(build_cache_toolchain_hash)"
    current_fingerprint="${toolchain_hash}"
    stored_fingerprint="$(build_cache_state_value "compatibility_fingerprint")"

    echo "Build cache"
    echo "  Path: ${BUILD_DIR}"
    echo "  Size: ${size_mb}MB"
    echo "  Max: ${BUILD_CACHE_MAX_SIZE_MB}MB"
    echo "  Target: ${BUILD_CACHE_TARGET_SIZE_MB}MB"
    echo "  Stale days: ${BUILD_CACHE_STALE_DAYS}"
    echo "  Prune interval: ${BUILD_CACHE_PRUNE_INTERVAL_SECONDS}s"
    echo "  Stored fingerprint: ${stored_fingerprint}"
    echo "  Current fingerprint: ${current_fingerprint}"
    echo "  Fresh: $([ "${stored_fingerprint}" = "${current_fingerprint}" ] && echo "yes" || echo "no")"
    echo "  Last prune: $(cat "${BUILD_CACHE_LAST_PRUNE_FILE}" 2>/dev/null || echo "never")"
    echo "  Compiled outputs: $(get_directory_size_mb "${BUILD_DIR}/$(uname -m)-apple-macosx")MB"
    echo "  Dependency checkouts: $(get_directory_size_mb "${BUILD_DIR}/checkouts")MB"
    echo "  Binary artifacts: $(get_directory_size_mb "${BUILD_DIR}/artifacts")MB"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-prune}" in
        prune)
            BUILD_CACHE_FORCE_PRUNE="${BUILD_CACHE_FORCE_PRUNE:-true}"
            manage_build_cache
            ;;
        status)
            print_build_cache_status
            ;;
        clear-module-cache)
            reset_clang_module_caches
            ;;
        *)
            echo "Usage: $0 [prune|status|clear-module-cache]"
            exit 1
            ;;
    esac
fi
