//
//  ExclusionRulesView.swift
//  Sorty
//
//  Modern exclusion rules management with grouped cards and improved UX
//

import SwiftUI
import UniformTypeIdentifiers

struct ExclusionRulesView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var rulesManager: ExclusionRulesManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var learningsManager: LearningsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    /// Injected for tests (MockAIClient); defaults to the factory in production.
    var injectedAIClient: (any AIClientProtocol)? = nil
    @State private var showingAddRule = false
    @State private var isUsingManualExclusion = false
    @State private var ruleToEdit: ExclusionRule?
    @State private var showingLearningExclusionImporter = false
    @State private var searchText = ""
    @State private var newNLException = ""
    @State private var naturalLanguageSuggestionIndex = 0
    @State private var isImprovingException = false
    @State private var isCreatingExceptionRules = false
    @State private var resolvedExceptionRules: [ExclusionRule] = []
    @State private var revealedExceptionRuleCount = 0
    @State private var resolvedSupplementalDescription: String?
    @State private var streamedRuleDetails: [UUID: String] = [:]
    @State private var isShowingResolvedRuleDetails = false
    @State private var showCreateExceptionError = false
    @State private var createExceptionErrorMessage = ""
    @State private var showImproveExceptionRequest = false
    @State private var improveExceptionRequestMessage = ""
    @State private var learningExclusionSliverTrigger = 0
    @State private var isShowingLearningExclusionsInfo = false
    @State private var isShowingNaturalLanguageExceptionsInfo = false
    @State private var isLearningExclusionsExpanded = true
    @State private var showingRemoveAllConfirmation = false
    @State private var isWindowVisible = true
    @FocusState private var isNLExceptionFocused: Bool

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearchText.isEmpty
    }

    private var filteredRules: [ExclusionRule] {
        let newestFirst = Array(rulesManager.rules.reversed())
        if !isSearching {
            return newestFirst
        }
        return newestFirst.filter {
            $0.displayDescription.localizedCaseInsensitiveContains(trimmedSearchText)
                || $0.type.rawValue.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    private var groupedRules: [(String, [ExclusionRule])] {
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

    private func groupTitle(for type: ExclusionRuleType) -> String {
        switch type {
        case .fileExtension, .fileName, .folderName, .pathContains, .fileType:
            "Files & Folders"
        case .fileSize, .creationDate, .modificationDate, .regex, .customScript:
            "Conditions"
        case .hiddenFiles, .systemFiles, .finderTag:
            "macOS"
        }
    }

    private var filteredLearningExclusionPatterns: [String] {
        let patterns = learningsManager.currentProfile?.learningExclusionPatterns ?? []
        guard isSearching else { return patterns }
        return patterns.filter { $0.localizedCaseInsensitiveContains(trimmedSearchText) }
    }

    private var filteredNaturalLanguageExceptions: [NaturalLanguageException] {
        let exceptions = rulesManager.naturalLanguageExceptions
        guard isSearching else { return exceptions }
        return exceptions.filter { exception in
            exception.text.localizedCaseInsensitiveContains(trimmedSearchText)
                || exception.referencedPaths.contains {
                    $0.localizedCaseInsensitiveContains(trimmedSearchText)
                }
        }
    }

    private var hasSearchResults: Bool {
        !groupedRules.isEmpty || !filteredLearningExclusionPatterns.isEmpty
            || !filteredNaturalLanguageExceptions.isEmpty
    }

    private let naturalLanguageExceptionSuggestions = [
        "Exclude folders named Archive and everything inside them",
        "Exclude folders named Receipts and everything inside them",
        "Exclude PDF files with tax or passport in the file name",
        "Exclude video files larger than 1 GB",
    ]

    private var naturalLanguageSuggestion: String {
        naturalLanguageExceptionSuggestions[naturalLanguageSuggestionIndex]
    }

    private var hasNaturalLanguageExceptionText: Bool {
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

    private var content: some View {
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

    private func rulesLinked(to rule: ExclusionRule) -> [ExclusionRule] {
        guard let groupID = rule.conditionGroupID else { return [rule] }
        return rulesManager.rules.filter { $0.conditionGroupID == groupID }
    }

    private func scrollToHighlightedRule(using proxy: ScrollViewProxy) {
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

    private var headerView: some View {
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

    private var addExclusionSheet: some View {
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

    private var exclusionEditorAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.88, blendDuration: 0.12)
    }

    private var exclusionEditorTransition: AnyTransition {
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

    private var emptyHeaderView: some View {
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

    // MARK: - Natural Language Exceptions

    private var learningExclusionsCard: some View {
        SettingsCard(
            title: "Learning Exclusions",
            icon: "eye.slash",
            color: .orange,
            count: filteredLearningExclusionPatterns.count,
            isExpanded: $isLearningExclusionsExpanded,
            headerAccessory: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onHover { hovering in
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                        isShowingLearningExclusionsInfo = hovering
                    }
                    .popover(
                        isPresented: $isShowingLearningExclusionsInfo,
                        arrowEdge: .trailing
                    ) {
                        Text(
                            "Folders here are still organized, but they won't teach Sorty anything."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(width: 280, alignment: .leading)
                        .systemLiquidGlassPopover(cornerRadius: 12)
                    }
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let patterns = learningsManager.currentProfile?.learningExclusionPatterns,
                    !patterns.isEmpty
                {
                    HStack {
                        Spacer()

                        Button {
                            presentLearningExclusionImporter()
                        } label: {
                            Label("Add Folder", systemImage: "plus")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.sortyPrimary(size: .small))
                        .accessibilityIdentifier("AddLearningExclusionFolderButton")
                    }
                }

                if !filteredLearningExclusionPatterns.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(filteredLearningExclusionPatterns, id: \.self) { pattern in
                            LearningExclusionRow(pattern: pattern, manager: learningsManager)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange.opacity(0.6))
                            .milestoneEmptyStateSliver(
                                trigger: learningExclusionSliverTrigger,
                                tint: .orange
                            )
                            .onScrollVisibilityChange(threshold: 0.6) { isVisible in
                                guard isVisible else { return }
                                learningExclusionSliverTrigger += 1
                            }
                            .accessibilityHidden(true)
                        Text("No folders excluded")
                            .font(.subheadline.bold())
                        Text(
                            "Exclude folders that should still be organized but shouldn't teach Sorty anything."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                        Button {
                            presentLearningExclusionImporter()
                        } label: {
                            Label("Exclude Folder", systemImage: "plus")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.sortyPrimary(size: .small))
                        .accessibilityIdentifier("EmptyStateAddLearningExclusionFolderButton")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
                }
            }
        }
    }

    private var naturalLanguageExceptionsCard: some View {
        SettingsCard(
            title: "Describe an Exception",
            icon: "sparkles",
            color: .purple,
            count: 0,
            isExpanded: nil,
            headerAccessory: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onHover { hovering in
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                        isShowingNaturalLanguageExceptionsInfo = hovering
                    }
                    .popover(
                        isPresented: $isShowingNaturalLanguageExceptionsInfo,
                        arrowEdge: .trailing
                    ) {
                        Text("Describe what to exclude. Sorty turns it into the same structured rules available in the manual options below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(width: 280, alignment: .leading)
                            .systemLiquidGlassPopover(cornerRadius: 12)
                    }
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if isCreatingExceptionRules || !resolvedExceptionRules.isEmpty {
                    exceptionInterpretation
                        .transition(.blurReplace.combined(with: .opacity))
                } else {
                    Text("Use ordinary language — you can combine names, folders, file kinds, and context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .center, spacing: 10) {
                        ZStack(alignment: .leading) {
                        TextField("", text: $newNLException, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNLExceptionFocused)
                            .accessibilityLabel("Exception description")
                            .onKeyPress(.tab) {
                                guard newNLException.isEmpty else { return .ignored }
                                newNLException = naturalLanguageSuggestion
                                HapticFeedbackManager.shared.selection()
                                return .handled
                            }
                            .onSubmit {
                                Task { await createRulesFromNaturalLanguage() }
                            }

                        if newNLException.isEmpty {
                            HStack(spacing: 10) {
                                Text(naturalLanguageSuggestion)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .numericTextTransition(
                                        animationValue: naturalLanguageSuggestionIndex
                                    )

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
                            .padding(.horizontal, 8)
                            .allowsHitTesting(false)
                        }
                    }

                        HStack(spacing: 8) {
                        if hasNaturalLanguageExceptionText {
                            Button {
                                Task { await improveExceptionWithAI() }
                            } label: {
                                if isImprovingException {
                                    SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                                        .frame(width: 58)
                                } else {
                                    Label("Improve", systemImage: "wand.and.stars")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(height: 32)
                            .foregroundStyle(.tint)
                            .disabled(isImprovingException || isCreatingExceptionRules)
                            .help("Improve this exception with Sorty")
                            .accessibilityHint("Rewrites the exception to be clearer and more specific")
                            .alert("Sorty needs more detail", isPresented: $showImproveExceptionRequest) {
                                Button("Edit Exception") {
                                    isNLExceptionFocused = true
                                }
                            } message: {
                                Text(
                                    "\(improveExceptionRequestMessage)\n\nEdit the exception above, then click Improve again."
                                )
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }

                        Button {
                            Task { await createRulesFromNaturalLanguage() }
                        } label: {
                            if isCreatingExceptionRules {
                                SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                            } else {
                                Label("Create Rules", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.sortyPrimary(size: .small))
                        .onboardingBeamBorder(
                            variant: .featured,
                            active: hasNaturalLanguageExceptionText
                        )
                        .disabled(
                            !hasNaturalLanguageExceptionText
                                || isImprovingException
                                || isCreatingExceptionRules
                        )
                        .help("Turn this description into exclusion rules")
                        .alert("Couldn't Create Exclusion Rules", isPresented: $showCreateExceptionError) {
                            Button("Edit Description") {
                                isNLExceptionFocused = true
                            }
                        } message: {
                            Text(createExceptionErrorMessage)
                        }
                    }
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.82),
                            value: hasNaturalLanguageExceptionText
                        )
                    }
                }
            }
        }
        .task(id: NaturalLanguageSuggestionTaskID(isEmpty: newNLException.isEmpty, isVisible: isWindowVisible, controlActiveState: controlActiveState, scenePhase: scenePhase)) {
            guard newNLException.isEmpty, isWindowVisible, !reduceMotion,
                  controlActiveState != .inactive, scenePhase == .active else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, newNLException.isEmpty else { return }

                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    naturalLanguageSuggestionIndex =
                        (naturalLanguageSuggestionIndex + 1) % naturalLanguageExceptionSuggestions.count
                }
            }
        }
    }

    private func presentLearningExclusionImporter() {
        HapticFeedbackManager.shared.tap()
        showingLearningExclusionImporter = true
    }

    private func handleLearningExclusionImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                var addedCount = 0
                for url in urls {
                    let hasScopedAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }
                    let before =
                        learningsManager.currentProfile?.learningExclusionPatterns.count ?? 0
                    await learningsManager.addLearningExclusion(url.path)
                    if (learningsManager.currentProfile?.learningExclusionPatterns.count ?? 0)
                        > before
                    {
                        addedCount += 1
                    }
                }
                if addedCount > 0 {
                    HapticFeedbackManager.shared.success()
                } else {
                    HapticFeedbackManager.shared.error()
                }
            }
        case .failure(let error):
            DebugLogger.log("Learning exclusion import failed: \(error)")
            HapticFeedbackManager.shared.error()
        }
    }

    private func improveExceptionWithAI() async {
        let original = newNLException.trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty else { return }
        isImprovingException = true
        defer { isImprovingException = false }

        do {
            let client: any AIClientProtocol
            if let injected = injectedAIClient {
                client = injected
            } else {
                client = try AIClientFactory.createClient(config: settingsViewModel.config)
            }
            let outcome = try await ImproveInstructionsTool.run(
                client: client,
                originalInstructions: original,
                workflow: "exclusion rule"
            )

            switch outcome {
            case .replacement(let replacement):
                newNLException = String(replacement.prefix(200))
                showImproveExceptionRequest = false
                HapticFeedbackManager.shared.success()
            case .needsUserInput(let message):
                improveExceptionRequestMessage = message
                showImproveExceptionRequest = true
                HapticFeedbackManager.shared.tap()
            }
        } catch {
            HapticFeedbackManager.shared.error()
        }
    }

    private func createRulesFromNaturalLanguage() async {
        let exception = newNLException.trimmingCharacters(in: .whitespaces)
        guard !exception.isEmpty else { return }
        isCreatingExceptionRules = true
        resolvedExceptionRules = []
        revealedExceptionRuleCount = 0
        resolvedSupplementalDescription = nil
        streamedRuleDetails = [:]
        defer { isCreatingExceptionRules = false }

        do {
            let client: any AIClientProtocol
            if let injected = injectedAIClient {
                client = injected
            } else {
                client = try AIClientFactory.createClient(config: settingsViewModel.config)
            }
            let resolution = try await NaturalLanguageExclusionResolver.resolve(
                client: client,
                description: String(exception.prefix(200))
            )
            resolvedExceptionRules = resolution.rules
            resolvedSupplementalDescription = resolution.supplementalDescription
            for (index, rule) in resolution.rules.enumerated() {
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(180)) }
                withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)) {
                    revealedExceptionRuleCount = index + 1
                }
                HapticFeedbackManager.shared.selection()
                await streamRuleDetail(rule)
            }
            showCreateExceptionError = false
            HapticFeedbackManager.shared.success()
        } catch {
            createExceptionErrorMessage = error.localizedDescription
            showCreateExceptionError = true
            HapticFeedbackManager.shared.error()
        }
    }

    private func streamRuleDetail(_ rule: ExclusionRule) async {
        let detail = rule.interpretedMatchDescription
        guard !reduceMotion else {
            streamedRuleDetails[rule.id] = detail
            return
        }

        streamedRuleDetails[rule.id] = ""
        for character in detail {
            guard !Task.isCancelled else { return }
            streamedRuleDetails[rule.id, default: ""].append(character)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private var exceptionInterpretation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                transformingExceptionIcon

                ZStack(alignment: .leading) {
                    transformingExceptionCopy
                        .id(activeResolvedRule?.id.uuidString ?? "request")
                        .transition(.blurReplace.combined(with: .opacity))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isCreatingExceptionRules {
                    HStack(spacing: 6) {
                        SortyGradientCircularLoader(size: 12, lineWidth: 2)
                        Text("\(revealedExceptionRuleCount) / \(max(resolvedExceptionRules.count, 1))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .numericTextTransition(animationValue: revealedExceptionRuleCount)
                    }
                } else {
                    Button {
                        saveResolvedExceptionRules()
                    } label: {
                        Label(
                            "Save \(resolvedExceptionRules.count == 1 ? "Exclusion" : "Exclusions")",
                            systemImage: "checkmark.shield.fill"
                        )
                    }
                    .buttonStyle(.sortyPrimary(size: .small))
                }
            }

            if !resolvedExceptionRules.isEmpty && !isCreatingExceptionRules {
                HStack(spacing: 8) {
                    Button {
                        resetNaturalLanguageEditor()
                    } label: {
                        Label("Edit Description", systemImage: "pencil")
                    }
                    .systemLiquidGlassButton()

                    if resolvedExceptionRules.count > 1 {
                        Button {
                            isShowingResolvedRuleDetails.toggle()
                        } label: {
                            Label(
                                "\(resolvedExceptionRules.count) exclusions",
                                systemImage: "list.bullet"
                            )
                            .numericTextTransition(animationValue: resolvedExceptionRules.count)
                        }
                        .systemLiquidGlassButton()
                        .popover(isPresented: $isShowingResolvedRuleDetails, arrowEdge: .bottom) {
                            resolvedRuleDetailsPopover
                        }
                    }

                    Spacer()
                }
            }

            if let resolvedSupplementalDescription {
                LabeledContent("Supplementary instruction", value: resolvedSupplementalDescription)
                    .font(.caption2)
                    .padding(8)
                    .systemLiquidGlassBackground(
                        cornerRadius: 10,
                        clear: true,
                        interactive: false
                    )
            }

        }
        .padding(10)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .overlay {
            if isCreatingExceptionRules {
                FocusedInstructionBeamBorder(active: true)
                    .transition(.blurReplace.combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Exclusion rule interpretation")
        .accessibilityValue(interpretationProgressLabel)
        .animation(
            reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84),
            value: isCreatingExceptionRules
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86),
            value: revealedExceptionRuleCount
        )
    }

    private var activeResolvedRule: ExclusionRule? {
        guard revealedExceptionRuleCount > 0, !resolvedExceptionRules.isEmpty else { return nil }
        return resolvedExceptionRules[min(revealedExceptionRuleCount - 1, resolvedExceptionRules.count - 1)]
    }

    private var interpretationProgressLabel: String {
        guard isCreatingExceptionRules else {
            return "Ready to save \(resolvedExceptionRules.count) \(resolvedExceptionRules.count == 1 ? "exclusion" : "exclusions")"
        }
        guard !resolvedExceptionRules.isEmpty else { return "Reading request" }
        return "Created \(revealedExceptionRuleCount) of \(resolvedExceptionRules.count) exclusions"
    }

    private var transformingExceptionIcon: some View {
        let rule = activeResolvedRule
        let icon = rule?.aiToolIcon ?? "text.bubble.fill"
        let color = rule.map { toolColor(for: $0.type) } ?? .blue
        return Image(systemName: icon)
            .font(.body.bold())
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .systemLiquidGlassBackground(cornerRadius: 10, clear: true, interactive: false)
            .symbolEffect(
                .variableColor.iterative,
                isActive: isCreatingExceptionRules && !reduceMotion
            )
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    private var transformingExceptionCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let rule = activeResolvedRule {
                Text(sentenceCased(rule.displayDescription))
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(transformingDetail(for: rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.interpolate)
            } else {
                Text("Reading request")
                    .font(.subheadline.bold())
                Text(newNLException)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func transformingDetail(for rule: ExclusionRule) -> String {
        var details = [rule.aiToolDisplayName, streamedRuleDetails[rule.id] ?? ""]
        if rule.caseSensitive { details.append("Case-sensitive") }
        if rule.negated { details.append("Inverse match") }
        return details.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func sentenceCased(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private func resetNaturalLanguageEditor() {
        resolvedExceptionRules = []
        revealedExceptionRuleCount = 0
        resolvedSupplementalDescription = nil
        streamedRuleDetails = [:]
        isShowingResolvedRuleDetails = false
        isNLExceptionFocused = true
    }

    private var resolvedRuleDetailsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exclusions ready to save")
                .font(.headline)
            ForEach(resolvedExceptionRules) { rule in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sentenceCased(rule.displayDescription))
                            .font(.subheadline.bold())
                        Text(transformingDetail(for: rule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: rule.aiToolIcon)
                        .foregroundStyle(toolColor(for: rule.type))
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .systemLiquidGlassPopover(cornerRadius: 12)
    }

    private func toolColor(for type: ExclusionRuleType) -> Color {
        switch type {
        case .fileExtension, .fileName, .folderName, .pathContains, .regex: .blue
        case .fileSize, .creationDate, .modificationDate: .orange
        case .hiddenFiles, .systemFiles, .finderTag, .fileType: .purple
        case .customScript: .green
        }
    }

    private func saveResolvedExceptionRules() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82)) {
            resolvedExceptionRules.forEach(rulesManager.addRule)
            if let resolvedSupplementalDescription {
                rulesManager.addNaturalLanguageException(resolvedSupplementalDescription)
            }
            resolvedExceptionRules = []
            revealedExceptionRuleCount = 0
            resolvedSupplementalDescription = nil
            streamedRuleDetails = [:]
        }
        newNLException = ""
        if showingAddRule {
            showingAddRule = false
        }
        HapticFeedbackManager.shared.success()
    }
}

private struct NaturalLanguageSuggestionTaskID: Hashable {
    let isEmpty: Bool
    let isVisible: Bool
    let controlActiveState: ControlActiveState
    let scenePhase: ScenePhase
}

private struct ExclusionEditorTransitionModifier: ViewModifier {
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

private struct NaturalLanguageExceptionRow: View {
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

private struct ExclusionRuleUsageButton: View {
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

struct ExclusionRuleRow: View {
    @SortyHotReload private var hotReload
    let rule: ExclusionRule
    @ObservedObject var rulesManager: ExclusionRulesManager
    let isHighlighted: Bool
    let onEdit: () -> Void
    @State private var isHovered = false
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    private var usage: ExclusionRuleUsage? {
        rulesManager.usageByRuleID[rule.id]
    }

    private static let systemFolderIcon: NSImage = {
        NSWorkspace.shared.icon(forFile: "/tmp")
    }()

    private var isFolderExclusion: Bool {
        rule.type == .pathContains && rule.pattern.hasPrefix("/")
    }

    private var exclusionTitle: String {
        let value = rule.displayDescription
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    var body: some View {
        HStack(spacing: 12) {
            // Type icon - use system folder icon for folder rules
            ruleIcon
                .frame(width: 28, height: 28)
                .background((rule.isEnabled ? colorForType(rule.type) : .secondary).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(exclusionTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(rule.isEnabled ? .primary : .secondary)

                    if rule.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else if rule.isAIGenerated == true {
                        Text("AI-created")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                }

                HStack(spacing: 6) {
                    Text(isFolderExclusion ? "Folder" : rule.type.friendlyName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !isFolderExclusion,
                       let description = rule.description,
                       !description.isEmpty {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey(description))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

            }

            Spacer()

            if settingsViewModel.config.showStatsForNerds {
                ExclusionRuleUsageButton(usage: usage)
            }

            if isHovered {
                Button {
                    HapticFeedbackManager.shared.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        rulesManager.removeRule(rule)
                    }
                } label: {
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
                    get: { rule.isEnabled },
                    set: { newValue in
                        HapticFeedbackManager.shared.selection()
                        var updatedRule = rule
                        updatedRule.isEnabled = newValue
                        rulesManager.updateRule(updatedRule)
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(
                rule.isEnabled
                    ? "Disable rule: \(rule.displayDescription)"
                    : "Enable rule: \(rule.displayDescription)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            HapticFeedbackManager.shared.selection()
            onEdit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .sortyFocusHighlight(
            isActive: isHighlighted,
            shape: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityValue(isHighlighted ? "Newly added" : "")
        .contextMenu {
            Button {
                HapticFeedbackManager.shared.selection()
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button(role: .destructive) {
                HapticFeedbackManager.shared.tap()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    rulesManager.removeRule(rule)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text("Edit"), onEdit)
        .accessibilityAction(named: Text("Delete")) {
            HapticFeedbackManager.shared.tap()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                rulesManager.removeRule(rule)
            }
        }
    }

    @ViewBuilder
    private var ruleIcon: some View {
        if rule.type == .folderName || isFolderExclusion {
            AppKitImageView(
                image: Self.systemFolderIcon,
                size: CGSize(width: 16, height: 16),
                opacity: rule.isEnabled ? 1.0 : 0.5
            )
            .frame(width: 16, height: 16)
        } else if rule.type == .finderTag,
                  let labelNumber = Int(rule.pattern),
                  let tagColor = FinderTagColor(rawValue: labelNumber) {
            Image(systemName: "tag.fill")
                .font(.system(size: 14))
                .foregroundStyle(rule.isEnabled ? tagColor.color : .secondary)
        } else {
            Image(systemName: iconForType(rule.type))
                .font(.system(size: 14))
                .foregroundStyle(rule.isEnabled ? colorForType(rule.type) : .secondary)
        }
    }

    private func iconForType(_ type: ExclusionRuleType) -> String {
        switch type {
        case .fileExtension: return "doc.badge.gearshape"
        case .fileName: return "doc"
        case .folderName: return "folder"
        case .pathContains: return "arrow.triangle.branch"
        case .regex: return "text.magnifyingglass"
        case .fileSize: return "scalemass"
        case .creationDate: return "calendar.badge.plus"
        case .modificationDate: return "calendar.badge.clock"
        case .hiddenFiles: return "eye.slash"
        case .systemFiles: return "gearshape.2"
        case .finderTag: return "tag"
        case .fileType: return "doc.on.doc"
        case .customScript: return "applescript"
        }
    }

    private func colorForType(_ type: ExclusionRuleType) -> Color {
        switch type {
        case .fileExtension, .fileName, .folderName, .pathContains, .regex:
            return .blue
        case .fileSize, .creationDate, .modificationDate:
            return .orange
        case .hiddenFiles, .systemFiles, .finderTag, .fileType:
            return .purple
        case .customScript:
            return .green
        }
    }
}

// MARK: - Add Exclusion Rule View

private enum ExclusionIntent: String, CaseIterable, Identifiable {
    case folder
    case finderTag
    case fileKind
    case name
    case properties
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .folder: "A specific folder"
        case .finderTag: "A Finder tag"
        case .fileKind: "A kind of file"
        case .name: "Files or folders by name"
        case .properties: "Files by size or age"
        case .advanced: "Advanced rule"
        }
    }

    var explanation: String {
        switch self {
        case .folder: "Exclude one folder and everything inside it from organizations and renames."
        case .finderTag: "Exclude files and folders with a selected Finder tag."
        case .fileKind: "Exclude a familiar category, or one specific file extension."
        case .name: "Match text in a file name or an exact folder name."
        case .properties: "Exclude files above or below a size, or based on their age."
        case .advanced: "Hidden files, macOS files, path fragments, and regular expressions."
        }
    }

    var icon: String {
        switch self {
        case .folder: "folder.badge.minus"
        case .finderTag: "tag"
        case .fileKind: "doc.on.doc"
        case .name: "text.magnifyingglass"
        case .properties: "slider.horizontal.3"
        case .advanced: "gearshape.2"
        }
    }
}

private extension FinderTagColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}

private enum FileKindChoice: String, CaseIterable, Identifiable {
    case category = "File category"
    case fileExtension = "File extension"

    var id: Self { self }
}

private enum NameMatchChoice: String, CaseIterable, Identifiable {
    case fileName = "File name contains"
    case folderName = "Folder name is"

    var id: Self { self }
}

private enum PropertyChoice: String, CaseIterable, Identifiable {
    case fileSize = "File size"
    case modificationDate = "Last modified"
    case creationDate = "Date created"

    var id: Self { self }
}

private enum AdvancedRuleChoice: String, CaseIterable, Identifiable {
    case hiddenFiles = "Hidden files"
    case systemFiles = "macOS system files"
    case pathContains = "Any path containing text"
    case regex = "Regular expression"

    var id: Self { self }
}

struct AddExclusionRuleView: View {
    @SortyHotReload private var hotReload
    @ObservedObject var rulesManager: ExclusionRulesManager
    @Environment(\.dismiss) var dismiss
    private let editingRule: ExclusionRule?
    private let relatedRules: [ExclusionRule]
    private let isEmbedded: Bool
    @State private var selectedIntent: ExclusionIntent?
    @State private var fileKindChoice: FileKindChoice = .category
    @State private var nameMatchChoice: NameMatchChoice = .fileName
    @State private var propertyChoice: PropertyChoice = .fileSize
    @State private var advancedChoice: AdvancedRuleChoice = .hiddenFiles
    @State private var selectedFinderTag: FinderTagColor = .red
    @State private var pattern: String = ""
    @State private var description: String = ""
    @State private var numericValue: Double = 100
    @State private var comparisonGreater: Bool = true
    @State private var sizeUnit: ExclusionSizeUnit = .megabytes
    @State private var dateAgeUnit: ExclusionAgeUnit = .days
    @State private var selectedFileTypeCategory: FileTypeCategory = .images
    @State private var selectedFolderURL: URL?
    @State private var showingFolderPicker = false
    @State private var caseSensitive = false
    @State private var negated = false
    @State private var activeConditionID: UUID?

    init(
        rulesManager: ExclusionRulesManager,
        editing rule: ExclusionRule? = nil,
        relatedRules: [ExclusionRule] = [],
        isEmbedded: Bool = false
    ) {
        self.rulesManager = rulesManager
        editingRule = rule
        self.relatedRules = relatedRules.isEmpty ? rule.map { [$0] } ?? [] : relatedRules
        self.isEmbedded = isEmbedded
        _activeConditionID = State(initialValue: rule?.id)

        guard let rule else { return }
        let intent = Self.intent(for: rule)

        _selectedIntent = State(initialValue: intent)
        _fileKindChoice = State(initialValue: rule.type == .fileExtension ? .fileExtension : .category)
        _nameMatchChoice = State(initialValue: rule.type == .folderName ? .folderName : .fileName)
        _propertyChoice = State(initialValue: rule.type == .creationDate ? .creationDate : rule.type == .modificationDate ? .modificationDate : .fileSize)
        _advancedChoice = State(initialValue: rule.type == .systemFiles ? .systemFiles : rule.type == .pathContains ? .pathContains : rule.type == .regex ? .regex : .hiddenFiles)
        _selectedFinderTag = State(initialValue: Int(rule.pattern).flatMap(FinderTagColor.init(rawValue:)) ?? .red)
        _pattern = State(initialValue: rule.pattern)
        _description = State(initialValue: rule.description ?? "")
        _sizeUnit = State(initialValue: rule.sizeUnit ?? .megabytes)
        _dateAgeUnit = State(initialValue: rule.ageUnit ?? .days)
        let displayedValue: Double
        if rule.type == .fileSize {
            displayedValue = (rule.numericValue ?? 0) / (rule.sizeUnit ?? .megabytes).megabyteMultiplier
        } else if rule.type == .creationDate || rule.type == .modificationDate {
            displayedValue = (rule.ageIntervalSeconds ?? 0) / (rule.ageUnit ?? .days).secondsMultiplier
        } else {
            displayedValue = rule.numericValue ?? 100
        }
        _numericValue = State(initialValue: displayedValue)
        _selectedFileTypeCategory = State(initialValue: rule.fileTypeCategory ?? .images)
        _selectedFolderURL = State(initialValue: intent == .folder ? URL(fileURLWithPath: rule.pattern) : nil)
        _caseSensitive = State(initialValue: rule.caseSensitive)
        _negated = State(initialValue: rule.negated)
    }

    var body: some View {
        Group {
            if isEmbedded {
                editorContent
            } else {
                VStack(spacing: 0) {
                    header

                    Divider()

                    ScrollView {
                        editorContent
                            .padding(20)
                    }
                }
                .frame(width: 620, height: 620)
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                return
            }
            HapticFeedbackManager.shared.selection()
            selectedFolderURL = url.standardizedFileURL
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isEmbedded, selectedIntent != nil {
                manualEditorControls
            }
            if relatedRules.count > 1 {
                linkedConditionsView
            }
            if let selectedIntent {
                configurationView(for: selectedIntent)
            } else {
                intentPicker
            }
        }
    }

    private var manualEditorControls: some View {
        HStack {
            Button {
                HapticFeedbackManager.shared.selection()
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedIntent = nil
                    selectedFolderURL = nil
                }
            } label: {
                Label("Back", systemImage: "chevron.left")
            }

            Spacer()

            Button("Add Exclusion") {
                HapticFeedbackManager.shared.success()
                addRule()
            }
            .buttonStyle(.sortyPrimary(size: .small))
            .disabled(!isValidInput)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private var header: some View {
        HStack {
            if selectedIntent == nil {
                Button("Cancel") {
                    HapticFeedbackManager.shared.tap()
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button {
                    HapticFeedbackManager.shared.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedIntent = nil
                        selectedFolderURL = nil
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            Spacer()

            Text(editingRule == nil ? (selectedIntent == nil ? "Add an Exclusion" : "Set Up Exclusion") : "Edit Exclusion")
                .font(.headline)

            Spacer()

            if selectedIntent != nil {
                Button(editingRule == nil ? "Add Exclusion" : "Save Changes") {
                    HapticFeedbackManager.shared.success()
                    addRule()
                }
                .buttonStyle(.sortyPrimary)
                .onboardingBeamBorder(variant: .warning, active: isValidInput)
                .disabled(!isValidInput)
                .keyboardShortcut(.return, modifiers: [.command])
            } else {
                Button("Cancel") {}
                    .hidden()
            }
        }
        .padding()
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
    }

    private var intentPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What should Sorty exclude?")
                    .font(.title3.weight(.semibold))

                Text("Choose the closest match. You’ll only see the settings that apply.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            ForEach(ExclusionIntent.allCases) { intent in
                Button {
                    HapticFeedbackManager.shared.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let relatedRule = relatedRules.first(where: {
                            Self.intent(for: $0) == intent
                        }) {
                            loadCondition(relatedRule)
                        }
                        selectedIntent = intent
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: intent.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                            .frame(width: 34, height: 34)
                            .background(SortyDesignSystem.Colors.resolvedAccent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(intent.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(intent.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .systemLiquidGlassBackground(cornerRadius: 12)
            }
        }
    }

    private var linkedConditionsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(displayedExceptionName)
                .font(.headline)
            Text("Sorty excludes an item only when every condition below matches.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(relatedRules) { condition in
                Button {
                    HapticFeedbackManager.shared.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        loadCondition(condition)
                        selectedIntent = Self.intent(for: condition)
                    }
                } label: {
                    HStack {
                        Image(systemName: condition.aiToolIcon)
                            .foregroundStyle(
                                condition.id == activeConditionID
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            .accessibilityHidden(true)
                        Text(condition.interpretedMatchDescription)
                            .foregroundStyle(.primary)
                        Spacer()
                        if condition.id == activeConditionID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    condition.id == activeConditionID
                        ? Color.accentColor.opacity(0.10)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .padding(14)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
    }

    private var displayedExceptionName: String {
        let name = relatedRules.compactMap(\.description).first
            ?? editingRule?.displayDescription
            ?? "Edit exclusion"
        guard let first = name.first else { return "Edit exclusion" }
        return first.uppercased() + name.dropFirst()
    }

    @ViewBuilder
    private func configurationView(for intent: ExclusionIntent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(intent.title, systemImage: intent.icon)
                    .font(.title3.weight(.semibold))
                Text(intent.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                switch intent {
                case .folder:
                    folderConfiguration
                case .finderTag:
                    finderTagConfiguration
                case .fileKind:
                    fileKindConfiguration
                case .name:
                    nameConfiguration
                case .properties:
                    propertyConfiguration
                case .advanced:
                    advancedConfiguration
                }
            }
            .padding(16)
            .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)

            if intent != .folder {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Label (optional)")
                        .font(.subheadline.weight(.semibold))
                    TextField("e.g. Old video exports", text: $description)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(16)
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            }

            if supportsMatchingOptions {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Matching options")
                        .font(.subheadline.weight(.semibold))
                    Toggle("Match uppercase and lowercase separately", isOn: $caseSensitive)
                    Toggle("Exclude everything except matches", isOn: $negated)
                }
                .padding(16)
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            }
        }
    }

    private var supportsMatchingOptions: Bool {
        switch selectedRuleType {
        case .fileExtension, .fileName, .folderName, .pathContains, .regex:
            true
        default:
            false
        }
    }

    private static func intent(for rule: ExclusionRule) -> ExclusionIntent {
        switch rule.type {
        case .pathContains where rule.pattern.hasPrefix("/"):
            .folder
        case .finderTag:
            .finderTag
        case .fileType, .fileExtension:
            .fileKind
        case .fileName, .folderName:
            .name
        case .fileSize, .creationDate, .modificationDate:
            .properties
        case .hiddenFiles, .systemFiles, .pathContains, .regex, .customScript:
            .advanced
        }
    }

    private func loadCondition(_ rule: ExclusionRule) {
        activeConditionID = rule.id
        fileKindChoice = rule.type == .fileExtension ? .fileExtension : .category
        nameMatchChoice = rule.type == .folderName ? .folderName : .fileName
        propertyChoice = rule.type == .creationDate
            ? .creationDate
            : rule.type == .modificationDate ? .modificationDate : .fileSize
        advancedChoice = rule.type == .systemFiles
            ? .systemFiles
            : rule.type == .pathContains ? .pathContains : rule.type == .regex ? .regex : .hiddenFiles
        selectedFinderTag = Int(rule.pattern).flatMap(FinderTagColor.init(rawValue:)) ?? .red
        pattern = rule.pattern
        description = rule.description ?? ""
        sizeUnit = rule.sizeUnit ?? .megabytes
        dateAgeUnit = rule.ageUnit ?? .days
        if rule.type == .fileSize {
            numericValue = (rule.numericValue ?? 0) / sizeUnit.megabyteMultiplier
        } else if rule.type == .creationDate || rule.type == .modificationDate {
            numericValue = (rule.ageIntervalSeconds ?? 0) / dateAgeUnit.secondsMultiplier
        } else {
            numericValue = rule.numericValue ?? 100
        }
        selectedFileTypeCategory = rule.fileTypeCategory ?? .images
        selectedFolderURL = Self.intent(for: rule) == .folder
            ? URL(fileURLWithPath: rule.pattern)
            : nil
        caseSensitive = rule.caseSensitive
        negated = rule.negated
    }

    private var folderConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedFolderURL {
                HStack(spacing: 14) {
                    FolderThumbnailView(
                        url: selectedFolderURL,
                        size: CGSize(width: 36, height: 36)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedFolderURL.lastPathComponent)
                            .font(.subheadline.weight(.medium))
                        PrivacySensitivePathText(
                            path: selectedFolderURL.deletingLastPathComponent().path
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer()

                    Button("Change") {
                        showingFolderPicker = true
                    }
                    .buttonStyle(.sortyBordered(size: .small))
                }
            } else {
                HStack(spacing: 16) {
                    Image(systemName: "folder.badge.minus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                        .frame(width: 44, height: 44)
                        .background(SortyDesignSystem.Colors.resolvedAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Choose the folder to exclude")
                            .font(.subheadline.weight(.semibold))
                        Text("The folder and everything inside it will be excluded from organizations and renames.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Button {
                        HapticFeedbackManager.shared.tap()
                        showingFolderPicker = true
                    } label: {
                        Label("Choose Folder", systemImage: "folder.badge.minus")
                    }
                    .buttonStyle(.sortyPrimary)
                    .accessibilityIdentifier("ChooseExclusionFolderButton")
                }
            }
        }
    }

    private var fileKindConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Match", selection: $fileKindChoice) {
                ForEach(FileKindChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if fileKindChoice == .category {
                Picker("Category", selection: $selectedFileTypeCategory) {
                    ForEach(FileTypeCategory.allCases) { category in
                        Label(category.rawValue, systemImage: category.icon).tag(category)
                    }
                }
                .pickerStyle(.menu)

                Text(categorySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                labeledPatternField(
                    title: "Extension",
                    placeholder: "pdf",
                    help: "Enter it with or without the dot."
                )
            }
        }
    }

    private var finderTagConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Finder tag", selection: $selectedFinderTag) {
                ForEach(FinderTagColor.allCases) { tag in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(tag.name)
                    }
                    .tag(tag)
                }
            }
            .pickerStyle(.menu)

            Text("Tag a file or folder in Finder. Sorty will leave it alone. A tagged folder protects everything inside it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var nameConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Match", selection: $nameMatchChoice) {
                ForEach(NameMatchChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            labeledPatternField(
                title: nameMatchChoice == .fileName ? "Text in the file name" : "Folder name",
                placeholder: nameMatchChoice == .fileName ? "draft" : "node_modules",
                help: nameMatchChoice == .fileName
                    ? "Any matching file will be excluded from organizations and renames."
                    : "Every matching folder and its contents will be excluded from organizations and renames."
            )
        }
    }

    private var propertyConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Property", selection: $propertyChoice) {
                ForEach(PropertyChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if propertyChoice == .fileSize {
                HStack(spacing: 10) {
                    Picker("Exclude files", selection: $comparisonGreater) {
                        Text("Exclude files larger than").tag(true)
                        Text("Exclude files smaller than").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()

                    TextField("100", value: $numericValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    Picker("Size unit", selection: $sizeUnit) {
                        ForEach(ExclusionSizeUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 82)

                    Spacer()
                }
            } else {
                HStack(spacing: 10) {
                    Picker("Exclude files", selection: $comparisonGreater) {
                        Text("Exclude files older than").tag(true)
                        Text("Exclude files newer than").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()

                    TextField("30", value: $numericValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    Picker("Time unit", selection: $dateAgeUnit) {
                        ForEach(ExclusionAgeUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Spacer()
                }
            }
        }
    }

    private var advancedConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Rule", selection: $advancedChoice) {
                ForEach(AdvancedRuleChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.menu)

            switch advancedChoice {
            case .hiddenFiles:
                explanationRow("Files and folders whose names begin with a period will be excluded from organizations and renames.")
            case .systemFiles:
                explanationRow("Common macOS metadata and system-generated files will be excluded from organizations and renames.")
            case .pathContains:
                labeledPatternField(
                    title: "Text in the path",
                    placeholder: "/backups/",
                    help: "Matches this text anywhere in the full path."
                )
            case .regex:
                labeledPatternField(
                    title: "Regular expression",
                    placeholder: "^temp_.*\\.log$",
                    help: "Matches against the file or folder name."
                )
            }
        }
    }

    private func labeledPatternField(title: String, placeholder: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            TextField(placeholder, text: $pattern)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ExclusionRulePatternField")
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func explanationRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var categorySummary: String {
        let examples = selectedFileTypeCategory.extensions.prefix(6).map { ".\($0)" }
        guard !examples.isEmpty else {
            return "Files not covered by the standard categories."
        }
        return "Includes \(examples.joined(separator: ", "))\(selectedFileTypeCategory.extensions.count > 6 ? ", and more." : ".")"
    }

    private var selectedRuleType: ExclusionRuleType? {
        switch selectedIntent {
        case .folder: .pathContains
        case .finderTag: .finderTag
        case .fileKind: fileKindChoice == .category ? .fileType : .fileExtension
        case .name: nameMatchChoice == .fileName ? .fileName : .folderName
        case .properties:
            switch propertyChoice {
            case .fileSize: .fileSize
            case .modificationDate: .modificationDate
            case .creationDate: .creationDate
            }
        case .advanced:
            switch advancedChoice {
            case .hiddenFiles: .hiddenFiles
            case .systemFiles: .systemFiles
            case .pathContains: .pathContains
            case .regex: .regex
            }
        case nil: nil
        }
    }

    private var isValidInput: Bool {
        guard let selectedIntent, let selectedRuleType else { return false }

        if selectedIntent == .folder {
            return selectedFolderURL != nil
        }

        switch selectedRuleType {
        case .hiddenFiles, .systemFiles, .finderTag, .fileType:
            return true
        case .fileSize, .creationDate, .modificationDate:
            return numericValue > 0
        case .customScript:
            return false
        default:
            return !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func addRule() {
        guard let selectedIntent, let selectedRuleType else { return }

        if selectedIntent == .folder, let selectedFolderURL {
            let normalizedPath = selectedFolderURL.standardizedFileURL.path
            let folderName = selectedFolderURL.lastPathComponent
            save(
                ExclusionRule(
                    type: .pathContains,
                    pattern: normalizedPath,
                    description: folderName.isEmpty ? "Protected folder" : folderName,
                    caseSensitive: caseSensitive,
                    negated: negated
                )
            )
            return
        }

        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule: ExclusionRule

        switch selectedRuleType {
        case .finderTag:
            rule = ExclusionRule(
                type: .finderTag,
                pattern: String(selectedFinderTag.rawValue),
                description: description.isEmpty
                    ? "\(selectedFinderTag.name) Finder tag"
                    : description
            )
        case .fileSize, .creationDate, .modificationDate:
            rule = ExclusionRule(
                type: selectedRuleType,
                description: description.isEmpty ? nil : description,
                numericValue: selectedRuleType == .fileSize
                    ? numericValue * sizeUnit.megabyteMultiplier
                    : numericValue * dateAgeUnit.secondsMultiplier / ExclusionAgeUnit.days.secondsMultiplier,
                comparisonGreater: comparisonGreater,
                sizeUnit: selectedRuleType == .fileSize ? sizeUnit : nil,
                ageUnit: selectedRuleType == .fileSize ? nil : dateAgeUnit,
                ageIntervalSeconds: selectedRuleType == .fileSize
                    ? nil
                    : numericValue * dateAgeUnit.secondsMultiplier,
                caseSensitive: caseSensitive,
                negated: negated
            )
        case .fileType:
            rule = ExclusionRule(
                type: .fileType,
                description: description.isEmpty ? nil : description,
                fileTypeCategory: selectedFileTypeCategory,
                caseSensitive: caseSensitive,
                negated: negated
            )
        default:
            rule = ExclusionRule(
                type: selectedRuleType,
                pattern: trimmedPattern,
                description: description.isEmpty ? nil : description,
                caseSensitive: caseSensitive,
                negated: negated
            )
        }

        save(rule)
    }

    private func save(_ rule: ExclusionRule) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if let editingRule,
               let conditionToUpdate = relatedRules.first(where: { $0.id == activeConditionID })
                    ?? (relatedRules.count == 1 ? editingRule : nil) {
                let updatedRule = ExclusionRule(
                    id: conditionToUpdate.id,
                    type: rule.type,
                    pattern: rule.pattern,
                    isEnabled: conditionToUpdate.isEnabled,
                    description: rule.description,
                    isBuiltIn: conditionToUpdate.isBuiltIn,
                    isAIGenerated: conditionToUpdate.isAIGenerated ?? false,
                    conditionGroupID: conditionToUpdate.conditionGroupID,
                    numericValue: rule.numericValue,
                    comparisonGreater: rule.comparisonGreater,
                    sizeUnit: rule.sizeUnit,
                    ageUnit: rule.ageUnit,
                    ageIntervalSeconds: rule.ageIntervalSeconds,
                    fileTypeCategory: rule.fileTypeCategory,
                    caseSensitive: rule.caseSensitive,
                    negated: rule.negated
                )
                rulesManager.updateRule(updatedRule)
            } else {
                rulesManager.addRule(rule)
            }
        }
        dismiss()
    }
}

// FlowLayout is now defined globally in AnalysisView.swift

#Preview {
    ExclusionRulesView()
        .environmentObject(ExclusionRulesManager())
        .frame(width: 600, height: 550)
}
