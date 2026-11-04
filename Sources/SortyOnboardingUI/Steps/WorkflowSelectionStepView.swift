//
//  WorkflowSelectionStepView.swift
//  Sorty
//
//  Workflow/Persona selection step of the onboarding flow
//

import AppKit
import SwiftUI

public struct WorkflowSelectionStepView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var customPersonaStore: CustomPersonaStore
    
    public init() {}
    
    public var body: some View {
        HStack(alignment: .center, spacing: 28) {
            // Left side - explanation
            VStack(alignment: .leading, spacing: 24) {
                Spacer()

                VStack(alignment: .leading, spacing: 16) {
                    OnboardingIconSliver(
                        systemName: "person.crop.circle.badge.checkmark",
                        color: SortyDesignSystem.Colors.resolvedAccent,
                        fontSize: 48
                    )
                    
                    Text("Choose Your Workflow")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    
                    Text("Select a persona that matches how you work. This helps Sorty understand your organization preferences.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(SortyDesignSystem.Colors.info)
                        Text("You can change this anytime in Settings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .sortyInsetSurface(tint: SortyDesignSystem.Colors.info)
                }
                .frame(maxWidth: 350)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 72)
            .padding(.trailing, 24)
            
            // Right side - persona selection. The custom-persona list handles
            // its own overflow without scrolling the whole column.
            personaColumn
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.trailing, 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow Selection Step")
    }

    private var personaColumn: some View {
        VStack(spacing: 8) {
            Text("Select Default Persona")
                .font(.headline)
                .fontWeight(.semibold)
                    
                // Built-in personas grid - 2x2 layout
                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 10, maximum: .infinity)),
                    GridItem(.flexible(minimum: 10, maximum: .infinity))
                ], spacing: 8) {
                    ForEach(PersonaType.allCases, id: \.self) { persona in
                        OnboardingPersonaCard(
                            persona: persona,
                            isSelected: personaManager.selectedPersona == persona && personaManager.selectedCustomPersonaId == nil
                        ) {
                            HapticFeedbackManager.shared.selection()
                            personaManager.selectPersona(persona)
                            appState.personaGeneratorPresentationContext = nil
                        }
                    }
                }
                .frame(maxWidth: 420)
                    
                // Let users choose a built-in persona or generate a custom one.
                // Kept above the custom list so the action stays visible
                // without scrolling even when the list overflows.
                HStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                    Text("or")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                }
                .frame(maxWidth: 420)

                GeneratePersonaButton(
                    style: .compact,
                    title: customPersonaStore.customPersonas.isEmpty ? "Generate a Persona" : "Generate Another",
                    subtitle: "Create a custom workflow",
                    action: presentPersonaGenerator
                )
                .frame(maxWidth: 420)

                if !customPersonaStore.customPersonas.isEmpty {
                    HStack {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 1)
                        Text("or")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 1)
                    }
                    .frame(maxWidth: 420)

                    Group {
                        if customPersonaStore.customPersonas.count > 2 {
                            ScrollView(.vertical) {
                                customPersonaGrid
                            }
                            .contentMargins(.top, 10, for: .scrollContent)
                            .scrollIndicators(.visible)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                VStack(spacing: 0) {
                                    // Gradual fade so cards dissolve into the footer instead of hard-clipping.
                                    LinearGradient(
                                        colors: [
                                            Color(nsColor: .windowBackgroundColor).opacity(0),
                                            Color(nsColor: .windowBackgroundColor)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .frame(height: 20)
                                    Label(
                                        "Scroll to see \(customPersonaStore.customPersonas.count - 2) more",
                                        systemImage: "chevron.down"
                                    )
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(
                                        "\(customPersonaStore.customPersonas.count - 2) more personas available below"
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 2)
                                    .padding(.bottom, 8)
                                    .background(Color(nsColor: .windowBackgroundColor))
                                }
                            }
                            .frame(height: 124)
                        } else {
                            customPersonaGrid
                        }
                    }
                    .frame(maxWidth: 420)

                }

        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func presentPersonaGenerator() {
        appState.personaGeneratorPresentationContext = .onboarding
    }

    private var customPersonaGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(minimum: 10, maximum: .infinity)),
            GridItem(.flexible(minimum: 10, maximum: .infinity))
        ], spacing: 8) {
            ForEach(customPersonaStore.customPersonas) { persona in
                OnboardingCustomPersonaCard(
                    persona: persona,
                    isSelected: personaManager.selectedCustomPersonaId == persona.id,
                    compact: true,
                    onDelete: {
                        let fallbackPersonaID = customPersonaStore
                            .selectionAfterDeletingPersona(id: persona.id)
                        customPersonaStore.deletePersona(id: persona.id)
                        if personaManager.selectedCustomPersonaId == persona.id {
                            if let fallbackPersonaID {
                                personaManager.selectCustomPersona(fallbackPersonaID)
                            } else {
                                personaManager.selectPersona(personaManager.selectedPersona)
                            }
                        }
                    }
                ) {
                    personaManager.selectCustomPersona(persona.id)
                    appState.personaGeneratorPresentationContext = nil
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }
}

// MARK: - Supporting Views

struct OnboardingPersonaCard: View {
    @SortyHotReload private var hotReload
    let persona: PersonaType
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isSelected ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.15) : Color.secondary.opacity(0.1))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: persona.icon)
                        .font(.system(size: 22))
                        .foregroundStyle(isSelected ? SortyDesignSystem.Colors.resolvedAccent : .primary)
                }
                
                VStack(spacing: 2) {
                    Text(persona.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    
                    Text(persona.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xl, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xl, style: .continuous)
                    .fill(cardFill)
            )
            .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.xl)
            .overlay(
                RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xl, style: .continuous)
                    .stroke(cardStroke, lineWidth: isSelected ? 1.4 : 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(isSelected ? "Selected Workflow" : "Use as Default", systemImage: isSelected ? "checkmark.circle.fill" : "checkmark.circle") {
                action()
            }
            .disabled(isSelected)

            Divider()

            Button("Copy Workflow Name", systemImage: "doc.on.doc") {
                copyWorkflowText(persona.displayName)
            }

            Button("Copy Summary", systemImage: "text.quote") {
                copyWorkflowText(persona.description)
            }
        }
        // Fixed geometry: hover and selection change only the shadow color,
        // fill, and stroke, so the glass card never re-blurs a growing shadow.
        .shadow(color: shadowColor, radius: 8, x: 0, y: 4)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .sortyQuick, value: isHovered)
        .animation(
            reduceMotion ? nil : .sortySnappy,
            value: isSelected
        )
    }

    private var cardFill: Color {
        if isSelected {
            return SortyDesignSystem.Colors.resolvedAccent.opacity(0.10)
        }

        return Color.primary.opacity(isHovered ? 0.08 : 0.045)
    }

    private var cardStroke: Color {
        if isSelected {
            return SortyDesignSystem.Colors.resolvedAccent.opacity(0.62)
        }

        return Color.primary.opacity(isHovered ? 0.18 : 0.09)
    }

    private var shadowColor: Color {
        if isSelected {
            return SortyDesignSystem.Colors.resolvedAccent.opacity(0.10)
        }

        return Color.black.opacity(isHovered ? 0.06 : 0.025)
    }
}

