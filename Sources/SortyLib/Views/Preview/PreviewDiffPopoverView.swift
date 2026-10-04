import SwiftUI

struct PreviewDiffPopoverView: View {
    let diff: OrganizationPlanDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Changes between previews")
                    .font(.headline)
                Text("\(diff.fromLabel) → \(diff.toLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .numericTextTransition(animationValue: "\(diff.fromLabel)-\(diff.toLabel)")
            }
            .padding()

            Divider()

            if diff.changes.isEmpty {
                ContentUnavailableView(
                    "No changes",
                    systemImage: "equal",
                    description: Text("These previews organize the files the same way.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(OrganizationPlanDiff.ChangeKind.allCases, id: \.self) { kind in
                            let changes = diff.changes(for: kind)
                            if !changes.isEmpty {
                                PreviewDiffSection(kind: kind, changes: changes)
                            }
                        }
                    }
                    .padding()
                }
                .frame(minHeight: 220, maxHeight: 420)
            }
        }
        .frame(width: 440)
        .systemLiquidGlassPopover(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes from \(diff.fromLabel) to \(diff.toLabel)")
    }
}

private struct PreviewDiffSection: View {
    let kind: OrganizationPlanDiff.ChangeKind
    let changes: [OrganizationPlanDiff.Change]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(kind.rawValue) · \(changes.count)", systemImage: kind.systemImage)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .numericTextTransition(animationValue: changes.count)

            ForEach(changes) { change in
                PreviewDiffRow(change: change)
            }
        }
    }
}

private struct PreviewDiffRow: View {
    let change: OrganizationPlanDiff.Change

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(change.filename)
                .font(.callout.bold())
                .lineLimit(1)
                .truncationMode(.middle)

            if let before = change.before, let after = change.after {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    diffValue(before, systemImage: "minus", color: .red)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    diffValue(after, systemImage: "plus", color: .green)
                }
                .font(.caption)
                .lineLimit(2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Before: \(before). After: \(after)")
            } else {
                if let after = change.after {
                    diffValue(after, systemImage: "plus", color: .green)
                        .accessibilityLabel("Added: \(after)")
                } else {
                    diffValue(
                        change.before ?? "Removed from this preview",
                        systemImage: "minus",
                        color: .red
                    )
                    .accessibilityLabel("Removed: \(change.before ?? change.filename)")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func diffValue(_ value: String, systemImage: String, color: Color) -> some View {
        Label(value, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: .rect(cornerRadius: 6))
    }
}
