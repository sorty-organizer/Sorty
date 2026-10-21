import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct WatchedFolderNerdStats: View {
    @SortyHotReload private var hotReload
    let folder: WatchedFolder
    let activity: WatchedFolderActivity?
    @EnvironmentObject private var history: OrganizationHistory

    /// Memoizes the history scan across rows and body evaluations. Keyed by
    /// folder path + history revision: entries only change when the revision
    /// bumps, and the filter walks every entry.
    private final class NerdRunsCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: [OrganizationHistoryEntry]] = [:]

        func runs(for key: String, compute: () -> [OrganizationHistoryEntry]) -> [OrganizationHistoryEntry] {
            lock.withLock {
                if let cached = storage[key] {
                    return cached
                }
                let built = compute()
                if storage.count > 32 {
                    storage.removeAll()
                }
                storage[key] = built
                return built
            }
        }
    }

    private static let runsCache = NerdRunsCache()

    private var recentRuns: [OrganizationHistoryEntry] {
        let folderPath = URL(fileURLWithPath: folder.path).standardizedFileURL.path
        let key = "\(folderPath)#\(history.revision)"
        return Self.runsCache.runs(for: key) {
            history.entries.filter {
                $0.source == .watchedFolder
                    && URL(fileURLWithPath: $0.directoryPath).standardizedFileURL.path == folderPath
            }
        }
    }

    private var completedRuns: [OrganizationHistoryEntry] {
        recentRuns.filter { $0.status == .completed }
    }

    private var filesOrganized: Int {
        completedRuns.reduce(0) { $0 + $1.filesOrganized }
    }

    private var successRate: String {
        guard !recentRuns.isEmpty else { return "No runs" }
        let rate = Double(completedRuns.count) / Double(recentRuns.count) * 100
        return rate.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private var averageFilesPerRun: String {
        guard !completedRuns.isEmpty else { return "0" }
        let average = Double(filesOrganized) / Double(completedRuns.count)
        return average.formatted(.number.precision(.fractionLength(0...1)))
    }

    private var totalAITime: String {
        let duration = recentRuns.compactMap { $0.plan?.generationStats?.duration }.reduce(0, +)
        return GenerationStats.formatDuration(duration)
    }

    private var estimatedCost: String {
        let cost = recentRuns
            .compactMap { $0.plan?.generationStats?.computedCost }
            .reduce(Decimal.zero, +)
        return GenerationStats.formatCost(cost)
    }

    private var lastRun: String {
        guard let timestamp = recentRuns.first?.timestamp else { return "Never" }
        return timestamp.formatted(.relative(presentation: .named))
    }

    private var queuedFileCount: Int {
        guard let activity else { return 0 }
        switch activity {
        case .waitingForStability(let count, _),
             .queued(let count, _),
             .retrying(let count, _, _),
             .parked(let count),
             .running(let count),
             .awaitingReview(let count):
            return count
        }
    }

    private var activityLabel: String {
        guard let activity else { return "Idle" }
        switch activity {
        case .waitingForStability: return "Stabilizing"
        case .queued: return "Queued"
        case .retrying: return "Retrying"
        case .parked: return "Parked"
        case .running: return "Running"
        case .awaitingReview: return "Review"
        }
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 10, maximum: .infinity)),
                GridItem(.flexible(minimum: 10, maximum: .infinity)),
                GridItem(.flexible(minimum: 10, maximum: .infinity))
            ],
            spacing: 8
        ) {
            NerdStatPillExpanded(
                icon: "tray.full",
                color: .indigo,
                title: "Queued files",
                value: GenerationStats.formatCount(queuedFileCount),
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "waveform.path.ecg",
                color: .blue,
                title: "Activity",
                value: activityLabel,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "play.circle",
                color: .orange,
                title: "Runs",
                value: GenerationStats.formatCount(recentRuns.count),
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "checkmark.circle",
                color: .green,
                title: "Success rate",
                value: successRate,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "doc.on.doc",
                color: .teal,
                title: "Files organized",
                value: GenerationStats.formatCount(filesOrganized),
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "chart.bar",
                color: .purple,
                title: "Avg files per run",
                value: averageFilesPerRun,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "clock",
                color: .blue,
                title: "Total AI time",
                value: totalAITime,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "dollarsign.circle",
                color: .green,
                title: "Estimated cost",
                value: estimatedCost,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "calendar",
                color: .secondary,
                title: "Last run",
                value: lastRun,
                unit: nil
            )
        }
        .accessibilityElement(children: .contain)
    }
}
