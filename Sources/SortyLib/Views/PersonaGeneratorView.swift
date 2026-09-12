//
//  PersonaGeneratorView.swift
//  Sorty
//
//  UI for generating personas from natural language
//

import Foundation
import SwiftUI
import Beam

struct PersonaGeneratorView: View {
    @SortyHotReload private var hotReload
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject var store: CustomPersonaStore
    @Binding var selectedPersonaId: String?
    var onPersonaGenerated: (() -> Void)? = nil
    
    @StateObject private var generator = PersonaGenerator()
    @State private var prompt: String = ""
    @State private var promptSelection = NSRange(location: 0, length: 0)
    @State private var promptSuggestionIndex: Int = 0
    @State private var isWindowVisible = true
    @Environment(\.controlActiveState) private var controlActiveState
    
    @StateObject private var honingEngine = PersonaHoningEngine()
    @State private var questions: [HoningQuestion] = []
    @State private var answers: [String: String] = [:]
    @State private var customAnswers: [String: String] = [:]
    @State private var isHoning: Bool = false
    @State private var isLoadingQuestions: Bool = false
    @State private var currentQuestionIndex: Int = 0
    @FocusState private var focusedCustomAnswerQuestionID: String?

    private let promptSuggestions = [
        "Organize my sci-fi ebook collection by author, then series.",
        "Group my photos by year and event, with RAW files separate from edits.",
        "Sort client work by project, then keep active and completed work separate.",
        "Organize school files by subject, unit, and assignment type.",
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                if isHoning, let question = currentHoningQuestion {
                    honingView(question: question)
                } else {
                    initialInputView
                }
            }
            
