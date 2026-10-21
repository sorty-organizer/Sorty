//
//  ExclusionRulesView.swift
//  Sorty
//
//  Modern exclusion rules management with grouped cards and improved UX
//

import SwiftUI
import UniformTypeIdentifiers

struct ExclusionRulesView: View {
    @SortyHotReload var hotReload
    @EnvironmentObject var rulesManager: ExclusionRulesManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var learningsManager: LearningsManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.controlActiveState) var controlActiveState
    @Environment(\.scenePhase) var scenePhase
    /// Injected for tests (MockAIClient); defaults to the factory in production.
    var injectedAIClient: (any AIClientProtocol)? = nil
    @State var showingAddRule = false
    @State var isUsingManualExclusion = false
    @State var ruleToEdit: ExclusionRule?
    @State var showingLearningExclusionImporter = false
    @State var searchText = ""
    @State var newNLException = ""
    @State var naturalLanguageSuggestionIndex = 0
    @State var isImprovingException = false
    @State var isCreatingExceptionRules = false
    @State var resolvedExceptionRules: [ExclusionRule] = []
    @State var revealedExceptionRuleCount = 0
    @State var resolvedSupplementalDescription: String?
    @State var streamedRuleDetails: [UUID: String] = [:]
    @State var isShowingResolvedRuleDetails = false
    @State var showCreateExceptionError = false
    @State var createExceptionErrorMessage = ""
    @State var showImproveExceptionRequest = false
    @State var improveExceptionRequestMessage = ""
    @State var learningExclusionSliverTrigger = 0
    @State var isShowingLearningExclusionsInfo = false
    @State var isShowingNaturalLanguageExceptionsInfo = false
    @State var isLearningExclusionsExpanded = true
    @State var showingRemoveAllConfirmation = false
    @State var isWindowVisible = true
    @FocusState var isNLExceptionFocused: Bool

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool {
        !trimmedSearchText.isEmpty
    }

    var filteredRules: [ExclusionRule] {
        let newestFirst = Array(rulesManager.rules.reversed())
        if !isSearching {
            return newestFirst
        }
        return newestFirst.filter {
            $0.displayDescription.localizedCaseInsensitiveContains(trimmedSearchText)
                || $0.type.rawValue.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    var groupedRules: [(String, [ExclusionRule])] {
        var orderedTitles: [String] = []
        for rule in filteredRules {
            let title = groupTitle(for: rule.type)
            if !orderedTitles.contains(title) {
                orderedTitles.append(title)
            }
        }
        if !filteredNaturalLanguageExceptions.isEmpty,
           !orderedTitles.contains("Files & Folders") {
            orderedTitles.append("Files & Folders")
        }

        return orderedTitles.compactMap { title in
            let rules = filteredRules.filter { groupTitle(for: $0.type) == title }
            let hasNaturalLanguageExceptions =
                title == "Files & Folders" && !filteredNaturalLanguageExceptions.isEmpty
            return rules.isEmpty && !hasNaturalLanguageExceptions ? nil : (title, rules)
        }
    }

    func groupTitle(for type: ExclusionRuleType) -> String {
        switch type {
        case .fileExtension, .fileName, .folderName, .pathContains, .fileType:
            "Files & Folders"
        case .fileSize, .creationDate, .modificationDate, .regex, .customScript:
            "Conditions"
        case .hiddenFiles, .systemFiles, .finderTag:
            "macOS"
        }
    }

    var filteredLearningExclusionPatterns: [String] {
        let patterns = learningsManager.currentProfile?.learningExclusionPatterns ?? []
        guard isSearching else { return patterns }
        return patterns.filter { $0.localizedCaseInsensitiveContains(trimmedSearchText) }
    }

    var filteredNaturalLanguageExceptions: [NaturalLanguageException] {
        let exceptions = rulesManager.naturalLanguageExceptions
        guard isSearching else { return exceptions }
        return exceptions.filter { exception in
            exception.text.localizedCaseInsensitiveContains(trimmedSearchText)
                || exception.referencedPaths.contains {
                    $0.localizedCaseInsensitiveContains(trimmedSearchText)
                }
        }
    }

    var hasSearchResults: Bool {
        !groupedRules.isEmpty || !filteredLearningExclusionPatterns.isEmpty
            || !filteredNaturalLanguageExceptions.isEmpty
    }

    let naturalLanguageExceptionSuggestions = [
        "Exclude folders named Archive and everything inside them",
        "Exclude folders named Receipts and everything inside them",
        "Exclude PDF files with tax or passport in the file name",
        "Exclude video files larger than 1 GB",
    ]

    var naturalLanguageSuggestion: String {
        naturalLanguageExceptionSuggestions[naturalLanguageSuggestionIndex]
    }

    var hasNaturalLanguageExceptionText: Bool {
        !newNLException.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if rulesManager.rules.count > 1 {
                content
                    .searchable(text: $searchText, prompt: "Search rules")
            } else {
                content
            }
        }
        .onChange(of: rulesManager.rules.count) { previousCount, count in
            if count <= 1 {
                searchText = ""
            }
            if count > previousCount, let newestRule = rulesManager.rules.last {
                appState.highlightedExclusionRuleID = newestRule.id
            }
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
    }

    var content: some View {
        VStack(spacing: 0) {
            if rulesManager.rules.isEmpty {
                ZStack(alignment: .topLeading) {
                    EmptyExclusionRulesView(onAddRule: {
                        HapticFeedbackManager.shared.tap()
                        isUsingManualExclusion = false
                        showingAddRule = true
                    })
                    .transition(TransitionStyles.scaleAndFade)
                    .animatedAppearance(delay: 0.08)

                    emptyHeaderView
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .animatedAppearance(delay: 0.03)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Header
                headerView
                    .animatedAppearance(delay: 0.03)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 20) {
                            // Grouped rules
                            ForEach(Array(groupedRules.enumerated()), id: \.1.0) { index, group in
                                RuleGroupCard(
                                    title: group.0,
                                    rules: group.1,
                                    rulesManager: rulesManager,
                                    highlightedRuleID: appState.highlightedExclusionRuleID,
                                    infoText: group.0 == "Files & Folders"
                                        ? "Matching files and folders are excluded from organizations, renames, and learnings."
                                        : nil,
                                    naturalLanguageExceptions: group.0 == "Files & Folders"
                                        ? filteredNaturalLanguageExceptions : [],
                                    onEditRule: { ruleToEdit = $0 },
                                    onRemoveNaturalLanguageException: { exception in
                                        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82)) {
                                            rulesManager.removeNaturalLanguageException(id: exception.id)
                                        }
                                    }
                                )
                                .animatedAppearance(delay: Double(index) * 0.05)
                            }

                            if !hasSearchResults && isSearching {
                                VStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.title)
                                        .foregroundStyle(.secondary)
                                    Text("No rules match '\(trimmedSearchText)'")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                            }

                            if !isSearching || !filteredLearningExclusionPatterns.isEmpty {
                                learningExclusionsCard
                                    .animatedAppearance(delay: 0.12)
                            }

                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 20)
                    }
                    .transition(TransitionStyles.slideFromRight)
                    .onAppear {
                        scrollToHighlightedRule(using: proxy)
                    }
                    .onChange(of: appState.highlightedExclusionRuleID) { _, _ in
                        scrollToHighlightedRule(using: proxy)
                    }
                }
                .animation(.pageTransition, value: rulesManager.rules.isEmpty)
            }
        }
        .emptyStateWorkflowGradient(isVisible: rulesManager.rules.isEmpty)
        .animation(.pageTransition, value: rulesManager.rules.isEmpty)
        .navigationTitle("Exclusions")
        .sheet(isPresented: $showingAddRule) {
            addExclusionSheet
                .modalBounce()
        }
        .sheet(item: $ruleToEdit) { rule in
            AddExclusionRuleView(
                rulesManager: rulesManager,
                editing: rule,
                relatedRules: rulesLinked(to: rule)
            )
                .modalBounce()
        }
        .fileImporter(
            isPresented: $showingLearningExclusionImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            handleLearningExclusionImport(result)
        }
    }

    func rulesLinked(to rule: ExclusionRule) -> [ExclusionRule] {
        guard let groupID = rule.conditionGroupID else { return [rule] }
        return rulesManager.rules.filter { $0.conditionGroupID == groupID }
    }

    func scrollToHighlightedRule(using proxy: ScrollViewProxy) {
        guard let ruleID = appState.highlightedExclusionRuleID else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(ruleID, anchor: .center)
            }
            try? await Task.sleep(for: .seconds(3))
            if appState.highlightedExclusionRuleID == ruleID {
                appState.highlightedExclusionRuleID = nil
            }
        }
    }

    var headerView: some View {
        HStack {
            HStack(spacing: 12) {
                if appState.navigatedFromSettings {
                    GlassyBackButton {
                        HapticFeedbackManager.shared.tap()
                        appState.navigatedFromSettings = false
                        appState.openSettingsWindow(section: .rules)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Exclusions")
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        Text("\(rulesManager.enabledRulesCount) active")
                            .foregroundStyle(.green)
                            .numericTextTransition(
                                animationValue: rulesManager.enabledRulesCount
                            )
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(
                            "\(rulesManager.rules.count - rulesManager.enabledRulesCount) disabled"
                        )
                        .foregroundStyle(.secondary)
                        .numericTextTransition(
                            animationValue: rulesManager.rules.count
                                - rulesManager.enabledRulesCount
                        )
                    }
                    .font(.caption)
                }
            }
            .animatedAppearance(delay: 0.05)

            Spacer()

            if !rulesManager.rules.isEmpty {
                Button {
                    HapticFeedbackManager.shared.tap()
                    showingRemoveAllConfirmation = true
                } label: {
                    Label("Remove All", systemImage: "trash")
                }
                .buttonStyle(.tintedPill(.red, size: .small))
                .controlSize(.small)
                .accessibilityIdentifier("ClearAllExclusionsButton")
                .confirmationDialog(
                    "Remove all \(rulesManager.rules.count) exclusion rules?",
                    isPresented: $showingRemoveAllConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Remove All", role: .destructive) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            rulesManager.clearAllRules()
                        }
                        HapticFeedbackManager.shared.success()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Excluded files and folders will become eligible for organization and learnings again.")
                }
            }

            Button {
                HapticFeedbackManager.shared.tap()
                isUsingManualExclusion = false
                showingAddRule = true
            } label: {
                Label("Add Exclusion", systemImage: "plus")
            }
            .buttonStyle(.sortyPrimary)
            .onboardingBeamBorder(variant: .featured)
            .accessibilityIdentifier("AddExclusionRuleButton")
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    var addExclusionSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    showingAddRule = false
                    isUsingManualExclusion = false
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Text("Add an Exclusion")
                    .font(.headline)

                Spacer()

                Button("Cancel") {}
                    .hidden()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !isUsingManualExclusion {
                        naturalLanguageExceptionsCard
                            .transition(exclusionEditorTransition)
                    }

                    Button {
                        HapticFeedbackManager.shared.selection()
                        withAnimation(exclusionEditorAnimation) {
                            isUsingManualExclusion.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(height: 1)
                            Text(isUsingManualExclusion ? "Or describe it instead" : "Or set it up manually")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .contentTransition(.opacity)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(height: 1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(
                        isUsingManualExclusion
                            ? "Collapses the manual options and shows the description field"
                            : "Collapses the description field and shows the manual options"
                    )

                    if isUsingManualExclusion {
                        AddExclusionRuleView(
                            rulesManager: rulesManager,
                            isEmbedded: true
                        )
                        .transition(exclusionEditorTransition)
                    }
                }
                .padding(20)
                .animation(exclusionEditorAnimation, value: isUsingManualExclusion)
            }
        }
        .frame(width: 680, height: 720)
    }

    var exclusionEditorAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.88, blendDuration: 0.12)
    }

    var exclusionEditorTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: ExclusionEditorTransitionModifier(opacity: 0, blurRadius: 10, yOffset: 10, scale: 0.985),
                identity: ExclusionEditorTransitionModifier()
            ),
            removal: .modifier(
                active: ExclusionEditorTransitionModifier(opacity: 0, blurRadius: 6, yOffset: -6, scale: 0.985),
                identity: ExclusionEditorTransitionModifier()
            )
        )
    }

    var emptyHeaderView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Exclusions")
                    .font(.largeTitle.bold())

                Text(
                    "Keep protected files, folders, and patterns out of organization and learnings"
                )
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

}

// FlowLayout is now defined globally in AnalysisView.swift

#Preview {
    ExclusionRulesView()
        .environmentObject(ExclusionRulesManager())
        .frame(width: 600, height: 550)
}
