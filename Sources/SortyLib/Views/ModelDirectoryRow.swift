import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model Directory Row

struct ModelDirectoryRow: View {
    @SortyHotReload private var hotReload
    let directory: ReferenceModelDirectory
    @ObservedObject var manager: LearningsManager
    @State private var isHovered = false
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scanState: ReferenceDirectoryScanState {
        manager.modelDirectoryScanState(id: directory.id)
    }

    private var status: (text: String, icon: String, color: Color) {
        switch scanState {
        case .scanning:
            return ("Scanning folder structure and filenames", "arrow.triangle.2.circlepath", .blue)
        case .ready:
            return ("Ready for matching previews", "checkmark.circle.fill", .teal)
        case .warning(let message):
            return (message, "exclamationmark.triangle.fill", .orange)
        case .failed(let message):
            return ("Scan failed: \(message)", "xmark.circle.fill", .red)
        case .unavailable:
            return ("Folder is missing or unavailable", "folder.badge.questionmark", .orange)
        case .paused:
            return ("Paused and not used in previews", "pause.circle.fill", .secondary)
        }
    }

    private var learnedSummary: String? {
        guard let snapshot = directory.scanSnapshot else { return nil }
        let categories = snapshot.fileCategoryDistribution
            .filter { $0.value > 0 }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.rawValue < $1.key.rawValue
            }
            .prefix(3)
            .map { $0.key.rawValue.capitalized }
        let conventions = (snapshot.namingConventions + snapshot.fileNamingConventions)
            .orderedDeduplicated()
            .prefix(2)
        var parts = [
            "\(snapshot.totalFolderCount.formatted()) folders",
            "\(snapshot.totalFileCount.formatted()) files",
            "up to \(snapshot.maximumDepth.formatted()) levels deep",
        ]
        if categories.isEmpty == false {
            parts.append(categories.joined(separator: ", "))
        }
        if conventions.isEmpty == false {
            parts.append(conventions.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        var parts = [directory.displayName, status.text]
        if let learnedSummary {
            parts.append(learnedSummary)
        }
        if settingsViewModel.config.showStatsForNerds,
           let scannedAt = directory.lastScannedAt {
            parts.append("Last scanned \(scannedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: directory.isAccessible ? "folder.fill" : "folder.badge.questionmark")
                    .font(.body.bold())
                    .symbolReplaceTransition(animationValue: directory.isAccessible)
                    .foregroundStyle(status.color)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(directory.displayName)
                        .font(.subheadline.bold())
                        .foregroundStyle(directory.isEnabled ? .primary : .secondary)
                    PrivacySensitivePathText(path: directory.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        if scanState == .scanning {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: status.icon)
                                .accessibilityHidden(true)
                        }
                        Text(status.text)
                    }
                    .font(.caption)
                    .foregroundStyle(status.color)
                    .lineLimit(2)
                    if let learnedSummary {
                        Text(learnedSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if settingsViewModel.config.showStatsForNerds,
                       let scannedAt = directory.lastScannedAt {
                        Text("Last scanned \(scannedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityRepresentation {
                    Text(accessibilitySummary)
                }

                Spacer(minLength: 8)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons }
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(isHovered ? 0.08 : 0.03))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { HapticFeedbackManager.shared.selection() }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if directory.isAccessible {
            Button {
                HapticFeedbackManager.shared.tap()
                Task { @MainActor in
                    await manager.rescanModelDirectory(id: directory.id)
                    switch manager.modelDirectoryScanState(id: directory.id) {
                    case .ready, .warning:
                        HapticFeedbackManager.shared.success()
                        AccessibilityNotification.Announcement(
                            "Finished scanning \(directory.displayName)"
                        ).post()
                    case .failed, .unavailable:
                        HapticFeedbackManager.shared.error()
                        AccessibilityNotification.Announcement(
                            "Could not scan \(directory.displayName)"
                        ).post()
                    case .scanning, .paused:
                        break
                    }
                }
            } label: {
                Label(isFailedScan ? "Retry" : "Rescan", systemImage: "arrow.clockwise")
                    .font(.caption.bold())
            }
            .systemLiquidGlassButton()
            .disabled(scanState == .scanning)
            .accessibilityIdentifier("RescanModelDirectoryButton_\(directory.id)")

            Button {
                HapticFeedbackManager.shared.tap()
                let didToggle = manager.toggleModelDirectory(id: directory.id)
                if didToggle == false {
                    HapticFeedbackManager.shared.error()
                    NotificationManager.shared.showHUDInfo(
                        title: "Five Example Folders Active",
                        message: "Pause another folder before using this one.",
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .orange
                    )
                }
            } label: {
                Label(
                    directory.isEnabled ? "Pause" : "Use",
                    systemImage: directory.isEnabled ? "pause" : "play"
                )
                .font(.caption.bold())
            }
            .systemLiquidGlassButton()
            .accessibilityIdentifier("ModelDirectoryToggle_\(directory.id)")

            Button {
                HapticFeedbackManager.shared.tap()
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .font(.caption.bold())
            }
            .systemLiquidGlassButton()
            .accessibilityIdentifier("OpenModelDirectoryButton_\(directory.id)")
        }

        Button {
            HapticFeedbackManager.shared.tap()
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                manager.removeModelDirectory(id: directory.id)
            }
        } label: {
            Label("Remove", systemImage: "xmark")
                .font(.caption.bold())
        }
        .systemLiquidGlassButton()
        .accessibilityIdentifier("RemoveModelDirectoryButton_\(directory.id)")
    }

    private var isFailedScan: Bool {
        if case .failed = scanState { return true }
        return false
    }
}
