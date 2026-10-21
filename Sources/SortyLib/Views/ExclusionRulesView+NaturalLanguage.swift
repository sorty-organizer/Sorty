import SwiftUI
import UniformTypeIdentifiers

// MARK: - NaturalLanguage
extension ExclusionRulesView {
    // MARK: - Natural Language Exceptions

    var learningExclusionsCard: some View {
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

    var naturalLanguageExceptionsCard: some View {
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

    func presentLearningExclusionImporter() {
        HapticFeedbackManager.shared.tap()
        showingLearningExclusionImporter = true
    }

    func handleLearningExclusionImport(_ result: Result<[URL], Error>) {
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

    func improveExceptionWithAI() async {
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

    func createRulesFromNaturalLanguage() async {
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

    func streamRuleDetail(_ rule: ExclusionRule) async {
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

    var exceptionInterpretation: some View {
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

    var activeResolvedRule: ExclusionRule? {
        guard revealedExceptionRuleCount > 0, !resolvedExceptionRules.isEmpty else { return nil }
        return resolvedExceptionRules[min(revealedExceptionRuleCount - 1, resolvedExceptionRules.count - 1)]
    }

    var interpretationProgressLabel: String {
        guard isCreatingExceptionRules else {
            return "Ready to save \(resolvedExceptionRules.count) \(resolvedExceptionRules.count == 1 ? "exclusion" : "exclusions")"
        }
        guard !resolvedExceptionRules.isEmpty else { return "Reading request" }
        return "Created \(revealedExceptionRuleCount) of \(resolvedExceptionRules.count) exclusions"
    }

    var transformingExceptionIcon: some View {
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

    var transformingExceptionCopy: some View {
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

    func transformingDetail(for rule: ExclusionRule) -> String {
        var details = [rule.aiToolDisplayName, streamedRuleDetails[rule.id] ?? ""]
        if rule.caseSensitive { details.append("Case-sensitive") }
        if rule.negated { details.append("Inverse match") }
        return details.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func sentenceCased(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    func resetNaturalLanguageEditor() {
        resolvedExceptionRules = []
        revealedExceptionRuleCount = 0
        resolvedSupplementalDescription = nil
        streamedRuleDetails = [:]
        isShowingResolvedRuleDetails = false
        isNLExceptionFocused = true
    }

    var resolvedRuleDetailsPopover: some View {
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

    func toolColor(for type: ExclusionRuleType) -> Color {
        switch type {
        case .fileExtension, .fileName, .folderName, .pathContains, .regex: .blue
        case .fileSize, .creationDate, .modificationDate: .orange
        case .hiddenFiles, .systemFiles, .finderTag, .fileType: .purple
        case .customScript: .green
        }
    }

    func saveResolvedExceptionRules() {
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