            if generator.isGenerating {
                generationOverlay
            }
        }
        .frame(width: 500, height: isHoning || generator.isGenerating ? 550 : 430)
        .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.82),
            value: isHoning || generator.isGenerating
        )
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
    }

    private var generationOverlay: some View {
        VStack(spacing: 22) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                .frame(width: 58, height: 58)
                .background(
                    SortyDesignSystem.Colors.resolvedAccent.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .symbolEffect(.breathe, isActive: !reduceMotion)

            VStack(spacing: 10) {
                Text("Building Your Persona")
                    .font(.title3.weight(.bold))
            }

            VStack(spacing: 6) {
                if !generator.generationUpdate.isEmpty {
                    Label("Live model update", systemImage: "brain")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                }

                Text(currentGenerationStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 360)
                    .frame(minHeight: 42)
                    .numericTextTransition(animationValue: currentGenerationStatus)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
            }
            .animation(.easeInOut(duration: 0.22), value: currentGenerationStatus)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .overlay {
            PersonaGenerationBorderBeam(cornerRadius: 18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var initialInputView: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                    .animatedEmptyStateIcon()
                
                Text("Generate Persona")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Describe your ideal organization style.")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            
            // Input Area
            VStack(alignment: .leading, spacing: 8) {
                Text("I want to organize...")
                    .font(.headline)
                
                ZStack(alignment: .topLeading) {
                    SubmittableTextEditor(
                        text: $prompt,
                        selectedRange: $promptSelection,
                        onAcceptSuggestion: acceptCurrentPromptSuggestion
                    ) {
                        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !isLoadingQuestions
                        else {
                            return
                        }
                        startHoning()
                    }

                    if prompt.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Text(currentPromptSuggestion)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .numericTextTransition(animationValue: promptSuggestionIndex)

                            Spacer(minLength: 0)

                            Text("Tab")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Color.secondary.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .accessibilityHidden(true)
                        }
                        .padding(.leading, 15)
                        .padding(.trailing, 10)
                        .padding(.top, 7)
                        .allowsHitTesting(false)
                        .task(id: shouldCyclePromptSuggestions) {
                            guard shouldCyclePromptSuggestions else { return }
                            promptSuggestionIndex = 0

                            while !Task.isCancelled {
                                try? await Task.sleep(for: .seconds(2.5))
                                guard !Task.isCancelled,
                                      shouldCyclePromptSuggestions else { return }
                                promptSuggestionIndex =
                                    (promptSuggestionIndex + 1) % promptSuggestions.count
                            }
                        }
                    }
                }
                .frame(height: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
                .accessibilityLabel("Persona description")
                .accessibilityHint(
                    prompt.isEmpty
                        ? "Press Tab to use the suggested description"
                        : "Press Command and Return to continue"
                )
            }
            .padding(.horizontal, 30)
            
            if let error = generator.error {
                Text(error.localizedDescription).foregroundColor(.red).font(.caption).padding(.horizontal)
            }
            
            HStack(spacing: 16) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.sortyBordered)
                
                Button {
                    startHoning()
                } label: {
                    if isLoadingQuestions {
                        SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                    } else {
                        Text("Next")
                    }
                }
                .buttonStyle(.sortyProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingQuestions)
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
    }

    private var shouldCyclePromptSuggestions: Bool {
        prompt.isEmpty
            && !isHoning
            && !generator.isGenerating
            && isWindowVisible
            && controlActiveState != .inactive
    }
    
    private func honingView(question: HoningQuestion) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Text("Refining Your Persona")
                    .font(.title3.weight(.bold))

                Text("Question \(currentQuestionIndex + 1) of \(questions.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                    .numericTextTransition(animationValue: currentQuestionIndex)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        SortyDesignSystem.Colors.resolvedAccent.opacity(0.12),
                        in: Capsule(style: .continuous)
                    )
            }
            .padding(.top, 18)

            SortyGradientProgressBar(
                progress: Double(currentQuestionIndex + 1) / Double(max(questions.count, 1)),
                accent: SortyDesignSystem.Colors.resolvedAccent,
                height: 9
            )
            .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 16) {
                Text(question.text)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                
                ForEach(question.options, id: \.self) { option in
                    HoningOptionButton(
                        option: option,
                        isSelected: answers[question.id] == option
                    ) {
                        selectAnswer(option, for: question)
                    }
                }

                customAnswerField(for: question)
            }
            .padding(.horizontal, 30)

            if let error = generator.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
            
            HStack {
                if currentQuestionIndex > 0 {
                    Button("Back") {
                        focusedCustomAnswerQuestionID = nil
                        HapticFeedbackManager.shared.selection()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                            currentQuestionIndex -= 1
                        }
                    }
                    .buttonStyle(.sortyBordered)
                }
                
                Spacer()
                
                Button(currentQuestionIndex == questions.count - 1 ? "Generate Persona" : "Next") {
                    advance(from: question)
                }
                .buttonStyle(.sortyProminent)
                .disabled(answers[question.id] == nil || generator.isGenerating)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
        }
    }
    
    private func selectAnswer(_ option: String, for question: HoningQuestion) {
        focusedCustomAnswerQuestionID = nil
        guard answers[question.id] != option else { return }
        HapticFeedbackManager.shared.selection()
        customAnswers[question.id] = ""
        answers[question.id] = option
    }

    private func customAnswerBinding(for question: HoningQuestion) -> Binding<String> {
        Binding(
            get: { customAnswers[question.id] ?? "" },
            set: { value in
                customAnswers[question.id] = value
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    answers[question.id] = nil
                } else {
                    answers[question.id] = trimmed
                }
            }
        )
    }

    private func customAnswerField(for question: HoningQuestion) -> some View {
        let answer = customAnswers[question.id] ?? ""
        let showsPlaceholder = answer.isEmpty
            && focusedCustomAnswerQuestionID != question.id

        return ZStack(alignment: .leading) {
            Text(showsPlaceholder ? "Or type exactly what you want…" : "")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .allowsHitTesting(false)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(reduceMotion ? .easeOut(duration: 0.12) : .default, value: showsPlaceholder)

            TextField("", text: customAnswerBinding(for: question))
                .focused($focusedCustomAnswerQuestionID, equals: question.id)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard answers[question.id] != nil else { return }
                    advance(from: question)
                }
                .accessibilityLabel("Custom answer")
        }
    }

    private func advance(from question: HoningQuestion) {
        focusedCustomAnswerQuestionID = nil
        guard answers[question.id] != nil else { return }

        if currentQuestionIndex < questions.count - 1 {
            HapticFeedbackManager.shared.selection()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                currentQuestionIndex += 1
            }
        } else {
            generateFinalPersona()
        }
    }

    private var currentHoningQuestion: HoningQuestion? {
        guard questions.indices.contains(currentQuestionIndex) else { return nil }
        return questions[currentQuestionIndex]
    }

    private var currentPromptSuggestion: String {
        promptSuggestions[promptSuggestionIndex % promptSuggestions.count]
    }

    private func acceptCurrentPromptSuggestion() -> Bool {
        guard prompt.isEmpty else { return false }

        prompt = currentPromptSuggestion
        promptSelection = NSRange(
            location: (currentPromptSuggestion as NSString).length,
            length: 0
        )
        HapticFeedbackManager.shared.selection()
        return true
    }
    
    private func startHoning() {
        guard !isLoadingQuestions else { return }

        isLoadingQuestions = true
        currentQuestionIndex = 0
        answers.removeAll()
        customAnswers.removeAll()

        Task {
            do {
                questions = try await honingEngine.generateQuestions(from: prompt, config: settingsViewModel.config)
                if questions.isEmpty {
                    generateFinalPersona()
                } else {
                    HapticFeedbackManager.shared.selection()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        isHoning = true
                    }
                }
            } catch {
                generateFinalPersona()
            }
            isLoadingQuestions = false
        }
    }
    
    private func generateFinalPersona() {
        Task {
            let richAnswers = questions.compactMap { question -> HoningAnswer? in
                guard let answer = answers[question.id] else { return nil }
                return HoningAnswer(
                    questionId: question.id,
                    selectedOption: "Q: \(question.text) -> A: \(answer)"
                )
            }

            do {
                let result = try await generator.generatePersona(from: prompt, answers: richAnswers, config: settingsViewModel.config)
                
                let newPersona = CustomPersona(
                    name: result.name,
                    icon: result.icon,
                    description: prompt,
                    promptModifier: result.prompt,
                    instructionSuggestions: result.suggestions
                )
                
                await MainActor.run {
                    store.addPersona(newPersona)
                    selectedPersonaId = newPersona.id
                    onPersonaGenerated?()
                    HapticFeedbackManager.shared.success()
                    NotificationManager.shared.showHUDInfo(
                        title: "Persona Ready",
                        message: "\(newPersona.name) is saved and now active.",
                        icon: "checkmark.circle.fill",
                        iconColor: SortyDesignSystem.Colors.resolvedAccent,
                        identifier: "persona-generated"
                    )
                    dismiss()
                }
            } catch {
                HapticFeedbackManager.shared.error()
            }
        }
    }

    private var currentGenerationStatus: String {
        if !generator.generationUpdate.isEmpty {
            return generator.generationUpdate
        }
        return answers.isEmpty
            ? "Preparing a tailored organization strategy from your description."
            : "Preparing a strategy from your description and \(answers.count) refinements."
    }
}

