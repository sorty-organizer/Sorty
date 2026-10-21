import AppKit
import SwiftUI

// MARK: - Operation Row View

struct OperationRowView: View {
    @SortyHotReload private var hotReload
    let operation: FileSystemManager.FileOperation
    let isUndone: Bool
    let isFailed: Bool
    let isUndoing: Bool
    let isEntryUndone: Bool
    let onUndo: () -> Void

    @State private var isHovered = false

    private var fileName: String {
        if let dest = operation.destinationPath {
            return URL(fileURLWithPath: dest).lastPathComponent
        }
        return URL(fileURLWithPath: operation.sourcePath).lastPathComponent
    }

    private var operationIcon: String {
        switch operation.type {
        case .moveFile: return "arrow.right.doc"
        case .renameFile: return "pencil.line"
        case .tagFile: return "tag"
        case .createFolder: return "folder.badge.plus"
        case .deleteFile: return "trash"
        case .copyFile: return "doc.on.doc"
        }
    }

    private var operationLabel: String {
        switch operation.type {
        case .moveFile: return operation.metadata?.newFilename == nil ? "Moved" : "Moved & Renamed"
        case .renameFile: return "Renamed"
        case .tagFile: return "Tagged"
        case .createFolder: return "Created"
        case .deleteFile: return "Deleted"
        case .copyFile: return "Copied"
        }
    }

    private var destinationFolder: String? {
        guard let dest = operation.destinationPath else { return nil }
        return URL(fileURLWithPath: dest).deletingLastPathComponent().lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            if isUndone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if isFailed {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Image(systemName: operationIcon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            operationDescription
            Spacer()

            if isUndoing {
                CometLoader(size: 16, lineWidth: 2, color: .secondary)
                    .frame(width: 16, height: 16)
            } else if !isUndone && !isEntryUndone {
                Button {
                    onUndo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.mini)
                .disabled(isFailed)
                .accessibilityLabel("Undo \(fileName)")
                .accessibilityIdentifier("UndoOperation-\(operation.id.uuidString)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(operationBackgroundColor)
        )
        .opacity(isUndone ? 0.7 : 1.0)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.subtleBounce, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(operationLabel) \(fileName)\(isUndone ? ", undone" : "")\(isFailed ? ", failed" : "")")
    }

    private var operationBackgroundColor: Color {
        isUndone ? Color.green.opacity(0.05) : isFailed ? Color.red.opacity(0.05) : Color.secondary.opacity(0.05)
    }

    private var operationDescription: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fileName)
                .font(.caption)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(operationLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let folder = destinationFolder {
                    Text("→ \(folder)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Processing Overlay

struct ProcessingOverlay: View {
    @SortyHotReload private var hotReload
    let stage: String
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.1)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                LoadingDotsView(dotCount: 3, dotSize: 8, color: .accentColor)

                Text(stage)
                    .font(.body)
                    .foregroundColor(.primary)
                    .numericTextTransition(animationValue: stage)
            }
            .padding(24)
            .systemLiquidGlassBackground(cornerRadius: 12)
            .scaleEffect(appeared ? 1 : 0.8)
            .opacity(appeared ? 1 : 0)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Processing: \(stage)")
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                appeared = true
            }
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    @SortyHotReload private var hotReload
    let status: OrganizationStatus

    private var color: Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .skipped: return .secondary
        case .undo: return .orange
        case .partiallyUndone: return .yellow
        case .duplicatesCleanup: return .accentColor
        }
    }

    var body: some View {
        Text(status.displayName.uppercased())
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Status: \(status.displayName)")
    }
}
