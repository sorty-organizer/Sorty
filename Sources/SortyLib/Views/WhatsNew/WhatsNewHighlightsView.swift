import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The 1.3.1 highlights page. Each card holds a small working sample of its
/// feature. Samples keep local state only and never touch real files.
struct WhatsNewHighlightsView: View {
    @SortyHotReload private var hotReload
    @Binding var isEditingSampleName: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: SortyDesignSystem.Spacing.md) {
            WhatsNewRenameCard(isEditing: $isEditingSampleName)
                .frame(height: 178)
                .modifier(entrance(order: 0))

            HStack(spacing: SortyDesignSystem.Spacing.md) {
                WhatsNewExpiringCard()
                    .modifier(entrance(order: 1))
                WhatsNewFeedbackCard()
                    .modifier(entrance(order: 2))
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            hasAppeared = true
        }
    }

    private func entrance(order: Int) -> WhatsNewCardEntrance {
        WhatsNewCardEntrance(
            isVisible: hasAppeared,
            animation: reduceMotion ? nil : .sortySpringStandard.delay(Double(order) * 0.06)
        )
    }
}

private struct WhatsNewCardEntrance: ViewModifier {
    let isVisible: Bool
    let animation: Animation?

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || animation == nil ? 0 : 10)
            .animation(animation, value: isVisible)
    }
}

extension View {
    /// Tinted glass surface shared by the What's New pages.
    func whatsNewCard(tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xl, style: .continuous)

        return background {
            LinearGradient(
                colors: [tint.opacity(0.10), Color.primary.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(shape)
        .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.xl, interactive: false)
        .overlay {
            shape.strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    /// Inset well that holds a card's sample.
    fileprivate func whatsNewSampleWell() -> some View {
        let shape = RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.lg, style: .continuous)

        return background(Color.primary.opacity(0.05), in: shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

private struct WhatsNewCardHeading: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String
    let tint: Color
    var badge: LocalizedStringKey?
    var isProminent = false

    var body: some View {
        VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.sm) {
            HStack(spacing: SortyDesignSystem.Spacing.sm) {
                Image(systemName: symbol)
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.18), in: Circle())
                    .accessibilityHidden(true)

                if !isProminent {
                    titleText
                }


                if let badge {
                    Text(badge)
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, SortyDesignSystem.Spacing.xs)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.32), in: Capsule())
                }
            }

            if isProminent {
                titleText
            }

