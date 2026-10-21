import AppKit
import Foundation
import SwiftUI
import Beam

// MARK: - Redesigned Header

struct DuplicatesHeaderNew: View {
    @SortyHotReload private var hotReload
    @ObservedObject var manager: DuplicateDetectionManager
    let currentDirectory: URL?
    let isCleaningUp: Bool
    let onSelectDirectory: () -> Void
    let onScan: () -> Void
    let onCancel: () -> Void
    let onBulkDelete: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            headerLayout(spacing: 20, showsFullControls: true)
                .frame(minWidth: 760)
            headerLayout(spacing: 12, showsFullControls: false)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var isScanInProgress: Bool {
        manager.isScanning || manager.state == .preparing
    }

    /// Path-keyed folder icon cache. The header re-renders on every scan
    /// progress tick (twice, through `ViewThatFits`), so an uncached
    /// NSWorkspace lookup would hand AppKit a new image each time.
    nonisolated(unsafe) private static let folderIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        return cache
    }()

    private static func folderIcon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = folderIconCache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        folderIconCache.setObject(icon, forKey: key)
        return icon
    }

    private func headerLayout(spacing: CGFloat, showsFullControls: Bool) -> some View {
        HStack(spacing: spacing) {
            // Left Side: Title & Target Folder
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 44, height: 44)

                    Image(systemName: "doc.on.doc.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Files")
                        .font(.headline)
                        .lineLimit(1)

                    if let dir = currentDirectory {
                        Button(action: onSelectDirectory) {
                            HStack(spacing: 4) {
                                AppKitImageView(
                                    image: Self.folderIcon(for: dir.path),
                                    size: CGSize(width: 16, height: 16)
                                )
                                .frame(width: 16, height: 16)
                                Text(dir.lastPathComponent)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                        .help(PrivacyPathMasker.redactedPath(dir.path))
                    } else {
                        Text("No folder selected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            .layoutPriority(1)

            Spacer()

            // Right Side: Controls
            HStack(spacing: showsFullControls ? 12 : 8) {
                HStack(spacing: 8) {
                    Button(action: onSettings) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .systemLiquidGlassButton()
                    .help("Detection Settings")
                    .accessibilityLabel("Duplicate detection settings")
                    .disabled(isScanInProgress)

                    if manager.exactGroupCount > 0 && !isScanInProgress {
                        Button {
                            onBulkDelete()
                        } label: {
                            Label(
                                showsFullControls ? "Clean Up Exact Copies" : "Clean Up",
                                systemImage: "trash"
                            )
                        }
                        .buttonStyle(.sortyPrimary(size: .small))
                        .tint(.red)
                        .disabled(isCleaningUp)
                        .help("Keep one preferred copy from every exact-match group and move the rest to Trash")
                    }

                    if isScanInProgress {
                        Button(action: onCancel) {
                            Label("Cancel", systemImage: "xmark")
                        }
                        .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))
                        .tint(.red)
                    } else if manager.lastScanDate == nil {
                        Button(action: onScan) {
                            Label(
                                showsFullControls ? "Start Scan" : "Scan", systemImage: "play.fill")
                        }
                        .buttonStyle(.sortyPrimary(size: .small))
                        .disabled(currentDirectory == nil)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
    }
}

// MARK: - Components

struct DuplicatesResultsSidebarHeader: View {
    @SortyHotReload private var hotReload
    @ObservedObject var manager: DuplicateDetectionManager
    let showsStats: Bool
    let onScanAgain: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsUnavailableFiles = false
    @AppStorage("duplicates.semanticCleanupNoticeDismissed")
    private var hasDismissedSemanticCleanupNotice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review groups")
                    .font(.headline)

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .numericTextTransition(animationValue: summaryText)
            }

            if showsStats {
                DuplicatesNerdStatsStrip(manager: manager)
            }

            if manager.unreadableFileCount > 0 {
                Button {
                    HapticFeedbackManager.shared.selection()
                    showsUnavailableFiles.toggle()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                        Text(
                            "\(manager.unreadableFileCount) file\(manager.unreadableFileCount == 1 ? " was" : "s were") unavailable and excluded from these results."
                        )
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .numericTextTransition(animationValue: manager.unreadableFileCount)
                .accessibilityHint("Shows the unavailable files and recovery options")
                .popover(isPresented: $showsUnavailableFiles, arrowEdge: .trailing) {
                    UnavailableDuplicateFilesPopover(
                        files: manager.unavailableFiles,
                        onScanAgain: {
                            showsUnavailableFiles = false
                            onScanAgain()
                        }
                    )
                }
            }

            if manager.semanticSkippedFileCount > 0 {
                Label(
                    "Exact duplicate results are complete. Similarity matching was skipped for this large folder to keep resource use stable.",
                    systemImage: "leaf"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if manager.semanticGroupCount > 0 && !hasDismissedSemanticCleanupNotice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Cleanup All only removes exact duplicates.", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    Button("OK") {
                        HapticFeedbackManager.shared.tap()
                        withAnimation(noticeDismissAnimation) {
                            hasDismissedSemanticCleanupNotice = true
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                }
                .font(.caption)
                .transition(noticeDismissTransition)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var noticeDismissAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    private var noticeDismissTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    private var summaryText: String {
        let exact = "\(manager.exactGroupCount) exact group\(manager.exactGroupCount == 1 ? "" : "s")"
        let similar = "\(manager.semanticGroupCount) similar file\(manager.semanticGroupCount == 1 ? "" : "s")"
        let recoverable = "\(manager.formattedSavings) safely recoverable"
        return [exact, similar, recoverable].joined(separator: " • ")
    }
}
