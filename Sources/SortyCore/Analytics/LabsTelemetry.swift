//
//  LabsTelemetry.swift
//  Sorty
//
//  Bounded analytics for Sorty Labs features and remotely tested experiments.
//

import Foundation

/// One place for Labs event names and values, so every property stays a small
/// fixed set. Never pass file names, paths, rule text or folder names here.
/// Events go through `AnalyticsManager`, which drops them without consent.
@MainActor
package enum LabsTelemetry {
    /// Where a Labs action happened.
    package enum Surface: String {
        case menuBar = "menu_bar"
        case watchedFolders = "watched_folders"
        case settings
        case exclusions
    }

    // MARK: - Expiring Files

    private static var lastScanSignature: String?
    private static var lastScanReportedAt: Date?

    /// Scan health while the feature is experimental: per-kind counts, how long
    /// it took, and whether Desktop or Downloads couldn't be read. Scans run on
    /// every popover and menu open, so this reports only when the result
    /// changes or 30 minutes have passed.
    package static func expiringScanned(
        candidates: [ExpiringFileCandidate],
        unreadableFolders: Int,
        finishedDetection: Bool,
        duration: TimeInterval,
        now: Date = Date()
    ) {
        func bucket(_ reasons: Set<ExpiringFileCandidate.Reason>) -> String {
            AnalyticsManager.countBucket(candidates.filter { reasons.contains($0.reason) }.count)
        }
        let properties: [String: Any] = [
            "count_bucket": AnalyticsManager.countBucket(candidates.count),
            "installer_count_bucket": bucket([.installer, .installed]),
            "archive_count_bucket": bucket([.archive, .extracted]),
            "screenshot_count_bucket": bucket([.screenshot]),
            "finished_count_bucket": bucket([.installed, .extracted]),
            "unreadable_folder_count": min(unreadableFolders, 3),
            "finished_detection": finishedDetection,
            "scan_duration_ms": Int((max(0, duration) * 1_000).rounded()),
        ]
        let signature = ["count_bucket", "installer_count_bucket", "archive_count_bucket", "screenshot_count_bucket",
                         "finished_count_bucket", "unreadable_folder_count", "finished_detection"]
            .map { "\(properties[$0] ?? "")" }
            .joined(separator: "|")
        if signature == lastScanSignature, let last = lastScanReportedAt, now.timeIntervalSince(last) < 30 * 60 {
            return
        }
        lastScanSignature = signature
        lastScanReportedAt = now
        let outcome = unreadableFolders > 0 ? "partial" : (candidates.isEmpty ? "empty" : "success")
        capture(subfeature: "expiring_files", action: "scan_completed", outcome: outcome, properties: properties)
    }

    /// The review list was opened, with how many files were waiting.
    package static func expiringReviewOpened(from surface: Surface, waiting: Int) {
        capture(
            subfeature: "expiring_files",
            action: "review_opened",
            outcome: waiting > 0 ? "success" : "empty",
            properties: [
                "source": surface.rawValue,
                "count_bucket": AnalyticsManager.countBucket(waiting),
            ]
        )
    }

    /// Result of a Move to Trash. `finished` counts files offered early by
    /// Spot Finished Downloads, so its share of real cleanups is visible.
    package static func expiringTrashed(
        from surface: Surface,
        offered: Int,
        selected: Int,
        trashed: Int,
        changed: Int,
        failed: Int,
        finished: Int
    ) {
        let outcome = switch (trashed, changed + failed) {
        case (0, _): "failed"
        case (_, 0): "success"
        default: "partial"
        }
        var properties: [String: Any] = [
            "source": surface.rawValue,
            "count_bucket": AnalyticsManager.countBucket(trashed),
            "selection_kind": selected >= offered ? "all" : "subset",
            "result_kind": finished == 0 ? "age_only" : (finished == selected ? "finished_only" : "mixed"),
        ]
        switch (changed > 0, failed > 0) {
        case (true, true): properties["failure_reason"] = "changed_and_trash_failed"
        case (true, false): properties["failure_reason"] = "changed_since_scan"
        case (false, true): properties["failure_reason"] = "trash_failed"
        case (false, false): break
        }
        capture(subfeature: "expiring_files", action: "move_to_trash", outcome: outcome, properties: properties)
    }

    /// A file was kept. The reason shows which kinds Sorty offers too eagerly.
    package static func expiringKept(from surface: Surface, reason: ExpiringFileCandidate.Reason) {
        capture(
            subfeature: "expiring_files",
            action: "file_kept",
            outcome: "success",
            properties: [
                "source": surface.rawValue,
                "result_kind": reasonIdentifier(reason),
            ]
        )
    }

    /// The age limit changed. Presets report their value; anything else is `custom`.
    package static func expiringAgeChanged(to days: Int, presets: [Int]) {
        capture(
            subfeature: "expiring_files",
            action: "age_changed",
            outcome: "success",
            properties: [
                "source": Surface.settings.rawValue,
                "selection_kind": presets.contains(days) ? "\(days)_days" : "custom",
            ]
        )
    }

    nonisolated static func reasonIdentifier(_ reason: ExpiringFileCandidate.Reason) -> String {
        switch reason {
        case .installer: "installer"
        case .archive: "archive"
        case .screenshot: "screenshot"
        case .markedByYou: "marked"
        case .installed: "app_installed"
        case .extracted: "already_extracted"
        }
    }

    // MARK: - Settings

    /// A Labs feature's shortcut in Settings was used to jump to its screen.
    package static func openedFromSettings(_ feature: SortyLabsFeature) {
        capture(
            subfeature: featureIdentifier(feature),
            action: "opened_from_settings",
            outcome: "success",
            properties: ["source": Surface.settings.rawValue]
        )
    }

    /// The In Testing card finished loading. Only the count is sent; flag
    /// keys stay out, matching the disabled flag evaluation events.
    package static func remoteExperimentsShown(count: Int) {
        capture(
            subfeature: "remote_experiments",
            action: "card_viewed",
            outcome: count > 0 ? "success" : "empty",
            properties: [
                "source": Surface.settings.rawValue,
                "count_bucket": AnalyticsManager.countBucket(count),
            ]
        )
    }

    nonisolated static func featureIdentifier(_ feature: SortyLabsFeature) -> String {
        switch feature {
        case .expiringFiles: "expiring_files"
        }
    }

    /// Sends the PostHog event and leaves a Sentry breadcrumb, so a crash or
    /// handled error in a Labs feature shows the steps that led to it.
    private static func capture(subfeature: String, action: String, outcome: String, properties: [String: Any]) {
        ReliabilityManager.shared.recordWorkflow(workflow: subfeature, stage: action, outcome: outcome)
        AnalyticsManager.shared.captureFeature(
            feature: "labs",
            subfeature: subfeature,
            action: action,
            outcome: outcome,
            properties: properties
        )
    }
}
