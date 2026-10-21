import AppKit
import Foundation
import SwiftUI
import Beam

struct UnifiedDuplicateGroupRow: View {
    @SortyHotReload private var hotReload
    let group: UnifiedDuplicateGroup

    /// Memoizes the folder summary across rows and body evaluations. The
    /// summary parses every file URL; the cache key is the full path list so
    /// a changed group can never serve a stale label.
    final class FolderSummaryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func summary(for key: String, compute: () -> String) -> String {
            lock.withLock {
                if let cached = storage[key] {
                    return cached
                }
                let built = compute()
                if storage.count > 128 {
                    storage.removeAll()
                }
                storage[key] = built
                return built
            }
        }
    }

    private static let folderSummaryCache = FolderSummaryCache()

    private var firstFileURL: URL? {
        guard let path = group.files.first?.path else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var folderSummary: String {
        let key = "\(group.id)#\(group.files.map(\.path).joined(separator: "|"))"
        return Self.folderSummaryCache.summary(for: key) {
            let folders = Set(
                group.files.map {
                    URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent
                })
            if folders.count == 1, let folder = folders.first, !folder.isEmpty {
                return folder
            }
            return "Across \(folders.count) folders"
        }
    }

    private var badgeColor: Color {
        group.isExact ? .orange : .blue
    }

    var body: some View {
        HStack(spacing: 12) {
            if let url = firstFileURL {
                FileThumbnailView(url: url, size: CGSize(width: 40, height: 40))
                    .frame(width: 40, height: 40)
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(badgeColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: group.isExact ? "doc.on.doc.fill" : "waveform.path")
                            .foregroundStyle(badgeColor)
                            .symbolReplaceTransition(animationValue: group.isExact)
                    }
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(group.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group.displayName)

                HStack(spacing: 5) {
                    Label(folderSummary, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("•")
                    Text("\(group.files.count) \(group.isExact ? "copies" : "matches")")
                        .numericTextTransition(animationValue: group.files.count)
                    Text("•")
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: group.potentialSavings, countStyle: .file)
                    )
                    .foregroundStyle(.green)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

        }
        .padding(.vertical, 7)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DuplicateSectionHeader: View {
    @SortyHotReload private var hotReload
    let title: String
    @Binding var isExpanded: Bool
    let guidance: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var isDismissed: Bool
    @State private var isInfoPresented = false
    @State private var shouldDismissInfo = false

    init(
        title: String,
        isExpanded: Binding<Bool>,
        guidance: String,
        infoKey: String
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.guidance = guidance
        self._isDismissed = AppStorage(wrappedValue: false, infoKey)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.24),
                            value: isExpanded
                        )
                        .accessibilityHidden(true)

                    Text(title)
                }
                .frame(minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(
                "Double-click to " + (isExpanded ? "collapse" : "expand") + " this section"
            )

            if !isDismissed {
                Button {
                    shouldDismissInfo = false
                    isInfoPresented = true
                } label: {
                    Image(systemName: "info.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("About " + title)
                .popover(isPresented: $isInfoPresented) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("About " + title)
                            .font(.headline)

                        Text(guidance)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle("Don't show again", isOn: $shouldDismissInfo)
                            .font(.body)

                        HStack {
                            Spacer()
                            Button("OK") {
                                if shouldDismissInfo {
                                    isDismissed = true
                                }
                                isInfoPresented = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(16)
                    .frame(width: 360, alignment: .leading)
                }
            }
        }
        .onAppear {
            shouldDismissInfo = isDismissed
        }
    }
}