            Text(detail)
                .font(.system(isProminent ? .subheadline : .caption, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.system(isProminent ? .title3 : .headline, design: .rounded, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Finder's icon for a sample file type.
private struct WhatsNewFileIcon: View {
    let type: UTType
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Rename

/// Sample preview row built from the rename controls in the real preview.
private struct WhatsNewRenameCard: View {
    @SortyHotReload private var hotReload
    @Binding var isEditing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var suggestionIndex = 0
    @State private var userName: String?
    @State private var editedName = ""
    @State private var isRegenerating = false
    @State private var keepsOriginalName = false
    @FocusState private var isFieldFocused: Bool

    private static let originalName = "IMG_4821.HEIC"
    private static let suggestions = [
        "Lisbon Sunset.heic",
        "Alfama Rooftop View.heic",
        "Sunset over the Tagus.heic",
    ]

    private let tint = SortyDesignSystem.Colors.resolvedAccent

    private var currentName: String {
        userName ?? Self.suggestions[suggestionIndex]
    }

    private var showsSuggestion: Bool {
        !keepsOriginalName && !isEditing
    }

    var body: some View {
        HStack(alignment: .top, spacing: SortyDesignSystem.Spacing.xl) {
            VStack(alignment: .leading, spacing: 0) {
                WhatsNewCardHeading(
                    title: "Refine names in preview",
                    detail: "Edit, regenerate, or revert a name before applying your plan.",
                    symbol: "pencil.line",
                    tint: tint,
                    badge: "New",
                    isProminent: true
                )

                Spacer(minLength: SortyDesignSystem.Spacing.sm)

                Label("Try it. This sample changes nothing.", systemImage: "cursorarrow.click")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 214, alignment: .leading)

            sample
        }
        .padding(SortyDesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .whatsNewCard(tint: tint)
        .animation(reduceMotion ? nil : .sortySnappy, value: showsSuggestion)
        .task(id: isRegenerating) {
            guard isRegenerating else { return }
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            userName = nil
            suggestionIndex = (suggestionIndex + 1) % Self.suggestions.count
            isRegenerating = false
        }
    }

    private var sample: some View {
        VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.sm) {
            HStack(spacing: SortyDesignSystem.Spacing.xs) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: "Travel")
                    .font(.system(.caption, design: .default, weight: .semibold))
                Spacer(minLength: 0)
                Text("2 files")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)

            Divider()

            VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.xs) {
                originalNameRow
                suggestionRow
                    .frame(height: 26)
            }

            HStack(spacing: SortyDesignSystem.Spacing.sm) {
                WhatsNewFileIcon(type: .quickTimeMovie)
                Text(verbatim: "Tram 28.mov")
                Spacer(minLength: 0)
                Text(verbatim: "48 MB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .opacity(0.55)
        }
        .font(.callout)
        .padding(SortyDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .whatsNewSampleWell()
    }

    private var originalNameRow: some View {
        HStack(spacing: SortyDesignSystem.Spacing.sm) {
            WhatsNewFileIcon(type: .heic)

            if isEditing {
                TextField("New name", text: $editedName)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .onSubmit(saveEdit)
                    .onExitCommand(perform: cancelEdit)
                    .accessibilityIdentifier("WhatsNewSampleNameField")
            } else {
                Text(verbatim: Self.originalName)
                    .lineLimit(1)
                    .foregroundStyle(showsSuggestion ? .secondary : .primary)
                    .strikethrough(
                        showsSuggestion,
                        color: SortyDesignSystem.Colors.error.opacity(0.72)
                    )
            }

            Spacer(minLength: SortyDesignSystem.Spacing.sm)

            Text(verbatim: "3.2 MB")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var suggestionRow: some View {
        if isEditing {
            Text("Press Return to save, Esc to cancel.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .frame(maxHeight: .infinity)
        } else if keepsOriginalName {
            Button {
                HapticFeedbackManager.shared.selection()
                keepsOriginalName = false
            } label: {
                Label("Suggest a name", systemImage: "wand.and.stars")
            }
            .buttonStyle(.sortyBordered(size: .small))
            .padding(.leading, 28)
            .accessibilityIdentifier("WhatsNewSampleSuggestButton")
        } else {
            HStack(spacing: SortyDesignSystem.Spacing.sm) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                RenameNameChangeView(
                    suggestedName: currentName,
                    helpText: "Sample suggestion",
                    isRegenerating: isRegenerating,
                    isHighlighted: true
                )

                Spacer(minLength: SortyDesignSystem.Spacing.xxs)

                RenameActionGlassCluster(
                    isRegenerating: isRegenerating,
                    onEdit: startEdit,
                    onRegenerate: regenerate,
                    onReject: keepOriginalName
                )
            }
            .padding(.leading, SortyDesignSystem.Spacing.xs)
        }
    }

    private func startEdit() {
        HapticFeedbackManager.shared.selection()
        editedName = currentName
        isEditing = true
        Task { @MainActor in
            isFieldFocused = true
        }
    }

    private func saveEdit() {
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            userName = name
        }
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }

    private func regenerate() {
        HapticFeedbackManager.shared.selection()
        isRegenerating = true
    }

    private func keepOriginalName() {
        HapticFeedbackManager.shared.selection()
        keepsOriginalName = true
    }
}

// MARK: - Expiring Files

private struct WhatsNewExpiringSample: Identifiable {
    let name: String
    let type: UTType
    let detail: String
    let megabytes: Int

    var id: String { name }
}

/// Sample review list. Selection updates the total; nothing moves to Trash.
private struct WhatsNewExpiringCard: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deselected: Set<String> = []

    private static let samples = [
        WhatsNewExpiringSample(
            name: "Figma-125.1.dmg",
            type: .diskImage,
            detail: "Installer · 8 months old · 212 MB",
            megabytes: 212
        ),
        WhatsNewExpiringSample(
            name: "Client Photos.zip",
            type: .zip,
            detail: "Archive · 1 year old · 96 MB",
            megabytes: 96
        ),
    ]

    private let tint = SortyDesignSystem.Colors.warning

    private var selected: [WhatsNewExpiringSample] {
        Self.samples.filter { !deselected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.md) {
            WhatsNewCardHeading(
                title: "Review old files",
                detail: "Turn on Expiring Files, then check each file before it moves to Trash.",
                symbol: "hourglass",
                tint: tint,
                badge: "New in Labs"
            )

            VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.xs) {
                ForEach(Self.samples) { sample in
                    row(sample)
                }

                Text("\(selected.count) selected · \(selected.reduce(0) { $0 + $1.megabytes }) MB")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .numericTextTransition(animationValue: selected.count)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(SortyDesignSystem.Spacing.sm)
            .frame(maxHeight: .infinity, alignment: .top)
            .whatsNewSampleWell()
        }
        .padding(SortyDesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .whatsNewCard(tint: tint)
    }

    private func row(_ sample: WhatsNewExpiringSample) -> some View {
        let isSelected = Binding(
            get: { !deselected.contains(sample.id) },
            set: { isOn in
                HapticFeedbackManager.shared.selection()
                if isOn {
                    deselected.remove(sample.id)
                } else {
                    deselected.insert(sample.id)
                }
            }
        )

        return HStack(spacing: SortyDesignSystem.Spacing.xs) {
            Toggle("", isOn: isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(verbatim: "Sample: Trash \(sample.name)"))

            WhatsNewFileIcon(type: sample.type, size: 24)

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: sample.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: sample.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(isSelected.wrappedValue ? 1 : 0.6)
        .animation(reduceMotion ? nil : .sortyQuick, value: isSelected.wrappedValue)
    }
}

// MARK: - Feedback

/// Sample feedback attachments with the real diagnostics choice.
private struct WhatsNewFeedbackCard: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var includesDiagnostics = true

    private let tint = SortyDesignSystem.Colors.success

    var body: some View {
        VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.md) {
            WhatsNewCardHeading(
                title: "Show what went wrong",
                detail: "Attach files to feedback and preview the diagnostics in your report.",
                symbol: "paperclip",
                tint: tint,
                badge: "New"
            )

            VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.sm) {
                HStack(spacing: SortyDesignSystem.Spacing.xs) {
                    attachment("Error.png", type: .png, size: "1.1 MB")
                    attachment("Plan.json", type: .json, size: "18 KB")
                }

                HStack {
                    Text("Include diagnostics")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: SortyDesignSystem.Spacing.sm)
                    Toggle("", isOn: $includesDiagnostics)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .onChange(of: includesDiagnostics) { _, _ in
                            HapticFeedbackManager.shared.selection()
                        }
                        .accessibilityLabel("Sample: Include diagnostics")
                }

                Text(
                    includesDiagnostics
                        ? "Versions, AI settings, and recent errors."
                        : "Only your message and attachments."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SortyDesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .whatsNewSampleWell()
        }
        .padding(SortyDesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .whatsNewCard(tint: tint)
        .animation(reduceMotion ? nil : .sortyQuick, value: includesDiagnostics)
    }

    private func attachment(_ name: String, type: UTType, size: String) -> some View {
        HStack(spacing: SortyDesignSystem.Spacing.xs) {
            WhatsNewFileIcon(type: type, size: 24)

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: size)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(SortyDesignSystem.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.md, style: .continuous)
        )
    }
}

#Preview {
    WhatsNewHighlightsView(isEditingSampleName: .constant(false))
        .frame(width: 592, height: 382)
        .padding(24)
}
