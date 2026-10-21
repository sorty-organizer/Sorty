import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings
extension LearningsView {
    // MARK: - Settings (Inline)

    var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    settingsRowLabel(
                        systemImage: "calendar.badge.clock",
                        title: "Data Retention",
                        detail: "How long to keep learning data"
                    )
                    Spacer()
                    Picker("", selection: $manager.dataRetentionDays) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                        Text("Forever").tag(0)
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .frame(width: 120)
                    .labelsHidden()
                    .onChange(of: manager.dataRetentionDays) {
                        HapticFeedbackManager.shared.selection()
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)

                Divider().padding(.leading, 40)

                HStack(spacing: 12) {
                    settingsRowLabel(
                        systemImage: "person.text.rectangle",
                        title: "Learning Data",
                        detail: "Import, export, or delete your learning data"
                    )
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Import") {
                            requestSensitiveAction(
                                reason: "Authenticate to import a learnings profile."
                            ) {
                                presentFileImporter(.learningsProfile)
                            }
                        }
                        Button("Export") {
                            requestSensitiveAction(
                                reason: "Authenticate to export your learnings profile."
                            ) {
                                exportProfile()
                            }
                        }
                        Button(role: .destructive) {
                            confirmDeleteAllLearningData()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.sortyBordered(intent: .destructive, size: .small))
                        .accessibilityHint("Permanently deletes all learning data")
                    }
                    .buttonStyle(.sortyBordered(size: .small))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Learnings settings")
        }
    }

    func settingsRowLabel(
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundColor(.blue)
                .font(.body.bold())
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    var referenceDirectoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teach Sorty with example folders")
                        .font(.subheadline.bold())
                    Text(
                        "Add folders that are already organized well. Sorty uses a matching example only when the files in a preview are similar. Representative filenames may be sent to your selected AI provider. Sorty never changes the example folder."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !manager.modelDirectories.isEmpty {
                    Text("\(manager.modelDirectories.filter(\.isEnabled).count) active")
                        .font(.caption.bold())
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .systemLiquidGlassBackground(cornerRadius: 999, interactive: false)
                        .clipShape(Capsule())
                        .numericTextTransition(
                            animationValue: manager.modelDirectories.filter(\.isEnabled).count
                        )
                    Button {
                        presentFileImporter(.modelDirectories)
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.sortyPrimary(size: .small))
                    .accessibilityIdentifier("AddModelDirectoryButton")
                }
            }

            if manager.modelDirectories.isEmpty {
                VStack(spacing: 10) {
                    if let image = SortyResources.image(named: "TeachSortyExampleFolders") {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .opacity(emptyExampleFoldersHasAppeared ? 1 : 0)
                            .scaleEffect(emptyExampleFoldersHasAppeared ? 1 : 0.8)
                            .animation(
                                reduceMotion
                                    ? .easeOut(duration: 0.12)
                                    : .spring(response: 0.5, dampingFraction: 0.7).delay(0.1),
                                value: emptyExampleFoldersHasAppeared
                            )
                            .accessibilityHidden(true)
                    }
                    Text("No reference directories")
                        .font(.subheadline.bold())
                        .opacity(emptyExampleFoldersHasAppeared ? 1 : 0)
                        .offset(y: emptyExampleFoldersHasAppeared ? 0 : 8)
                        .animation(
                            reduceMotion
                                ? .easeOut(duration: 0.12)
                                : .spring(response: 0.5, dampingFraction: 0.8).delay(0.2),
                            value: emptyExampleFoldersHasAppeared
                        )
                    Button {
                        presentFileImporter(.modelDirectories)
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.sortyPrimary(size: .small))
                    .accessibilityIdentifier("EmptyStateAddModelDirectoryButton")
                    .opacity(emptyExampleFoldersHasAppeared ? 1 : 0)
                    .offset(y: emptyExampleFoldersHasAppeared ? 0 : 10)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.12)
                            : .spring(response: 0.5, dampingFraction: 0.8).delay(0.3),
                        value: emptyExampleFoldersHasAppeared
                    )
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .task {
                    guard !emptyExampleFoldersHasAppeared else { return }
                    if !reduceMotion {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard !Task.isCancelled else { return }
                    emptyExampleFoldersHasAppeared = true
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(manager.modelDirectories) { directory in
                        ModelDirectoryRow(directory: directory, manager: manager)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 16, interactive: false)
    }

    // MARK: - Helpers

    func presentFileImporter(_ importer: ActiveFileImporter) {
        HapticFeedbackManager.shared.tap()
        activeFileImporter = importer
        isShowingFileImporter = true
    }

    func requestSensitiveAction(
        reason: String,
        pendingAction: PendingControlAction? = nil,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        if let pendingAction {
            guard self.pendingControlAction == nil else { return }
            showPendingControlAction(pendingAction)
        }

        if !FeatureFlags.sensitiveActionAuthenticationEnabled {
            onSuccess()
            return
        }

        Task { @MainActor in
            let didAuthenticate = await SecurityManager.shared.authenticateForSensitiveAction(
                reason: reason)
            guard didAuthenticate else {
                HapticFeedbackManager.shared.error()
                if pendingAction != nil {
                    finishPendingControlAction(
                        title: "Authentication Cancelled",
                        message: "No changes were made.",
                        icon: "xmark.circle.fill",
                        iconColor: .orange
                    )
                }
                return
            }
            onSuccess()
        }
    }

    // MARK: - Export / Import

    func exportProfile() {
        guard manager.currentProfile != nil else { return }
        let panel = NSSavePanel()
        let learningsType = UTType(filenameExtension: "learnings", conformingTo: .json) ?? .json
        panel.allowedContentTypes = [learningsType]
        panel.nameFieldStringValue =
            "learnings_profile_\(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-")).learnings"
        panel.message = "Export Learning Profile"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let summary = try manager.exportProfile(to: url)
                HapticFeedbackManager.shared.success()
                NotificationManager.shared.showHUDInfo(
                    title: "Learning Profile Exported",
                    message: "Saved \(summary.totalRecordCount) learning records with profile settings and integrity metadata.",
                    icon: "checkmark.circle.fill",
                    iconColor: .green
                )
            } catch {
                DebugLogger.log("Failed to export profile: \(error)")
                HapticFeedbackManager.shared.error()
                manager.error = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func handleModelDirectoryImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var addedCount = 0
            var duplicateCount = 0
            var limitReached = false
            for url in urls {
                let hasScopedAccess = url.startAccessingSecurityScopedResource()
                defer { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }
                switch manager.addModelDirectoryWithResult(url: url) {
                case .added:
                    addedCount += 1
                case .duplicate:
                    duplicateCount += 1
                case .activeLimitReached:
                    limitReached = true
                }
            }
            if addedCount > 0 {
                HapticFeedbackManager.shared.success()
                NotificationManager.shared.showHUDInfo(
                    title: addedCount == 1 ? "Example Folder Added" : "Example Folders Added",
                    message: "Sorty is scanning \(addedCount) folder\(addedCount == 1 ? "" : "s") now.",
                    icon: "folder.badge.plus",
                    iconColor: .teal
                )
            } else if limitReached {
                HapticFeedbackManager.shared.error()
                NotificationManager.shared.showHUDInfo(
                    title: "Five Example Folders Active",
                    message: "Pause or remove one before adding another.",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange
                )
            } else if duplicateCount > 0 {
                HapticFeedbackManager.shared.error()
                NotificationManager.shared.showHUDInfo(
                    title: "Folder Already Added",
                    message: "Sorty is already learning from that folder.",
                    icon: "folder.badge.questionmark",
                    iconColor: .orange
                )
            } else {
                HapticFeedbackManager.shared.error()
            }
        case .failure(let error):
            DebugLogger.log("Model directory import failed: \(error)")
            HapticFeedbackManager.shared.error()
        }
    }

    func handleProfileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let importResult = try await manager.importProfile(from: url)
                    HapticFeedbackManager.shared.success()
                    var details = [
                        "Merged \(importResult.importedRecordCount) records with \(importResult.previousRecordCount) existing records.",
                        "The profile now contains \(importResult.resultingRecordCount) records."
                    ]
                    if importResult.restoredSettingCount > 0 {
                        details.append("Restored \(importResult.restoredSettingCount) learning settings.")
                    }
                    if importResult.omittedByRetentionPolicy > 0 {
                        details.append(
                            "\(importResult.omittedByRetentionPolicy) older records were omitted by your retention policy."
                        )
                    }
                    if importResult.wasLegacyProfile {
                        details.append("The legacy profile was upgraded to the current format.")
                    }
                    NotificationManager.shared.showHUDInfo(
                        title: "Learning Profile Imported",
                        message: details.joined(separator: " "),
                        icon: "checkmark.circle.fill",
                        iconColor: .green
                    )
                } catch {
                    DebugLogger.log("Failed to import profile: \(error)")
                    HapticFeedbackManager.shared.error()
                    manager.error = "Import failed: \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            DebugLogger.log("Import failed: \(error)")
        }
    }
}
