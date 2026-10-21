import SwiftUI
import UniformTypeIdentifiers

struct NaturalLanguageSuggestionTaskID: Hashable {
    let isEmpty: Bool
    let isVisible: Bool
    let controlActiveState: ControlActiveState
    let scenePhase: ScenePhase
}

struct ExclusionEditorTransitionModifier: ViewModifier {
    var opacity = 1.0
    var blurRadius = 0.0
    var yOffset = 0.0
    var scale = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blurRadius)
            .scaleEffect(scale, anchor: .top)
            .offset(y: yOffset)
    }
}

// MARK: - Empty State View

struct EmptyExclusionRulesView: View {
    @SortyHotReload private var hotReload
    let onAddRule: () -> Void
    @State private var hasAppeared = false
    @State private var beamHasAppeared = false

    var body: some View {
        VStack(spacing: 24) {
            EmptyStateHeroIcon(systemName: "eye.slash.circle")
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.8)
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: hasAppeared)

            VStack(spacing: 8) {
                Text("Nothing is excluded")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(
                    "Choose folders or rules for anything Sorty should exclude from organizations and renames."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            Button {
                onAddRule()
            } label: {
                Label("Add Exclusion", systemImage: "plus")
            }
            .buttonStyle(.sortyPrimary)
            .onboardingBeamBorder(variant: .featured, active: beamHasAppeared)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                beamHasAppeared = true
            }
        }
    }
}

// MARK: - Rule Group Card

struct RuleGroupCard: View {
    @SortyHotReload private var hotReload
    let title: String
    let rules: [ExclusionRule]
    @ObservedObject var rulesManager: ExclusionRulesManager
    let highlightedRuleID: UUID?
    let infoText: String?
    let naturalLanguageExceptions: [NaturalLanguageException]
    let onEditRule: (ExclusionRule) -> Void
    let onRemoveNaturalLanguageException: (NaturalLanguageException) -> Void

    @State private var isExpanded = true
    @State private var isShowingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text("\(rules.count + naturalLanguageExceptions.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .numericTextTransition(
                                animationValue: rules.count + naturalLanguageExceptions.count
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)

                if let infoText {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        isShowingInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                    .popover(isPresented: $isShowingInfo, arrowEdge: .trailing) {
                        Text(infoText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(width: 280, alignment: .leading)
                            .systemLiquidGlassPopover(cornerRadius: 12)
                    }
                    .accessibilityLabel("About \(title)")
                    .help("About \(title)")
                }

                Button(action: toggleExpanded) {
                    HStack {
                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    ForEach(naturalLanguageExceptions) { exception in
                        NaturalLanguageExceptionRow(
                            exception: exception,
                            rulesManager: rulesManager,
                            onDelete: { onRemoveNaturalLanguageException(exception) }
                        )

                        if exception.id != naturalLanguageExceptions.last?.id || !rules.isEmpty {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }

                    ForEach(rules) { rule in
                        ExclusionRuleRow(
                            rule: rule,
                            rulesManager: rulesManager,
                            isHighlighted: rule.id == highlightedRuleID,
                            onEdit: { onEditRule(rule) }
                        )
                        .id(rule.id)

                        if rule.id != rules.last?.id {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
            }
        }
        .systemLiquidGlassBackground(cornerRadius: 12)
    }

    private func toggleExpanded() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded.toggle()
        }
        HapticFeedbackManager.shared.tap()
    }
}

struct NaturalLanguageExceptionRow: View {
    @SortyHotReload private var hotReload
    let exception: NaturalLanguageException
    @ObservedObject var rulesManager: ExclusionRulesManager
    let onDelete: () -> Void
    @State private var isHovered = false

    private static let systemFolderIcon: NSImage = {
        NSWorkspace.shared.icon(forFile: "/tmp")
    }()

    var body: some View {
        HStack(spacing: 12) {
            exceptionIcon
                .frame(width: 28, height: 28)
                .background((exception.isEnabled ? Color.purple : .secondary).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(exception.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(exception.isEnabled ? .primary : .secondary)
                        .lineLimit(2)

                    Text("Natural Language")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                HStack(spacing: 6) {
                    Text("Natural language exception")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !exception.referencedPaths.isEmpty {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(exception.referencedPaths.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(exception.referencedPaths.joined(separator: "\n"))
                    }
                }
            }

            Spacer()

            if isHovered {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { exception.isEnabled },
                    set: { isEnabled in
                        HapticFeedbackManager.shared.selection()
                        var updatedException = exception
                        updatedException.isEnabled = isEnabled
                        rulesManager.updateNaturalLanguageException(updatedException)
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(
                exception.isEnabled
                    ? "Disable exception: \(exception.text)"
                    : "Enable exception: \(exception.text)"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text("Delete")) {
            onDelete()
        }
    }

    @ViewBuilder
    private var exceptionIcon: some View {
        if exception.referencedPaths.isEmpty {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(exception.isEnabled ? .purple : .secondary)
        } else {
            AppKitImageView(
                image: Self.systemFolderIcon,
                size: CGSize(width: 16, height: 16),
                opacity: exception.isEnabled ? 1.0 : 0.5
            )
            .frame(width: 16, height: 16)
        }
    }
}

// MARK: - Exclusion Rule Row

struct ExclusionRuleUsageButton: View {
    @SortyHotReload private var hotReload
    let usage: ExclusionRuleUsage?
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails.toggle()
            HapticFeedbackManager.shared.selection()
        } label: {
            Label("\(usage?.matchCount ?? 0)", systemImage: "checkmark.shield")
                .font(.caption2.monospacedDigit())
                .foregroundStyle((usage?.matchCount ?? 0) > 0 ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Show exclusion usage")
        .accessibilityLabel("\(usage?.matchCount ?? 0) files skipped")
        .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rule usage")
                    .font(.headline)
                LabeledContent("Files skipped", value: (usage?.matchCount ?? 0).formatted())
                if let lastMatchedAt = usage?.lastMatchedAt {
                    LabeledContent {
                        Text(lastMatchedAt, format: .dateTime.month().day().year().hour().minute())
                    } label: {
                        Text("Last matched")
                    }
                } else {
                    Text("This rule has not matched a file yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(16)
            .frame(width: 240, alignment: .leading)
            .systemLiquidGlassPopover(cornerRadius: 12)
        }
    }
}