private struct PersonaGenerationBorderBeam: View {
    @SortyHotReload private var hotReload
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private let rotationDuration: TimeInterval = 2.4

    private var isAnimationActive: Bool {
        controlActiveState != .inactive
    }

    private var shouldAnimate: Bool {
        !reduceMotion && isAnimationActive
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.clear)
            .beam(
                .medium,
                palette: .colorful,
                theme: .dark,
                active: isAnimationActive,
                cornerRadius: cornerRadius,
                duration: rotationDuration,
                strength: 1.0
            )
            .overlay {
                fallbackBeam
            }
    }

    private var fallbackBeam: some View {
        SwiftUI.TimelineView(
            .animation(minimumInterval: 1.0 / 20.0, paused: !shouldAnimate)
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = shouldAnimate ? time / rotationDuration : 0

            ZStack {
                beamInteriorGlow(phase: phase)
                beamStroke(phase: phase)
            }
            .opacity(0.82)
        }
    }

    private func beamStroke(phase: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .clear, location: 0.08),
                        .init(
                            color: Color(red: 0.08, green: 0.80, blue: 1.0)
                                .opacity(0.36),
                            location: 0.16
                        ),
                        .init(
                            color: Color(red: 0.92, green: 0.16, blue: 0.58)
                                .opacity(0.62),
                            location: 0.25
                        ),
                        .init(color: .white.opacity(0.88), location: 0.32),
                        .init(
                            color: Color(red: 1.0, green: 0.34, blue: 0.18)
                                .opacity(0.54),
                            location: 0.39
                        ),
                        .init(
                            color: Color(red: 0.40, green: 0.20, blue: 1.0)
                                .opacity(0.36),
                            location: 0.48
                        ),
                        .init(color: .clear, location: 0.58),
                        .init(color: .clear, location: 1.00),
                    ],
                    center: .center,
                    angle: .degrees(
                        (phase.truncatingRemainder(dividingBy: 1)) * 360
                    )
                ),
                lineWidth: 1
            )
    }

    private func beamInteriorGlow(phase: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .inset(by: 3)
            .fill(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(
                            color: Color(red: 0.08, green: 0.80, blue: 1.0)
                                .opacity(0.10),
                            location: 0.15
                        ),
                        .init(
                            color: Color(red: 0.92, green: 0.16, blue: 0.58)
                                .opacity(0.20),
                            location: 0.25
                        ),
                        .init(color: .white.opacity(0.16), location: 0.32),
                        .init(
                            color: Color(red: 1.0, green: 0.34, blue: 0.18)
                                .opacity(0.14),
                            location: 0.40
                        ),
                        .init(color: .clear, location: 0.58),
                        .init(color: .clear, location: 1.00),
                    ],
                    center: .center,
                    angle: .degrees(
                        (phase.truncatingRemainder(dividingBy: 1)) * 360
                    )
                )
            )
            .blur(radius: 9)
            .mask {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(lineWidth: 22)
                    .blur(radius: 7)
            }
    }
}

private struct HoningOptionButton: View {
    @SortyHotReload private var hotReload
    let option: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var accent: Color {
        SortyDesignSystem.Colors.resolvedAccent
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(option)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? accent
                            : Color.secondary.opacity(isHovered ? 0.72 : 0.36)
                    )
                    .symbolReplaceTransition(animationValue: isSelected)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(cardFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: isSelected ? 1.5 : 1)
            }
            .shadow(
                color: accent.opacity(isSelected ? 0.10 : isHovered ? 0.07 : 0),
                radius: isHovered || isSelected ? 10 : 0,
                y: isHovered ? 4 : 2
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering && !isHovered {
                HapticFeedbackManager.shared.selection()
            }
            isHovered = hovering
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.15),
            value: isHovered
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6),
            value: isSelected
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardFill: Color {
        if isSelected {
            return accent.opacity(0.11)
        }
        if isHovered {
            return accent.opacity(0.055)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardStroke: Color {
        if isSelected {
            return accent.opacity(0.82)
        }
        if isHovered {
            return accent.opacity(0.34)
        }
        return Color.secondary.opacity(0.18)
    }
}
