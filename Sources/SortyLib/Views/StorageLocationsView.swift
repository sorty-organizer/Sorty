//
//  StorageLocationsView.swift
//  Sorty
//
//  Configuration sheet and shared UI for storage locations - directories where
//  files can be moved TO. Managed inline on the Ready to Organize page.
//

import SwiftUI

// MARK: - Storage Location Config View

struct StorageLocationConfigView: View {
    @SortyHotReload private var hotReload
    let location: StorageLocation
    @EnvironmentObject var storageLocationsManager: StorageLocationsManager
    @Environment(\.dismiss) var dismiss
    
    @State private var name: String
    @State private var description: String
    @State private var isDescriptionFocused = false
    @State private var descriptionSelection = NSRange(location: 0, length: 0)
    @State private var descriptionSuggestionIndex = 0
    @State private var isHoveringPath = false
    @State private var isWindowVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private let descriptionSuggestions = [
        "Archive for completed projects older than 6 months",
        "Storage for large media files and raw footage",
        "Backup location for important documents",
    ]

    init(location: StorageLocation) {
        self.location = location
        _name = State(initialValue: location.name)
        _description = State(initialValue: location.description ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 12) {
                    FolderThumbnailView(url: location.url, size: CGSize(width: 28, height: 28))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(location.name)
                                .font(.headline)

                            StorageProviderBadge(provider: location.capabilityProfile.provider)
                        }
                        Button {
                            HapticFeedbackManager.shared.tap()
                            NSWorkspace.shared.selectFile(
                                nil,
                                inFileViewerRootedAtPath: location.path
                            )
                        } label: {
                            HStack(spacing: 5) {
                                PrivacySensitivePathText(path: location.path)
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
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                            value: isHoveringPath
                        )
                        .onHover { isHoveringPath = $0 }
                        .help("Reveal \(location.name) in Finder")
                        .accessibilityLabel("Reveal \(location.name) in Finder") // [VERIFY] confirm label matches intent
                    }
                }
                
                Spacer()
                
                Button("Done") {
                    HapticFeedbackManager.shared.success()
                    save()
                }
                .buttonStyle(.sortyProminent)
            }
            .padding()
            .background(.ultraThinMaterial)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    // Basic Info Section
                    SettingsCard(title: "Display Name", icon: "textformat", color: .blue) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Location name", text: $name)
                                .textFieldStyle(.roundedBorder)
                            
                            Text("A friendly name for this storage location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Description Section
                    SettingsCard(title: "Description for Sorty", icon: "text.bubble", color: .purple) {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                SubmittableTextEditor(
                                    text: $description,
                                    isFocused: $isDescriptionFocused,
                                    selectedRange: $descriptionSelection,
                                    onAcceptSuggestion: acceptCurrentDescriptionSuggestion,
                                    onSubmit: save
                                )
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)

                                if description.isEmpty {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(currentDescriptionSuggestion)
                                            .font(.body)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                            .numericTextTransition(
                                                animationValue: descriptionSuggestionIndex
                                            )

                                        Spacer(minLength: 0)

                                        Text("Tab")
                                            .font(
                                                .system(
                                                    size: 10,
                                                    weight: .semibold,
                                                    design: .rounded
                                                )
                                            )
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(
                                                Color.secondary.opacity(0.10),
                                                in: RoundedRectangle(cornerRadius: 5)
                                            )
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.leading, 18)
                                    .padding(.trailing, 10)
                                    .padding(.vertical, 9)
                                    .allowsHitTesting(false)
                                    .task(id: shouldCycleDescriptionSuggestions) {
                                        guard shouldCycleDescriptionSuggestions else { return }
                                        while !Task.isCancelled {
                                            try? await Task.sleep(for: .seconds(3.5))
                                            guard !Task.isCancelled,
                                                  shouldCycleDescriptionSuggestions else { return }
                                            descriptionSuggestionIndex =
                                                (descriptionSuggestionIndex + 1)
                                                % descriptionSuggestions.count
                                        }
                                    }
                                }
                            }
                                .frame(height: 80)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(NSColor.textBackgroundColor))
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)

                                    FocusedInstructionBeamBorder(active: isDescriptionFocused)
                                }
                                .accessibilityIdentifier("StorageLocationDescriptionTextField")
                                .accessibilityLabel("Description for Sorty")
                                .accessibilityHint(
                                    description.isEmpty
                                        ? "Press Tab to use the suggested description, Command+Enter to save, or Enter for a new line"
                                        : "Press Command+Enter to save, or Enter for a new line"
                                )
                            
                            Text("Describe what types of files belong here. Sorty uses this to decide which files to move to this location.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 450, height: 460)
        .background(Color(NSColor.windowBackgroundColor))
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
    }

    private var shouldCycleDescriptionSuggestions: Bool {
        description.isEmpty
            && !isDescriptionFocused
            && isWindowVisible
            && controlActiveState != .inactive
    }

    private var currentDescriptionSuggestion: String {
        descriptionSuggestions[descriptionSuggestionIndex % descriptionSuggestions.count]
    }

    private func acceptCurrentDescriptionSuggestion() -> Bool {
        guard description.isEmpty else { return false }

        description = currentDescriptionSuggestion
        descriptionSelection = NSRange(
            location: (currentDescriptionSuggestion as NSString).length,
            length: 0
        )
        HapticFeedbackManager.shared.selection()
        return true
    }

    private func save() {
        var updated = location
        updated.name = name.isEmpty ? location.url.lastPathComponent : name
        updated.description = description.isEmpty ? nil : description
        
        withAnimation {
            storageLocationsManager.updateLocation(updated)
        }
        dismiss()
    }
}

private struct StorageProviderBadge: View {
    @SortyHotReload private var hotReload
    let provider: StorageProviderKind

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(label)
                .foregroundStyle(.primary)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .systemLiquidGlassBackground(cornerRadius: 999, interactive: false)
        .fixedSize()
        .help(accessibilityDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var label: String {
        switch provider {
        case .googleDrive: return "Cloud · Google Drive"
        case .dropbox: return "Cloud · Dropbox"
        case .oneDrive: return "Cloud · OneDrive"
        case .box: return "Cloud · Box"
        case .iCloudDrive: return "Cloud · iCloud"
        case .fileProvider: return "Cloud"
        case .externalVolume: return "External Drive"
        case .local: return "Local"
        }
    }

    private var symbolName: String {
        switch provider {
        case .googleDrive, .dropbox, .oneDrive, .box, .fileProvider:
            return "externaldrive.fill.badge.icloud"
        case .iCloudDrive:
            return "icloud.fill"
        case .externalVolume:
            return "externaldrive.fill"
        case .local:
            return "internaldrive.fill"
        }
    }

    private var tint: Color {
        switch provider {
        case .googleDrive: return .blue
        case .dropbox: return .indigo
        case .oneDrive: return .cyan
        case .box: return .purple
        case .iCloudDrive: return .blue
        case .fileProvider: return .teal
        case .externalVolume: return .orange
        case .local: return .secondary
        }
    }

    private var accessibilityDescription: String {
        switch provider {
        case .externalVolume:
            return "External drive storage location"
        case .local:
            return "Local storage location"
        default:
            return "Cloud storage location using \(provider.displayName)"
        }
    }
}

// MARK: - Info Row

struct InfoRow: View {
    @SortyHotReload private var hotReload
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
