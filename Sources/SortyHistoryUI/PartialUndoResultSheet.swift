import AppKit
import SwiftUI

struct PreflightValidationResult {
    let availableCount: Int
    let missingFiles: [String]
    let directoryIssues: [String]

    var hasIssues: Bool { !missingFiles.isEmpty || !directoryIssues.isEmpty }
}

/// Result shown when an undo operation partially succeeds
struct PartialUndoResult {
    let successCount: Int
    let missingFiles: [String]
    let failedOperationCount: Int
    let directoryPath: String

    var folderName: String {
        URL(fileURLWithPath: directoryPath).lastPathComponent
    }
}

// MARK: - Partial Undo Result Sheet

struct PartialUndoResultSheet: View {
    @SortyHotReload private var hotReload
    let result: PartialUndoResult
    let onDismiss: () -> Void

    @State private var isHoveredOpenFolder = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange.gradient)
                    .accessibilityHidden(true)

                Text("Partial Undo Complete")
                    .font(.title2.bold())

                Text("Some files could not be restored")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Stats
            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("\(result.successCount)")
                        .font(.title.bold())
                        .foregroundStyle(.green)
                        .numericTextTransition(animationValue: result.successCount)
                    Text("Restored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 40)

                VStack(spacing: 4) {
                    Text("\(result.missingFiles.count)")
                        .font(.title.bold())
                        .foregroundStyle(.orange)
                        .numericTextTransition(animationValue: result.missingFiles.count)
                    Text("Missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if result.failedOperationCount > 0 {
                    Divider()
                        .frame(height: 40)

                    VStack(spacing: 4) {
                        Text("\(result.failedOperationCount)")
                            .font(.title.bold())
                            .foregroundStyle(.red)
                            .numericTextTransition(
                                animationValue: result.failedOperationCount
                            )
                        Text("Failed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 16)

            Divider()

            // Missing files list
            if !result.missingFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Files Not Found", systemImage: "questionmark.folder")
                            .font(.headline)
                        Spacer()
                        Text("\(result.missingFiles.count) file\(result.missingFiles.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .numericTextTransition(
                                animationValue: result.missingFiles.count
                            )
                    }

                    Text("These files may have been moved, renamed, or deleted:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(result.missingFiles.enumerated()), id: \.offset) { _, fileName in
                                let displayName = FeatureFlags.privacyModeEnabled
                                    ? PrivacyPathMasker.redactedText(fileName)
                                    : fileName
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.questionmark")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                    Text(displayName)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.08))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .padding(16)
            }

            Spacer(minLength: 0)

            // Actions
            VStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: result.directoryPath)
                } label: {
                    Label {
                        Text("Open Folder in Finder")
                    } icon: {
                        Image(systemName: isHoveredOpenFolder ? "arrow.up.right" : "folder")
                            .contentTransition(.symbolEffect(.replace))
                            .transaction { transaction in
                                if reduceMotion {
                                    transaction.disablesAnimations = true
                                }
                            }
                    }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.sortyBordered)
                .scaleEffect(isHoveredOpenFolder ? 1.02 : 1.0)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                    value: isHoveredOpenFolder
                )
                .onHover { hovering in
                    if hovering && !isHoveredOpenFolder {
                        HapticFeedbackManager.shared.selection()
                    }
                    withAnimation(
                        reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)
                    ) {
                        isHoveredOpenFolder = hovering
                    }
                }
                .accessibilityIdentifier("OpenFolderButton")

                Button("Done") {
                    HapticFeedbackManager.shared.tap()
                    onDismiss()
                }
                .buttonStyle(.sortyProminent)
                .controlSize(.large)
                .accessibilityIdentifier("DismissPartialResultButton")
            }
            .padding(20)
        }
        .frame(minWidth: 400, idealWidth: 400, maxWidth: 400, minHeight: 450)
        .modalBounce()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Partial undo complete. \(result.successCount) files restored, \(result.missingFiles.count) files not found.")
    }
}