struct OnboardingCustomPersonaCard: View {
    @SortyHotReload private var hotReload
    let persona: CustomPersona
    let isSelected: Bool
    var compact: Bool = false
    var onDelete: (() -> Void)?
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let selectionAccent = SortyDesignSystem.Colors.resolvedAccent

    var body: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            action()
        } label: {
            Group {
                if compact {
                    compactBody
                } else {
                    fullBody
                }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(compact ? 10 : 18)
            .background(
                RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xl, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(isHovered ? 0.08 : 0.045),
                                selectionAccent.opacity(isSelected ? 0.16 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.xl)
            .overlay(
                RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xl, style: .continuous)
                    .stroke(
                        isSelected ? selectionAccent.opacity(0.78) : Color.primary.opacity(isHovered ? 0.18 : 0.09),
                        lineWidth: isSelected ? 1.4 : 1
                    )
            )
            .shadow(
                color: (isSelected ? selectionAccent : Color.black).opacity(isHovered || isSelected ? 0.14 : 0.025),
                radius: 8,
                x: 0,
                y: 4
            )
            .contentShape(RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(isSelected ? "Selected Workflow" : "Use as Default", systemImage: isSelected ? "checkmark.circle.fill" : "checkmark.circle") {
                HapticFeedbackManager.shared.tap()
                action()
            }
            .disabled(isSelected)

            Divider()

            Button("Copy Workflow Name", systemImage: "doc.on.doc") {
                copyWorkflowText(persona.name)
            }

            if !persona.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Copy Description", systemImage: "text.quote") {
                    copyWorkflowText(persona.description)
                }
            }

            Button("Copy Prompt", systemImage: "doc.text") {
                copyWorkflowText(persona.promptModifier)
            }

            if let onDelete {
                Divider()

                Button(role: .destructive) {
                    HapticFeedbackManager.shared.tap()
                    withAnimation(.sortySnappy) {
                        onDelete()
                    }
                } label: {
                    Label("Delete Workflow", systemImage: "trash")
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(reduceMotion ? nil : .sortyFade, value: isHovered)
        .animation(
            reduceMotion ? nil : .sortySnappy,
            value: isSelected
        )
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [SortyDesignSystem.Colors.resolvedAccent.opacity(0.22), selectionAccent.opacity(0.16)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)

                    Image(systemName: persona.icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(isSelected ? selectionAccent : .primary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(persona.name)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 8)

                        Text(isSelected ? "Selected" : "Custom")
                            .numericTextTransition(animationValue: isSelected)
                            .sortyBadge(tint: isSelected ? selectionAccent : nil)
                    }

                    Text(isSelected ? "Sorty will use this custom workflow by default." : "Custom workflow ready to use as your default persona.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .numericTextTransition(animationValue: isSelected)
                }
            }

            if !persona.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("\"\(persona.description)\"")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Label("Sorty-generated persona", systemImage: "sparkles")
                Label(isSelected ? "Default workflow" : "Ready to select", systemImage: isSelected ? "checkmark.circle.fill" : "arrow.up.right.circle")
                    .symbolReplaceTransition(animationValue: isSelected)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // Matches the built-in OnboardingPersonaCard's compact 2-column layout.
    private var compactBody: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(compactIconFill)
                    .frame(width: 44, height: 44)

                Image(systemName: persona.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? selectionAccent : .primary)
            }

            VStack(spacing: 2) {
                Text(persona.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(isSelected ? "Selected workflow" : "Custom workflow")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .numericTextTransition(animationValue: isSelected)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var compactIconFill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(selectionAccent.opacity(0.20))
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [SortyDesignSystem.Colors.resolvedAccent.opacity(0.18), SortyDesignSystem.Colors.resolvedAccent.opacity(0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

@MainActor
private func copyWorkflowText(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    HapticFeedbackManager.shared.selection()
}

// MARK: - Preview

#Preview {
    WorkflowSelectionStepView()
        .environmentObject(PersonaManager())
        .environmentObject(SettingsViewModel())
        .environmentObject(CustomPersonaStore())
        .environmentObject(AppState())
}
