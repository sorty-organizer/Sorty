import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Compact Storage Location Row

struct CompactStorageLocationRow: View {
    @SortyHotReload private var hotReload
    let location: StorageLocation
    @EnvironmentObject var storageLocationsManager: StorageLocationsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingConfig = false
    @State private var showReauthorizePicker = false
    @State private var isHoveringPath = false

    private var needsAttention: Bool {
        !location.exists || location.accessStatus == .lost
    }

    private var statusHelp: String? {
        if !location.exists { return "Folder not found" }
        if location.accessStatus == .lost { return "Access to this folder was lost. Grant access again." }
        if location.accessStatus == .stale { return "Access is being refreshed automatically" }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: location.isEnabled ? "externaldrive.fill" : "externaldrive")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.blue)
                    .symbolReplaceTransition(animationValue: location.isEnabled)

                if needsAttention {
                    Image(systemName: !location.exists ? "exclamationmark.triangle.fill" : "lock.slash.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(!location.exists ? .red : .orange)
                        .symbolReplaceTransition(animationValue: location.exists)
                        .offset(x: 5, y: 4)
                        .accessibilityHidden(true)
                }
            }
            .help(statusHelp ?? "")

            VStack(alignment: .leading, spacing: 2) {
                Text(location.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(location.isEnabled ? .primary : .secondary)

                Button {
                    HapticFeedbackManager.shared.tap()
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path)
                } label: {
                    HStack(spacing: 5) {
                        PrivacySensitivePathText(path: location.path, revealOnClick: false)
                            .lineLimit(1)
                            .truncationMode(.middle)

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
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Reveal \(location.name) in Finder")
                .accessibilityLabel("Reveal \(location.name) in Finder")
                .animation(
                    reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                    value: isHoveringPath
                )
                .onHover { hovering in
                    isHoveringPath = hovering
                }
            }

            Spacer()

            if location.accessStatus == .lost {
                Button("Grant Access") {
                    HapticFeedbackManager.shared.tap()
                    showReauthorizePicker = true
                }
                .font(.caption2)
                .buttonStyle(.sortyBordered)
                .controlSize(.mini)
                .help("Re-select this folder to restore access")
                .accessibilityLabel("Grant access to \(location.name)")
            }

            HStack(spacing: 6) {
                Button {
                    HapticFeedbackManager.shared.tap()
                    showingConfig = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.mini)
                .help("Customize \(location.name)")
                .accessibilityLabel("Customize \(location.name)")

                Button(role: .destructive) {
                    HapticFeedbackManager.shared.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        storageLocationsManager.removeLocation(location)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.mini)
                .help("Remove \(location.name)")
                .accessibilityLabel("Remove \(location.name)")
            }

            Toggle("", isOn: Binding(
                get: { location.isEnabled },
                set: { _ in
                    HapticFeedbackManager.shared.selection()
                    storageLocationsManager.toggleEnabled(for: location)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("Enable \(location.name)")
            .accessibilityValue(location.isEnabled ? "On" : "Off")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.05))
        )
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path)
            }
            Button("Customize...") {
                showingConfig = true
            }
            Divider()
            Button("Remove", role: .destructive) {
                HapticFeedbackManager.shared.tap()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    storageLocationsManager.removeLocation(location)
                }
            }
        }
        .sheet(isPresented: $showingConfig) {
            StorageLocationConfigView(location: location)
                .modalBounce()
        }
        .fileImporter(
            isPresented: $showReauthorizePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                storageLocationsManager.reauthorizeLocation(location, with: url)
            }
        }
    }
}

// MARK: - Storage Locations Info Popover

struct StorageLocationsInfoPopover: View {
    @SortyHotReload private var hotReload
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How Storage Locations Work", systemImage: "externaldrive")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 10) {
                InfoRow(icon: "arrow.right.circle", text: "Files can be moved TO enabled locations during organization")
                InfoRow(icon: "xmark.circle", text: "Files already inside a location will NOT be reorganized")
                InfoRow(icon: "brain", text: "Sorty matches files using each location's description — customize it to steer results")
                InfoRow(icon: "externaldrive.fill.badge.icloud", text: "Local, cloud, and external drive folders are all supported")
                InfoRow(icon: "checkmark.shield", text: "Folder access is checked automatically; Sorty asks only if it needs you to re-grant access")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
