import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Directory Header

struct DirectoryHeader: View {
    @SortyHotReload private var hotReload
    let url: URL
    let mode: OrganizationMode
    let onBack: () -> Void
    let onClear: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringPath = false

    var body: some View {
        HStack(spacing: 12) {
            GlassyBackButton(action: onBack)
                .padding(.trailing, 4)

            Button(action: revealSelectedDirectory) {
                FolderThumbnailView(url: url, size: CGSize(width: 32, height: 32))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal \(url.lastPathComponent) in Finder")
            .accessibilityLabel("Reveal \(url.lastPathComponent) in Finder") // [VERIFY] confirm label matches intent

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: mode.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .symbolReplaceTransition(animationValue: mode)
                        .accessibilityHidden(true)

                    Text(mode.workflowTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .numericTextTransition(animationValue: mode)
                }
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(action: revealSelectedDirectory) {
                    HStack(spacing: 5) {
                        PrivacySensitivePathText(path: url.deletingLastPathComponent().path)
                            .lineLimit(1)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                            .opacity(isHoveringPath ? 1 : 0)
                            .offset(
                                x: reduceMotion || isHoveringPath ? 0 : -3,
                                y: reduceMotion || isHoveringPath ? 0 : 3
                            )
                            .scaleEffect(reduceMotion || isHoveringPath ? 1 : 0.75)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Reveal \(url.lastPathComponent) in Finder")
                .accessibilityLabel("Reveal \(url.lastPathComponent) in Finder") // [VERIFY] confirm label matches intent
                .animation(
                    reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                    value: isHoveringPath
                )
                .onHover { hovering in
                    isHoveringPath = hovering
                }
            }

            Spacer()

            Button {
                onClear()
            } label: {
                Label("Change Folder", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.sortyBordered(size: .small))
            .accessibilityIdentifier("ChangeFolderButton")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func revealSelectedDirectory() {
        HapticFeedbackManager.shared.tap()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
}

struct SetupRepairGateView: View {
    @SortyHotReload private var hotReload
    let message: String
    let onStart: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Finish Provider Setup")
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                Button("Open Provider Settings", action: onOpenSettings)
                    .buttonStyle(.sortyBordered)
                    .accessibilityIdentifier("OpenProviderSettingsForRepairButton")

                Button("Try Organizing", action: onStart)
                    .buttonStyle(.sortyProminent)
                    .accessibilityIdentifier("RetryOrganizationForRepairButton")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
