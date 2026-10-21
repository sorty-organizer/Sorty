import Foundation
import AppKit
import SwiftUI

// MARK: - Storage
extension ReadyToOrganizeView {
    var storageLocationsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Button(action: toggleStorageLocations) {
                    HStack(spacing: 6) {
                        Image(systemName: selectedStorageLocationCount > 0 ? "externaldrive.fill" : "externaldrive")
                            .font(.system(size: 12))
                            .foregroundStyle(
                                selectedStorageLocationCount > 0
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            .symbolReplaceTransition(
                                animationValue: selectedStorageLocationCount > 0
                            )
                            .frame(width: 22, height: 22)
                            .background {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.32))
                                    .frame(width: 18, height: 18)
                                    .blur(radius: 5)
                                    .opacity(selectedStorageLocationCount > 0 ? 1 : 0)
                            }

                        Text(storageLocationTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .numericTextTransition(
                                animationValue: storageLocationTitle,
                                animation: .easeInOut(duration: 0.28)
                            )
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showStorageLocations ? "Hide organization locations" : "Show organization locations")
                .accessibilityLabel(showStorageLocations ? "Hide storage locations" : "Show storage locations")
                .accessibilityHint("Expand to manage local, cloud, and external organization locations")
                .accessibilityValue(showStorageLocations ? "Expanded" : "Collapsed")

                Button {
                    HapticFeedbackManager.shared.tap()
                    showStorageLocationsInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 44)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                    }
                }
                .popover(isPresented: $showStorageLocationsInfo, arrowEdge: .bottom) {
                    StorageLocationsInfoPopover()
                        .systemLiquidGlassPopover(cornerRadius: 12)
                }
                .help("How storage locations work")
                .accessibilityLabel("About storage locations")
                .accessibilityIdentifier("StorageLocationsInfoButton")

                Button(action: toggleStorageLocations) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 8)

                        storageLocationSelectionSummary
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showStorageLocations ? "Hide organization locations" : "Show organization locations")
                .accessibilityLabel(showStorageLocations ? "Hide storage locations" : "Show storage locations")

                Button(action: toggleStorageLocations) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showStorageLocations ? 180 : 0))
                        .animation(
                            reduceMotion ? nil : .smooth(duration: 0.28),
                            value: showStorageLocations
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showStorageLocations ? "Hide organization locations" : "Show organization locations")
                .accessibilityLabel(showStorageLocations ? "Collapse storage locations" : "Expand storage locations")
                .accessibilityIdentifier("StorageLocationsDisclosureButton")
            }

            if showStorageLocations {
                VStack(alignment: .leading, spacing: 10) {
                    if !storageLocationsManager.locations.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(storageLocationsManager.locations) { location in
                                CompactStorageLocationRow(location: location)
                                    .transition(storageLocationRowTransition)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .animation(storageLocationInsertionAnimation, value: storageLocationListIDs)
                    }

                    HStack(alignment: .center, spacing: 14) {
                        if storageLocationsManager.locations.isEmpty {
                            Spacer()
                        }

                        Button {
                            HapticFeedbackManager.shared.tap()
                            suggestedLocationName = nil
                            showingFolderPicker = true
                        } label: {
                            Label {
                                Text("Add Custom Location")
                            } icon: {
                                Image(systemName: "plus")
                                    .rotationEffect(.degrees(showingFolderPicker ? 45 : 0))
                                    .animation(
                                        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72),
                                        value: showingFolderPicker
                                    )
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.sortyBordered)
                        .controlSize(.small)
                        .help("Add a folder that Sorty can organize with")
                        .accessibilityHint("Opens the folder picker to add an organization location")

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(
                        storageLocationInsertionAnimation,
                        value: storageLocationsManager.locations.isEmpty
                    )
                    .padding(.top, 2)
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    var storageLocationSelectionSummary: some View {
        ZStack(alignment: .trailing) {
            Group {
                if selectedStorageLocationCount > 0 {
                    HStack(spacing: 8) {
                        Text("\(selectedStorageLocationCount) selected")
                            .font(.caption)
                            .foregroundStyle(storageLocationSelectionTint)
                            .numericTextTransition(animationValue: selectedStorageLocationCount)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .systemLiquidGlassBackground(cornerRadius: 999)

                        if unavailableSelectedStorageLocationCount > 0 {
                            Text("\(unavailableSelectedStorageLocationCount) unavailable")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .numericTextTransition(
                                    animationValue: unavailableSelectedStorageLocationCount
                                )
                        }
                    }
                } else if !storageLocationsManager.locations.isEmpty {
                    Text("No active locations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No locations configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .id(storageLocationSummaryID)
            .transition(storageLocationSummaryTransition)
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.86),
            value: storageLocationSummaryID
        )
        .accessibilityElement(children: .combine)
    }

}
