//
//  MenuBarLabsSections.swift
//  Sorty
//
//  Menu bar section for Labs Expiring Files.
//

import AppKit
import SwiftUI

// MARK: - Expiring Files

/// Old installers, archives and screenshots waiting for review before the Trash.
struct MenuBarExpiringFilesSection: View {
    @SortyHotReload private var hotReload
    @ObservedObject private var manager = ExpiringFilesManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isReviewing: Bool
    @State private var deselected: Set<String> = []

    /// The Inbox page opens straight into the review list; the menu bar starts collapsed.
    init(startsExpanded: Bool = false) {
        _isReviewing = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if manager.candidates.isEmpty {
                if let result = manager.lastResult {
                    Label(result, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    Text("Nothing has expired.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            } else {
                summaryButton
                if isReviewing {
                    reviewList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(reduceMotion ? nil : .sortySnappy, value: isReviewing)
        .task { await manager.refresh() }
    }

    private var selected: [ExpiringFileCandidate] {
        manager.candidates.filter { !deselected.contains($0.id) }
    }

    private var summaryButton: some View {
        Button {
            HapticFeedbackManager.shared.selection()
            isReviewing.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clean Up \(manager.candidates.count) Old \(manager.candidates.count == 1 ? "File" : "Files")")
                        .font(.callout)
                    Text("\(ByteCountFormatter.string(fromByteCount: manager.totalSize, countStyle: .file)) · older than \(manager.ageInDays) days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isReviewing ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MenuBarExpiringFilesSummary")
    }

    private var reviewList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(manager.candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
            .frame(maxHeight: 180)

            HStack {
                Button("Move \(selected.count) to Trash") {
                    HapticFeedbackManager.shared.success()
                    let chosen = selected
                    Task {
                        await manager.moveToTrash(chosen)
                        deselected = []
                        isReviewing = false
                    }
                }
                .buttonStyle(.sortyProminent(size: .small))
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("MenuBarExpiringFilesTrash")

                Spacer()

                Text("Recoverable from the Trash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func candidateRow(_ candidate: ExpiringFileCandidate) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { !deselected.contains(candidate.id) },
                set: { isOn in
                    HapticFeedbackManager.shared.selection()
                    if isOn { deselected.remove(candidate.id) } else { deselected.insert(candidate.id) }
                }
            )) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(candidate.url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(candidate.reason.rawValue) · \(candidate.dateAdded.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 4)

            Button("Keep") {
                HapticFeedbackManager.shared.tap()
                manager.keep(candidate)
            }
            .buttonStyle(.link)
            .font(.caption2)
            .help("Never suggest this file again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
