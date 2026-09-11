//
//  LearningsView.swift
//  Sorty
//
//  Passive Learning Dashboard — single scrollable page
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main View

struct LearningsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var manager: LearningsManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var exclusionRules: ExclusionRulesManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showingDeleteConfirmation = false
    @State private var showingWithdrawConfirmation = false
    @State private var activeFileImporter: ActiveFileImporter?
    @State private var isShowingFileImporter = false
    @State private var showLearningsModelPicker = false
    @State private var emptyLearningsHasAppeared = false
    @State private var emptyExampleFoldersHasAppeared = false
    @State private var pendingControlAction: PendingControlAction?
    @State private var selectedLearningRecordsCategory: LearningRecordsCategory?
    @AppStorage("learnings.activePatternsExpanded") private var isActivePatternsExpanded = true

    private enum PendingControlAction: Equatable {
        case withdrawConsent
        case deleteData

        var title: String {
            switch self {
            case .withdrawConsent: return "Pausing Learning"
            case .deleteData: return "Deleting Learnings Data"
            }
        }

        var message: String {
            switch self {
            case .withdrawConsent: return "Stopping future learning and saving the change..."
            case .deleteData: return "Removing your learnings profile, consent, model overrides, and local learning settings..."
            }
        }

        var icon: String {
            switch self {
            case .withdrawConsent: return "pause.circle.fill"
            case .deleteData: return "trash.circle.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .withdrawConsent: return .orange
            case .deleteData: return .red
            }
        }
    }

    private enum ActiveFileImporter: Int, Identifiable {
        case modelDirectories
        case learningsProfile

        var id: Int { rawValue }

        var allowedContentTypes: [UTType] {
            switch self {
            case .modelDirectories: return [.folder]
            case .learningsProfile:
                return [UTType(filenameExtension: "learnings", conformingTo: .json) ?? .json]
            }
        }

        var allowsMultipleSelection: Bool {
            switch self {
            case .modelDirectories: return true
            case .learningsProfile: return false
            }
        }
    }

    private enum LearningRecordsCategory: String, Identifiable {
        case patterns
        case sessions
        case feedback
        case instructions
        case supportingData

        var id: String { rawValue }

        var title: String {
            switch self {
            case .patterns: return "Patterns"
            case .sessions: return "Sessions"
            case .feedback: return "Feedback"
            case .instructions: return "Instructions"
            case .supportingData: return "Supporting Data"
            }
        }

        func title(for count: Int) -> String {
            switch self {
            case .patterns: return count == 1 ? "Pattern" : "Patterns"
            case .sessions: return count == 1 ? "Session" : "Sessions"
            case .feedback: return "Feedback"
            case .instructions: return count == 1 ? "Instruction" : "Instructions"
            case .supportingData: return "Supporting Data"
            }
        }

        var systemImage: String {
            switch self {
            case .patterns: return "sparkles"
            case .sessions: return "clock.arrow.circlepath"
            case .feedback: return "arrow.triangle.2.circlepath"
            case .instructions: return "text.bubble"
            case .supportingData: return "archivebox"
            }
        }

        var color: Color {
            switch self {
            case .patterns: return .purple
            case .sessions: return .blue
            case .feedback: return .orange
            case .instructions: return .teal
            case .supportingData: return .secondary
            }
        }
    }

    private struct LearningDataMetric: Identifiable {
        let category: LearningRecordsCategory
        let count: Int

        var id: String { category.id }
    }

    private struct LearningRecordField: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    var body: some View {
        ZStack {
            if !manager.consentManager.hasConsented {
                onboardingView
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                dashboardView
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
            }
        }
        .animation(.easeInOut(duration: 0.36), value: manager.consentManager.hasConsented)
        .frame(minWidth: 700, minHeight: 600)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Learnings Dashboard")
        .task {
            // No-op after the app's normal post-launch load; covers harness
            // mode and any path that shows Learnings before globals configure.
            await manager.loadPersistedState()
        }
        .onAppear {
            manager.isLocked = false
            manager.loadProfileIfNeededForCollection()
            if settingsViewModel.availableModels.isEmpty {
                settingsViewModel.updateAvailableModels()
            }
        }
        .navigationTitle("Learnings")
    }

    // MARK: - Onboarding

    private var onboardingView: some View {
        WorkflowContainer(currentStep: .configure) {
            Spacer()

            EmptyStateHeroIcon(systemName: "brain.head.profile")
                .animatedAppearance(delay: 0.03)

            VStack(spacing: 8) {
                Text("The Learnings")
                    .font(.largeTitle.bold())
                Text(
                    "A passive learning system that watches how you organize files and learns your preferences over time."
                )
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            }
            .animatedAppearance(delay: 0.07)

            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    icon: "eye.fill", title: "Watches",
                    description: "Observes when you modify directories after Sorty organization")
                featureRow(
                    icon: "arrow.uturn.backward.circle.fill", title: "Learns from Reverts",
                    description: "Understands when Sorty suggestions weren't right")
                featureRow(
                    icon: "text.bubble.fill", title: "Remembers Instructions",
                    description: "Captures your additional guidance and preferences")
                featureRow(
                    icon: "sparkles", title: "Improves Over Time",
                    description: "Uses learnings to make better future suggestions")
            }
            .padding(16)
            .systemLiquidGlassBackground(cornerRadius: 16, interactive: false)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Learnings features")
            .animatedAppearance(delay: 0.11)

            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.green)
                Text("Encrypted locally • On-device only • Delete anytime")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.1))
            .cornerRadius(20)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Privacy: Data is encrypted locally with biometric protection. You can delete anytime."
            )
            .animatedAppearance(delay: 0.15)

            Button(action: {
                Task {
                    HapticFeedbackManager.shared.light()
                    await manager.grantConsent()
                    manager.completeInitialSetup()
                    HapticFeedbackManager.shared.success()
                }
            }) {
                Label("Enable Learning", systemImage: "checkmark.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.sortyPrimary)
            .onboardingBeamBorder(variant: .featured)
            .keyboardShortcut(.return)
            .onHover { hovering in
                if hovering {
                    HapticFeedbackManager.shared.selection()
                }
            }
            .accessibilityLabel("Enable Learning")
            .accessibilityHint("Start learning from your organization habits")
            .animatedAppearance(delay: 0.19)

            Spacer()
        }
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: icon)
                .font(.title2.bold())
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 40)
                .systemLiquidGlassBackground(cornerRadius: 10, interactive: false)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title)).font(.headline)
                Text(LocalizedStringKey(description)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(description)")
    }

    // MARK: - Dashboard

    private var dashboardView: some View {
        VStack(spacing: 0) {
            dashboardHeader
                .animatedAppearance(delay: 0.03)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    whatSortyHasLearnedSection
                        .animatedAppearance(delay: 0.08)

                    referenceDirectoriesSection
                        .animatedAppearance(delay: 0.12)

                    settingsSection
                        .animatedAppearance(delay: 0.16)
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        }
        .modelSelectionOverlay(
            isPresented: $showLearningsModelPicker,
            currentProvider: usesDedicatedLearningsModel
                ? (manager.learningsModelSelection?.provider ?? settingsViewModel.config.provider)
                : settingsViewModel.config.provider,
            currentModel: usesDedicatedLearningsModel
                ? effectiveLearningsModel
                : settingsViewModel.config.model,
            contextMessage: usesDedicatedLearningsModel
                ? "Organization uses \(organizationModelDisplay)."
                : "Learnings uses the organization model (\(organizationModelDisplay)). Picking a different model creates a dedicated override for learnings analysis.",
            resetActionTitle: usesDedicatedLearningsModel ? "Use Organization Model" : nil,
            onReset: {
                manager.clearLearningsModelOverride()
            },
            onSelect: { provider, model, authMethod in
                if let authMethod {
                    settingsViewModel.config.setAuthMethod(authMethod, for: provider)
                }
                HapticFeedbackManager.shared.selection()
                if provider == settingsViewModel.config.provider
                    && model == settingsViewModel.config.model
                {
                    manager.clearLearningsModelOverride()
                } else {
                    manager.setLearningsModelOverride(provider: provider, model: model)
                }
            },
            isSubscriptionSelected: settingsViewModel.config.authMethod(for: usesDedicatedLearningsModel ? (manager.learningsModelSelection?.provider ?? settingsViewModel.config.provider) : settingsViewModel.config.provider) == .accountSignIn
        )
        .sheet(item: $selectedLearningRecordsCategory) { category in
            if let profile = manager.currentProfile {
                learningRecordsDetailSheet(category: category, profile: profile)
            }
        }
        .alert("Delete All Learning Data?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                cancelPendingControlAction()
            }
            Button("Delete", role: .destructive) {
                deleteAllLearningData()
            }
        } message: {
            if pendingControlAction == .deleteData {
                Text("Deleting learning data...")
            } else {
                Text(
                    "This will permanently delete all your learning data and preferences. This cannot be undone."
                )
            }
        }
        .alert("Pause Learning?", isPresented: $showingWithdrawConfirmation) {
            Button("Cancel", role: .cancel) {
                cancelPendingControlAction()
            }
            Button("Pause Learning", role: .destructive) {
                withdrawConsent()
            }
        } message: {
            Text(
                "Sorty will stop learning from your organization activity. Your existing learning data and preferences will stay saved, and you can turn learning back on at any time."
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .pauseLearning)) { notification in
            guard notification.targetsWindowSession(appState.windowSessionID) else { return }
            confirmWithdrawConsent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportLearningsProfile)) {
            notification in
            guard notification.targetsWindowSession(appState.windowSessionID) else { return }
            requestSensitiveAction(
                reason: "Authenticate to export your learnings profile."
            ) {
                exportProfile()
            }
        }
        .onChange(of: manager.showingImportPicker) { showing in
            guard showing else { return }
            manager.showingImportPicker = false
            activeFileImporter = .learningsProfile
            isShowingFileImporter = true
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: activeFileImporter?.allowedContentTypes ?? [.data],
            allowsMultipleSelection: activeFileImporter?.allowsMultipleSelection ?? false
        ) { result in
            guard let importer = activeFileImporter else { return }
            activeFileImporter = nil
            isShowingFileImporter = false
            switch importer {
            case .modelDirectories: handleModelDirectoryImport(result)
            case .learningsProfile: handleProfileImport(result)
            }
        }
    }

    // MARK: - Dashboard Header

    private var dashboardHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                if appState.navigatedFromSettings {
                    GlassyBackButton {
                        HapticFeedbackManager.shared.tap()
                        appState.navigatedFromSettings = false
                        appState.openSettingsWindow(section: .help)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "brain.head.profile")
                            .font(.title2)
                            .foregroundStyle(.blue.gradient)
                        Text("The Learnings")
                            .font(.title2.bold())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("The Learnings")

                    Text("Passively learning from your organization habits")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    confirmWithdrawConsent()
                } label: {
                    if pendingControlAction == .withdrawConsent {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Pause Learning", systemImage: "pause.fill")
                            .font(.caption.bold())
                    }
                }
                .buttonStyle(.tintedPill(.red, size: .small))
                .disabled(pendingControlAction != nil)
                .accessibilityHint("Stops learning until you enable it again")
            }

        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Learnings header")
    }

    private func confirmWithdrawConsent() {
        guard pendingControlAction == nil else { return }
        HapticFeedbackManager.shared.light()
        showPendingControlAction(.withdrawConsent)
        showingWithdrawConfirmation = true
    }

    private func confirmDeleteAllLearningData() {
        requestSensitiveAction(
            reason: "Authenticate to delete all learning data.",
            pendingAction: .deleteData
        ) {
            HapticFeedbackManager.shared.error()
            showingDeleteConfirmation = true
        }
    }

    private func withdrawConsent() {
        showPendingControlAction(.withdrawConsent)
        HapticFeedbackManager.shared.light()
        Task { @MainActor in
            await manager.withdrawConsent()
            HapticFeedbackManager.shared.success()
            finishPendingControlAction(
                title: "Learning Paused",
                message: "Learning is off. Your existing learnings data is still saved.",
                icon: "pause.circle.fill",
                iconColor: .green
            )
        }
    }

    private func deleteAllLearningData() {
        showPendingControlAction(.deleteData)
        HapticFeedbackManager.shared.error()
        Task { @MainActor in
            let didClear = await manager.clearAllData()
            if didClear {
                HapticFeedbackManager.shared.success()
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.72)) {
                    appState.hasCompletedOnboarding = false
                }
                finishPendingControlAction(
                    title: "Learnings Data Deleted",
                    message: "Your learnings profile, consent, and learning settings were removed.",
                    icon: "checkmark.circle.fill",
                    iconColor: .green
                )
            } else {
                HapticFeedbackManager.shared.error()
                finishPendingControlAction(
                    title: "Delete Failed",
                    message: manager.error ?? "Sorty could not delete all learnings data.",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .red
                )
            }
        }
    }

    private func showPendingControlAction(_ action: PendingControlAction) {
        pendingControlAction = action
        NotificationManager.shared.showHUDInfo(
            title: action.title,
            message: action.message,
            icon: action.icon,
            iconColor: action.iconColor,
            identifier: "learnings-control-action",
            isPersistent: true
        )
    }

    private func cancelPendingControlAction() {
        guard pendingControlAction != nil else { return }
        pendingControlAction = nil
        NotificationManager.shared.dismissHUD(identifier: "learnings-control-action")
    }

    private func finishPendingControlAction(
        title: String,
        message: String,
        icon: String,
        iconColor: Color
    ) {
        pendingControlAction = nil
        NotificationManager.shared.showHUDInfo(
            title: title,
            message: message,
            icon: icon,
            iconColor: iconColor,
            identifier: "learnings-control-action"
        )
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(heroAccentColor.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: heroIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(heroAccentColor)
                        .symbolReplaceTransition(animationValue: heroIcon)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(heroTitle)
                        .font(.headline)
                        .numericTextTransition(animationValue: heroTitle)
                    if let subtitle = heroSubtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .numericTextTransition(animationValue: subtitle)
                    }
                }
            }

            if let error = manager.error, !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .systemLiquidGlassBackground(cornerRadius: 8, interactive: false)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 14, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Learning status summary")
    }

    private var heroIcon: String {
        guard let profile = manager.currentProfile, profile.sessions.count > 0 else {
            return "sparkles"
        }
        let recentSessions = profile.sessions.prefix(5)
        let recentClean = recentSessions.filter { $0.acceptedWithoutCorrections }.count
        if recentClean == recentSessions.count && recentSessions.count >= 2 {
            return "checkmark.seal.fill"
        }
        return "brain.head.profile"
    }

    private var heroAccentColor: Color {
        guard let profile = manager.currentProfile, profile.sessions.count > 0 else {
            return .blue
        }
        let recentSessions = profile.sessions.prefix(5)
        let recentClean = recentSessions.filter { $0.acceptedWithoutCorrections }.count
        if recentClean == recentSessions.count && recentSessions.count >= 2 {
            return .green
        }
        return .purple
    }

    private var heroTitle: String {
        guard let profile = manager.currentProfile else {
            return "Ready to Learn"
        }
        let sessionCount = profile.sessions.count
        guard sessionCount > 0 else {
            return "Ready to Learn"
        }
        return "Learned from \(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }

    private var heroSubtitle: String? {
        guard let profile = manager.currentProfile else {
            return "Organize some folders and Sorty will pick up your preferences."
        }
        let sessionCount = profile.sessions.count
        guard sessionCount > 0 else {
            return "Organize some folders and Sorty will pick up your preferences."
        }
        let recentSessions = profile.sessions.prefix(5)
        let recentClean = recentSessions.filter { $0.acceptedWithoutCorrections }.count
        let ruleCount = profile.inferredRules.filter { $0.isEnabled }.count

        if recentClean == recentSessions.count && recentSessions.count >= 2 {
            return "Your last \(recentSessions.count) runs needed no corrections."
        } else if ruleCount > 0 {
            return
                "\(ruleCount) learned pattern\(ruleCount == 1 ? " is" : "s are") actively applied."
        }
        return nil
    }

    // MARK: - What Sorty Has Learned

    private var whatSortyHasLearnedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("What Sorty Has Learned")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }

            if let profile = manager.currentProfile {
                let topRules = profile.inferredRules
                    .filter { $0.isEnabled }
                    .sorted { $0.priority > $1.priority }
                    .prefix(5)
                let profileSummary = LearningsProfileArchiveSummary(profile: profile)
                let metrics = learningDataMetrics(for: profileSummary)
                let totalRecordCount = profileSummary.totalRecordCount

                if totalRecordCount == 0 {
                    emptyLearningsPlaceholder
                } else {
                    learningDataSummary(
                        metrics: metrics,
                        totalRecordCount: totalRecordCount,
                        hasActivePatterns: !topRules.isEmpty
                    )

                    if !topRules.isEmpty {
                        activePatternsPane(topRules: Array(topRules))
                    }
                }
            } else {
                emptyLearningsPlaceholder
            }
        }
    }

    /// Collapsible liquid-glass pane listing the learned rules Sorty applies.
    private func activePatternsPane(topRules: [InferredRule]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                HapticFeedbackManager.shared.light()
                withAnimation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .spring(response: 0.32, dampingFraction: 0.86)
                ) {
                    isActivePatternsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Active Patterns")
                        .font(.subheadline.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("\(topRules.count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isActivePatternsExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ActivePatternsDisclosureButton")
            .accessibilityHint(
                isActivePatternsExpanded
                    ? "Collapses the active patterns list"
                    : "Expands the active patterns list"
            )

            if isActivePatternsExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(topRules.enumerated()), id: \.element.id) { index, rule in
                        LearningInsightRow(rule: rule, manager: manager)
                            .animatedAppearance(delay: Double(index) * 0.05)
                        if index < topRules.count - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top))
                )
            }
        }
        .systemLiquidGlassBackground(cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func learningDataMetrics(
        for summary: LearningsProfileArchiveSummary
    ) -> [LearningDataMetric] {
        return [
            LearningDataMetric(
                category: .patterns,
                count: summary.inferredRules
            ),
            LearningDataMetric(
                category: .sessions,
                count: summary.sessions
            ),
            LearningDataMetric(
                category: .feedback,
                count: summary.feedbackCount
            ),
            LearningDataMetric(
                category: .instructions,
                count: summary.instructionCount
            ),
            LearningDataMetric(
                category: .supportingData,
                count: summary.supportingDataCount
            ),
        ].filter { $0.count > 0 }
    }

    private func learningDataSummary(
        metrics: [LearningDataMetric],
        totalRecordCount: Int,
        hasActivePatterns: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(totalRecordCount.formatted()) stored learning record\(totalRecordCount == 1 ? "" : "s")")
                    .font(.subheadline.bold())
                Text(
                    hasActivePatterns
                        ? "Sorty uses the active patterns below when organizing."
                        : "Sorty has learning evidence saved, but has not formed an active pattern from it yet."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 125), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(metrics) { metric in
                    Button {
                        HapticFeedbackManager.shared.light()
                        selectedLearningRecordsCategory = metric.category
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: metric.category.systemImage)
                                .foregroundStyle(metric.category.color)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            Text("\(metric.count.formatted()) \(metric.category.title(for: metric.count))")
                                .font(.caption.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .systemLiquidGlassBackground(cornerRadius: 9)
                    .accessibilityHint("Shows the stored \(metric.category.title.lowercased()) records")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
    }

    private func learningRecordsDetailSheet(
        category: LearningRecordsCategory,
        profile: LearningsProfile
    ) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: category.systemImage)
                        .font(.title2)
                        .foregroundStyle(category.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .font(.title2.bold())
                        Text("Stored locally in your Learnings profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") {
                        selectedLearningRecordsCategory = nil
                    }
                    .buttonStyle(.sortyPrimary(size: .small))
                }
                .padding(20)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        learningRecordsList(category: category, profile: profile)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(category.title)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(category.title) learning records")
    }

    @ViewBuilder
    private func learningRecordsList(
        category: LearningRecordsCategory,
        profile: LearningsProfile
    ) -> some View {
        switch category {
        case .patterns:
            learningRecordSection(title: "Inferred Patterns", count: profile.inferredRules.count) {
                ForEach(profile.inferredRules.sorted { $0.priority > $1.priority }) { rule in
                    learningPatternRecordRow(rule)
                }
            }

        case .sessions:
            learningRecordSection(title: "Organization Sessions", count: profile.sessions.count) {
                ForEach(profile.sessions.sorted { $0.timestamp > $1.timestamp }) { session in
                    learningRecordRow(
                        title: URL(fileURLWithPath: session.folderPath).lastPathComponent,
                        detail: sessionDetail(session),
                        date: session.completedAt ?? session.timestamp,
                        systemImage: session.wasReverted ? "arrow.uturn.backward" : "folder",
                        fields: sessionRecordFields(session)
                    )
                }
            }

        case .feedback:
            feedbackRecordSections(profile: profile)

        case .instructions:
            instructionRecordSections(profile: profile)

        case .supportingData:
            supportingDataRecordSections(profile: profile)
        }
    }

    @ViewBuilder
    private func feedbackRecordSections(profile: LearningsProfile) -> some View {
        learningRecordSection(title: "Observed Changes", count: profile.postOrganizationChanges.count) {
            ForEach(profile.postOrganizationChanges.sorted { $0.timestamp > $1.timestamp }) { change in
                learningRecordRow(
                    title: "Moved after organization",
                    detail: "\(safeFileName(change.originalPath)) → \(safeFileName(change.newPath))",
                    date: change.timestamp,
                    systemImage: "arrow.right",
                    fields: [
                        LearningRecordField(label: "Original Item", value: safeFileName(change.originalPath)),
                        LearningRecordField(label: "New Location", value: safeFileName(change.newPath)),
                        LearningRecordField(label: "Originally Organized by Sorty", value: change.wasAIOrganized ? "Yes" : "No"),
                    ]
                )
            }
        }
        learningRecordSection(title: "Cancelled Plans", count: profile.cancelledOrganizations.count) {
            ForEach(profile.cancelledOrganizations.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: safeFileName(item.folderPath),
                    detail: "Cancelled during \(item.cancelledAtStage) · \(item.fileCount) files",
                    date: item.timestamp,
                    systemImage: "xmark.circle",
                    fields: cancelledOrganizationFields(item)
                )
            }
        }
        learningRecordSection(title: "Regenerated Plans", count: profile.regeneratedOrganizations.count) {
            ForEach(profile.regeneratedOrganizations.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: safeFileName(item.folderPath),
                    detail: item.guidingInstruction ?? "Regenerated \(item.regenerationCount) time\(item.regenerationCount == 1 ? "" : "s")",
                    date: item.timestamp,
                    systemImage: "arrow.clockwise",
                    fields: regeneratedOrganizationFields(item)
                )
            }
        }
        learningRecordSection(
            title: "Accepted Regeneration Differences",
            count: profile.regenerationPreferenceEvidence.count
        ) {
            ForEach(profile.regenerationPreferenceEvidence.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: safeFileName(item.folderPath),
                    detail: "Compared the accepted plan with \(item.attempts.count) earlier attempt\(item.attempts.count == 1 ? "" : "s")",
                    date: item.timestamp,
                    systemImage: "arrow.clockwise.circle",
                    fields: regenerationPreferenceFields(item)
                )
            }
        }
        learningRecordSection(title: "Rename Feedback", count: profile.renameFeedbackHistory.count) {
            ForEach(profile.renameFeedbackHistory.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.originalName,
                    detail: "\(item.action.rawValue.capitalized): \(item.finalName ?? item.suggestedName ?? item.originalName)",
                    date: item.timestamp,
                    systemImage: "text.cursor",
                    fields: renameFeedbackFields(item)
                )
            }
        }
        learningRecordSection(title: "History Reverts", count: profile.historyReverts.count) {
            ForEach(profile.historyReverts.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.folderPath.map(safeFileName) ?? "Reverted organization",
                    detail: item.reason ?? "Reverted \(item.operationCount) operation\(item.operationCount == 1 ? "" : "s")",
                    date: item.timestamp,
                    systemImage: "arrow.uturn.backward",
                    fields: [
                        LearningRecordField(label: "Operations Reverted", value: "\(item.operationCount)"),
                        LearningRecordField(label: "Reason", value: item.reason ?? "No reason recorded"),
                    ]
                )
            }
        }
        labeledExampleSection(title: "Corrections", items: profile.corrections)
        labeledExampleSection(title: "Rejections", items: profile.rejections)
        labeledExampleSection(title: "Positive Examples", items: profile.positiveExamples)
        learningRecordSection(title: "Inline Answers", count: profile.inlineLearningMomentAnswers.count) {
            ForEach(profile.inlineLearningMomentAnswers.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.selectedOption,
                    detail: "Answer to an inline learning question",
                    date: item.timestamp,
                    systemImage: "checkmark.bubble",
                    fields: [
                        LearningRecordField(label: "Selected Answer", value: item.selectedOption),
                        LearningRecordField(label: "Question Record", value: item.momentId),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    private func instructionRecordSections(profile: LearningsProfile) -> some View {
        userInstructionSection(title: "Additional Instructions", items: profile.additionalInstructionsHistory)
        userInstructionSection(title: "Guiding Instructions", items: profile.guidingInstructionsHistory)
        learningRecordSection(title: "Steering Prompts", count: profile.steeringPrompts.count) {
            ForEach(profile.steeringPrompts.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.prompt,
                    detail: item.folderPath.map { "Folder: \(safeFileName($0))" },
                    date: item.timestamp,
                    systemImage: "arrow.triangle.turn.up.right.diamond",
                    fields: [
                        LearningRecordField(label: "Instruction", value: item.prompt),
                        LearningRecordField(label: "Folder", value: item.folderPath.map(safeFileName) ?? "All folders"),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    private func supportingDataRecordSections(profile: LearningsProfile) -> some View {
        learningRecordSection(title: "Applied Jobs", count: profile.jobHistory.count) {
            ForEach(profile.jobHistory.sorted { $0.timestamp > $1.timestamp }) { job in
                learningRecordRow(
                    title: job.projectName,
                    detail: "\(job.entries.count) operation\(job.entries.count == 1 ? "" : "s") · \(String(describing: job.status))",
                    date: job.timestamp,
                    systemImage: "tray.full",
                    fields: [
                        LearningRecordField(label: "Operations", value: "\(job.entries.count)"),
                        LearningRecordField(label: "Status", value: String(describing: job.status).capitalized),
                        LearningRecordField(label: "Backup", value: job.backupMode.displayName),
                    ]
                )
            }
        }
        learningRecordSection(title: "Learning Exclusions", count: profile.learningExclusionPatterns.count) {
            ForEach(profile.learningExclusionPatterns, id: \.self) { pattern in
                learningRecordRow(
                    title: safeFileName(pattern),
                    detail: "Excluded from learning",
                    date: nil,
                    systemImage: "eye.slash",
                    fields: [
                        LearningRecordField(label: "Folder", value: safeFileName(pattern)),
                        LearningRecordField(label: "Effect", value: "Sorty does not collect learning signals from this location."),
                    ]
                )
            }
        }
        learningRecordSection(title: "Rejected Pattern Cooldowns", count: profile.rejectedRuleCooldowns.count) {
            ForEach(profile.rejectedRuleCooldowns.sorted { $0.value > $1.value }, id: \.key) { ruleID, date in
                learningRecordRow(
                    title: "Pattern \(ruleID.prefix(8))",
                    detail: "Ignored until \(date.formatted(date: .abbreviated, time: .shortened))",
                    date: nil,
                    systemImage: "timer",
                    fields: [
                        LearningRecordField(label: "Pattern ID", value: ruleID),
                        LearningRecordField(label: "Ignored Until", value: date.formatted(date: .long, time: .standard)),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    private func labeledExampleSection(title: String, items: [LabeledExample]) -> some View {
        learningRecordSection(title: title, count: items.count) {
            ForEach(items.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: safeFileName(item.srcPath),
                    detail: "\(item.action.rawValue.capitalized): \(safeFileName(item.dstPath))",
                    date: item.timestamp,
                    systemImage: "arrow.right.circle",
                    fields: [
                        LearningRecordField(label: "Source", value: safeFileName(item.srcPath)),
                        LearningRecordField(label: "Destination", value: safeFileName(item.dstPath)),
                        LearningRecordField(label: "Outcome", value: item.action.rawValue.capitalized),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    private func userInstructionSection(title: String, items: [UserInstruction]) -> some View {
        learningRecordSection(title: title, count: items.count) {
            ForEach(items.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.instruction,
                    detail: item.folderPath.map { "Folder: \(safeFileName($0))" } ?? item.context,
                    date: item.timestamp,
                    systemImage: "text.bubble",
                    fields: instructionRecordFields(item)
                )
            }
        }
    }

    @ViewBuilder
    private func learningRecordSection<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) · \(count)")
                    .font(.subheadline.bold())
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    content()
                }
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            }
        }
    }

    private func learningRecordRow(
        title: String,
        detail: String?,
        date: Date?,
        systemImage: String,
        fields: [LearningRecordField] = []
    ) -> some View {
        NavigationLink {
            learningRecordDetailView(
                title: title,
                systemImage: systemImage,
                fields: recordDetailFields(summary: detail, date: date, additionalFields: fields)
            )
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if let date {
                    Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows this record's details")
    }

    private func learningPatternRecordRow(_ rule: InferredRule) -> some View {
        HStack(spacing: 10) {
            NavigationLink {
                learningRecordDetailView(
                    title: rule.explanation,
                    systemImage: "sparkles",
                    fields: patternRecordFields(rule)
                )
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(rule.isEnabled ? .green : .secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.explanation)
                            .font(.subheadline)
                        Text(rule.isEnabled ? "Enabled · \(rule.scope.displayName)" : "Disabled · \(rule.scope.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the pattern, evidence, and usage details")

            Toggle(
                "Enable \(rule.explanation)",
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in
                        Task {
                            HapticFeedbackManager.shared.selection()
                            await manager.setRuleEnabled(ruleId: rule.id, enabled: newValue)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.7)
            .accessibilityLabel("Enable pattern")
            .accessibilityValue(rule.isEnabled ? "On" : "Off")
        }
        .padding(12)
    }

    private func learningRecordDetailView(
        title: String,
        systemImage: String,
        fields: [LearningRecordField]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(field.value)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .accessibilityElement(children: .combine)
                        if index < fields.count - 1 {
                            Divider()
                        }
                    }
                }
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            }
            .padding(20)
        }
        .navigationTitle("Record Details")
    }

    private func recordDetailFields(
        summary: String?,
        date: Date?,
        additionalFields: [LearningRecordField]
    ) -> [LearningRecordField] {
        var fields = additionalFields
        if let summary, !summary.isEmpty, !fields.contains(where: { $0.value == summary }) {
            fields.insert(LearningRecordField(label: "Summary", value: summary), at: 0)
        }
        if let date {
            fields.append(
                LearningRecordField(
                    label: "Recorded",
                    value: date.formatted(date: .long, time: .standard)
                ))
        }
        return fields
    }

    private func sessionRecordFields(_ session: OrganizationSession) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Outcome", value: session.reaction.rawValue.capitalized),
            LearningRecordField(label: "Files Moved", value: "\(session.filesMoved.count)"),
            LearningRecordField(label: "Recorded Events", value: "\(session.events.count)"),
            LearningRecordField(label: "Corrections", value: "\(session.userCorrections.count)"),
            LearningRecordField(label: "Rename Feedback", value: "\(session.renameFeedback.count)"),
            LearningRecordField(label: "Patterns Used", value: "\(session.usedRuleIds.count)"),
            LearningRecordField(label: "Patterns That Failed", value: "\(session.failedRuleIds.count)"),
            LearningRecordField(label: "Reverted", value: session.wasReverted ? "Yes" : "No"),
        ]
        if let planSummary = session.planSummary, !planSummary.isEmpty {
            fields.insert(LearningRecordField(label: "Plan", value: planSummary), at: 1)
        }
        return fields
    }

    private func patternRecordFields(_ rule: InferredRule) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Status", value: rule.isEnabled ? "Enabled" : "Disabled"),
            LearningRecordField(label: "Approval", value: rule.status.rawValue.capitalized),
            LearningRecordField(label: "Scope", value: rule.scope.displayName),
            LearningRecordField(label: "Pattern", value: rule.pattern),
            LearningRecordField(label: "Destination Template", value: rule.template),
            LearningRecordField(label: "Priority", value: "\(rule.priority)"),
            LearningRecordField(label: "Supporting Examples", value: "\(rule.exampleIds.count)"),
            LearningRecordField(label: "Evidence Records", value: "\(rule.evidenceIds.count)"),
            LearningRecordField(label: "Applied Successfully", value: "\(rule.successCount)"),
            LearningRecordField(label: "Corrected After Use", value: "\(rule.failureCount)"),
        ]
        if let evidence = rule.evidenceDescription, !evidence.isEmpty {
            fields.insert(LearningRecordField(label: "Evidence", value: evidence), at: 5)
        }
        if let lastAppliedAt = rule.lastAppliedAt {
            fields.append(
                LearningRecordField(
                    label: "Last Applied",
                    value: lastAppliedAt.formatted(date: .long, time: .standard)
                ))
        }
        return fields
    }

    private func cancelledOrganizationFields(
        _ item: CancelledOrganization
    ) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Cancelled During", value: item.cancelledAtStage),
            LearningRecordField(label: "Files", value: "\(item.fileCount)"),
            LearningRecordField(label: "Proposed Folders", value: "\(item.proposedFolderCount)"),
            LearningRecordField(label: "Regenerations", value: "\(item.regenerationCount)"),
        ]
        if let instructions = item.instructions, !instructions.isEmpty {
            fields.append(LearningRecordField(label: "Instructions", value: instructions))
        }
        if let summary = item.proposedStructureSummary, !summary.isEmpty {
            fields.append(LearningRecordField(label: "Proposed Structure", value: summary))
        }
        if let model = item.aiModel, !model.isEmpty {
            fields.append(LearningRecordField(label: "Model", value: model))
        }
        return fields
    }

    private func regeneratedOrganizationFields(
        _ item: RegeneratedOrganization
    ) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Regeneration Count", value: "\(item.regenerationCount)"),
            LearningRecordField(label: "Folder", value: safeFileName(item.folderPath)),
        ]
        if let instruction = item.guidingInstruction, !instruction.isEmpty {
            fields.append(LearningRecordField(label: "Guiding Instruction", value: instruction))
        }
        if let summary = item.previousPlanSummary, !summary.isEmpty {
            fields.append(LearningRecordField(label: "Previous Plan", value: summary))
        }
        return fields
    }

    private func regenerationPreferenceFields(
        _ item: RegenerationPreferenceEvidence
    ) -> [LearningRecordField] {
        let changedFiles = Set(item.attempts.flatMap(\.fileChanges).map(\.fileID)).count
        var fields = [
            LearningRecordField(label: "Earlier Attempts", value: "\(item.attempts.count)"),
            LearningRecordField(label: "Files Changed", value: "\(changedFiles)"),
            LearningRecordField(label: "Accepted Version", value: "\(item.acceptedVersion)"),
        ]
        if let latest = item.attempts.last {
            fields.append(
                LearningRecordField(
                    label: "Folder Count",
                    value: "\(latest.rejectedFolderCount) → \(latest.acceptedFolderCount)"
                )
            )
            fields.append(
                LearningRecordField(
                    label: "Maximum Depth",
                    value: "\(latest.rejectedMaxDepth) → \(latest.acceptedMaxDepth)"
                )
            )
            fields.append(
                LearningRecordField(
                    label: "Unorganized Files",
                    value: "\(latest.rejectedUnorganizedCount) → \(latest.acceptedUnorganizedCount)"
                )
            )
        }
        return fields
    }

    private func renameFeedbackFields(
        _ item: RenameFeedbackEvent
    ) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Original Name", value: item.originalName),
            LearningRecordField(label: "Outcome", value: item.action.rawValue.capitalized),
        ]
        if let suggestedName = item.suggestedName, !suggestedName.isEmpty {
            fields.append(LearningRecordField(label: "Suggested Name", value: suggestedName))
        }
        if let finalName = item.finalName, !finalName.isEmpty {
            fields.append(LearningRecordField(label: "Final Name", value: finalName))
        }
        if let confidence = item.confidence {
            fields.append(
                LearningRecordField(
                    label: "Model Confidence",
                    value: confidence.formatted(.percent.precision(.fractionLength(0)))
                ))
        }
        return fields
    }

    private func instructionRecordFields(_ item: UserInstruction) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Instruction", value: item.instruction),
            LearningRecordField(
                label: "Folder",
                value: item.folderPath.map(safeFileName) ?? "All folders"
            ),
        ]
        if let context = item.context, !context.isEmpty {
            fields.append(LearningRecordField(label: "Context", value: context))
        }
        if let fileCount = item.fileCount {
            fields.append(LearningRecordField(label: "Files", value: "\(fileCount)"))
        }
        if item.isRegeneration == true {
            fields.append(LearningRecordField(label: "Used for Regeneration", value: "Yes"))
        }
        return fields
    }

    private func sessionDetail(_ session: OrganizationSession) -> String {
        let reaction = session.reaction.rawValue.capitalized
        let fileSummary = "\(session.filesMoved.count) file\(session.filesMoved.count == 1 ? "" : "s")"
        let feedbackSummary = "\(session.events.count) event\(session.events.count == 1 ? "" : "s")"
        return "\(reaction) · \(fileSummary) · \(feedbackSummary)"
    }

    private func safeFileName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Folder" : name
    }

    private var emptyLearningsPlaceholder: some View {
        VStack(spacing: 12) {
            Image("LearningsEmptyState")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 92, height: 92)
                .accessibilityIgnoresInvertColors()
                .opacity(emptyLearningsHasAppeared ? 1 : 0)
                .scaleEffect(emptyLearningsHasAppeared ? 1 : 0.8)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .spring(response: 0.5, dampingFraction: 0.7).delay(0.1),
                    value: emptyLearningsHasAppeared
                )
                .accessibilityHidden(true)
            Text("No patterns learned yet")
                .font(.subheadline.bold())
                .opacity(emptyLearningsHasAppeared ? 1 : 0)
                .offset(y: emptyLearningsHasAppeared ? 0 : 8)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .spring(response: 0.5, dampingFraction: 0.8).delay(0.2),
                    value: emptyLearningsHasAppeared)
            Text(
                "Organize some folders, and Sorty will pick up your preferences from corrections and feedback."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .opacity(emptyLearningsHasAppeared ? 1 : 0)
            .offset(y: emptyLearningsHasAppeared ? 0 : 10)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.5, dampingFraction: 0.8).delay(0.3),
                value: emptyLearningsHasAppeared)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No patterns learned yet. Organize folders to start learning.")
        .task {
            guard !emptyLearningsHasAppeared else { return }
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            emptyLearningsHasAppeared = true
        }
    }

    // MARK: - Settings (Inline)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    settingsRowLabel(
                        systemImage: "wand.and.stars",
                        title: "Learnings Model",
                        detail: usesDedicatedLearningsModel
                            ? "Dedicated model for learnings analysis"
                            : "Same model as organization"
                    )
                    Spacer()
                    ModelSelectorCompactButton(
                        provider: usesDedicatedLearningsModel
                            ? (manager.learningsModelSelection?.provider
                                ?? settingsViewModel.config.provider)
                            : settingsViewModel.config.provider,
                        label: usesDedicatedLearningsModel ? effectiveLearningsModel : "Default",
                        onTap: {
                            showLearningsModelPicker = true
                        }
                    )
                    .modelSelectorTriggerBounds()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)

                Divider().padding(.leading, 40)

                HStack(spacing: 12) {
                    settingsRowLabel(
                        systemImage: "calendar.badge.clock",
                        title: "Data Retention",
                        detail: "How long to keep learning data"
                    )
                    Spacer()
                    Picker("", selection: $manager.dataRetentionDays) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                        Text("Forever").tag(0)
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .frame(width: 120)
                    .labelsHidden()
                    .onChange(of: manager.dataRetentionDays) { _ in
                        HapticFeedbackManager.shared.selection()
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)

                Divider().padding(.leading, 40)

                HStack(spacing: 12) {
                    settingsRowLabel(
                        systemImage: "person.text.rectangle",
                        title: "Learning Data",
                        detail: "Import, export, or delete your learning data"
                    )
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Import…") {
                            requestSensitiveAction(
                                reason: "Authenticate to import a learnings profile."
                            ) {
                                presentFileImporter(.learningsProfile)
                            }
                        }
                        Button("Export…") {
                            requestSensitiveAction(
                                reason: "Authenticate to export your learnings profile."
                            ) {
                                exportProfile()
                            }
                        }
                        Button(role: .destructive) {
                            confirmDeleteAllLearningData()
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                        .buttonStyle(.sortyBordered(intent: .destructive, size: .small))
                        .accessibilityHint("Permanently deletes all learning data")
                    }
                    .buttonStyle(.sortyBordered(size: .small))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Learnings settings")
        }
    }

    private func settingsRowLabel(
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundColor(.blue)
                .font(.body.bold())
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var referenceDirectoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teach Sorty with example folders")
                        .font(.subheadline.bold())
                    Text(
                        "Add folders that are already organized well. Sorty uses a matching example only when the files in a preview are similar. Representative filenames may be sent to your selected AI provider. Sorty never changes the example folder."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !manager.modelDirectories.isEmpty {
                    Text("\(manager.modelDirectories.filter(\.isEnabled).count) active")
                        .font(.caption.bold())
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .systemLiquidGlassBackground(cornerRadius: 999, interactive: false)
                        .clipShape(Capsule())
                        .numericTextTransition(
                            animationValue: manager.modelDirectories.filter(\.isEnabled).count
                        )
                    Button {
                        presentFileImporter(.modelDirectories)
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.sortyPrimary(size: .small))
                    .accessibilityIdentifier("AddModelDirectoryButton")
                }
            }

            if manager.modelDirectories.isEmpty {
                VStack(spacing: 10) {
                    if let image = SortyResources.image(named: "TeachSortyExampleFolders") {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .opacity(emptyExampleFoldersHasAppeared ? 1 : 0)
                            .scaleEffect(emptyExampleFoldersHasAppeared ? 1 : 0.8)
                            .animation(
                                reduceMotion
                                    ? .easeOut(duration: 0.12)
                                    : .spring(response: 0.5, dampingFraction: 0.7).delay(0.1),
                                value: emptyExampleFoldersHasAppeared
                            )
                            .accessibilityHidden(true)
                    }
                    Text("No reference directories")
                        .font(.subheadline.bold())
                        .opacity(emptyExampleFoldersHasAppeared ? 1 : 0)
                        .offset(y: emptyExampleFoldersHasAppeared ? 0 : 8)
                        .animation(
                            reduceMotion
                                ? .easeOut(duration: 0.12)
                                : .spring(response: 0.5, dampingFraction: 0.8).delay(0.2),
                            value: emptyExampleFoldersHasAppeared
                        )
                    Button {
                        presentFileImporter(.modelDirectories)
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.sortyPrimary(size: .small))
                    .accessibilityIdentifier("EmptyStateAddModelDirectoryButton")
                    .opacity(emptyExampleFoldersHasAppeared ? 1 : 0)
                    .offset(y: emptyExampleFoldersHasAppeared ? 0 : 10)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.12)
                            : .spring(response: 0.5, dampingFraction: 0.8).delay(0.3),
                        value: emptyExampleFoldersHasAppeared
                    )
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .task {
                    guard !emptyExampleFoldersHasAppeared else { return }
                    if !reduceMotion {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard !Task.isCancelled else { return }
                    emptyExampleFoldersHasAppeared = true
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(manager.modelDirectories) { directory in
                        ModelDirectoryRow(directory: directory, manager: manager)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 16, interactive: false)
    }

    // MARK: - Helpers

    private var effectiveLearningsModel: String {
        manager.effectiveAIConfig(from: settingsViewModel.config).model
    }

    private var organizationModelDisplay: String {
        let provider = settingsViewModel.config.provider
        let model = settingsViewModel.config.model
        return "\(provider.displayName) / \(model.isEmpty ? provider.defaultModel : model)"
    }

    private func presentFileImporter(_ importer: ActiveFileImporter) {
        HapticFeedbackManager.shared.tap()
        activeFileImporter = importer
        isShowingFileImporter = true
    }

    private func requestSensitiveAction(
        reason: String,
        pendingAction: PendingControlAction? = nil,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        if let pendingAction {
            guard self.pendingControlAction == nil else { return }
            showPendingControlAction(pendingAction)
        }

        if !FeatureFlags.sensitiveActionAuthenticationEnabled {
            onSuccess()
            return
        }

        Task { @MainActor in
            let didAuthenticate = await SecurityManager.shared.authenticateForSensitiveAction(
                reason: reason)
            guard didAuthenticate else {
                HapticFeedbackManager.shared.error()
                if pendingAction != nil {
                    finishPendingControlAction(
                        title: "Authentication Cancelled",
                        message: "No changes were made.",
                        icon: "xmark.circle.fill",
                        iconColor: .orange
                    )
                }
                return
            }
            onSuccess()
        }
    }

    private var usesDedicatedLearningsModel: Bool {
        guard let selection = manager.learningsModelSelection else { return false }
        return selection.provider == settingsViewModel.config.provider
    }

    // MARK: - Export / Import

    private func exportProfile() {
        guard manager.currentProfile != nil else { return }
        let panel = NSSavePanel()
        let learningsType = UTType(filenameExtension: "learnings", conformingTo: .json) ?? .json
        panel.allowedContentTypes = [learningsType]
        panel.nameFieldStringValue =
            "learnings_profile_\(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-")).learnings"
        panel.message = "Export Learning Profile"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let summary = try manager.exportProfile(to: url)
                HapticFeedbackManager.shared.success()
                NotificationManager.shared.showHUDInfo(
                    title: "Learning Profile Exported",
                    message: "Saved \(summary.totalRecordCount) learning records with profile settings and integrity metadata.",
                    icon: "checkmark.circle.fill",
                    iconColor: .green
                )
            } catch {
                DebugLogger.log("Failed to export profile: \(error)")
                HapticFeedbackManager.shared.error()
                manager.error = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func handleModelDirectoryImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var addedCount = 0
            var duplicateCount = 0
            var limitReached = false
            for url in urls {
                let hasScopedAccess = url.startAccessingSecurityScopedResource()
                defer { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }
                switch manager.addModelDirectoryWithResult(url: url) {
                case .added:
                    addedCount += 1
                case .duplicate:
                    duplicateCount += 1
                case .activeLimitReached:
                    limitReached = true
                }
            }
            if addedCount > 0 {
                HapticFeedbackManager.shared.success()
                NotificationManager.shared.showHUDInfo(
                    title: addedCount == 1 ? "Example Folder Added" : "Example Folders Added",
                    message: "Sorty is scanning \(addedCount) folder\(addedCount == 1 ? "" : "s") now.",
                    icon: "folder.badge.plus",
                    iconColor: .teal
                )
            } else if limitReached {
                HapticFeedbackManager.shared.error()
                NotificationManager.shared.showHUDInfo(
                    title: "Five Example Folders Active",
                    message: "Pause or remove one before adding another.",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange
                )
            } else if duplicateCount > 0 {
                HapticFeedbackManager.shared.error()
                NotificationManager.shared.showHUDInfo(
                    title: "Folder Already Added",
                    message: "Sorty is already learning from that folder.",
                    icon: "folder.badge.questionmark",
                    iconColor: .orange
                )
            } else {
                HapticFeedbackManager.shared.error()
            }
        case .failure(let error):
            DebugLogger.log("Model directory import failed: \(error)")
            HapticFeedbackManager.shared.error()
        }
    }

    private func handleProfileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let importResult = try await manager.importProfile(from: url)
                    HapticFeedbackManager.shared.success()
                    var details = [
                        "Merged \(importResult.importedRecordCount) records with \(importResult.previousRecordCount) existing records.",
                        "The profile now contains \(importResult.resultingRecordCount) records."
                    ]
                    if importResult.restoredSettingCount > 0 {
                        details.append("Restored \(importResult.restoredSettingCount) learning settings.")
                    }
                    if importResult.omittedByRetentionPolicy > 0 {
                        details.append(
                            "\(importResult.omittedByRetentionPolicy) older records were omitted by your retention policy."
                        )
                    }
                    if importResult.wasLegacyProfile {
                        details.append("The legacy profile was upgraded to the current format.")
                    }
                    NotificationManager.shared.showHUDInfo(
                        title: "Learning Profile Imported",
                        message: details.joined(separator: " "),
                        icon: "checkmark.circle.fill",
                        iconColor: .green
                    )
                } catch {
                    DebugLogger.log("Failed to import profile: \(error)")
                    HapticFeedbackManager.shared.error()
                    manager.error = "Import failed: \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            DebugLogger.log("Import failed: \(error)")
        }
    }
}

// MARK: - Learning Insight Row

private struct LearningInsightRow: View {
    @SortyHotReload private var hotReload
    let rule: InferredRule
    @ObservedObject var manager: LearningsManager
    @State private var isHovered = false
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                .font(.body.bold())
                .foregroundColor(rule.isEnabled ? confidenceColor : .gray)
                .frame(width: 24)
                .symbolReplaceTransition(animationValue: rule.isEnabled)

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.explanation)
                    .font(.subheadline)
                    .foregroundColor(rule.isEnabled ? .primary : .secondary)

                HStack(spacing: 8) {
                    if rule.successCount > 0 {
                        Text("\(rule.successCount) applied")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .numericTextTransition(animationValue: rule.successCount)
                    }
                    if rule.failureCount > 0 {
                        Text("\(rule.failureCount) corrected")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .numericTextTransition(animationValue: rule.failureCount)
                    }
                    if case .folder = rule.scope {
                        Text(rule.scope.displayName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                if settingsViewModel.config.showStatsForNerds {
                    HStack(spacing: 8) {
                        Text("Used \(rule.successCount + rule.failureCount) times")
                        if rule.successCount + rule.failureCount > 0 {
                            Text("\(rule.successRate.formatted(.percent.precision(.fractionLength(0)))) accepted")
                        }
                        if let lastAppliedAt = rule.lastAppliedAt {
                            Text("Last used \(lastAppliedAt, format: .relative(presentation: .named))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in
                        Task {
                            HapticFeedbackManager.shared.selection()
                            await manager.setRuleEnabled(ruleId: rule.id, enabled: newValue)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.7)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            if hovering { HapticFeedbackManager.shared.selection() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rule.explanation). \(rule.isEnabled ? "Enabled" : "Disabled")")
    }

    private var confidenceColor: Color {
        if rule.failureRate > 0.3 { return .red }
        if rule.failureRate > 0.15 { return .orange }
        return .green
    }
}

// MARK: - Model Directory Row

struct ModelDirectoryRow: View {
    @SortyHotReload private var hotReload
    let directory: ReferenceModelDirectory
    @ObservedObject var manager: LearningsManager
    @State private var isHovered = false
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scanState: ReferenceDirectoryScanState {
        manager.modelDirectoryScanState(id: directory.id)
    }

    private var status: (text: String, icon: String, color: Color) {
        switch scanState {
        case .scanning:
            return ("Scanning folder structure and filenames", "arrow.triangle.2.circlepath", .blue)
        case .ready:
            return ("Ready for matching previews", "checkmark.circle.fill", .teal)
        case .warning(let message):
            return (message, "exclamationmark.triangle.fill", .orange)
        case .failed(let message):
            return ("Scan failed: \(message)", "xmark.circle.fill", .red)
        case .unavailable:
            return ("Folder is missing or unavailable", "folder.badge.questionmark", .orange)
        case .paused:
            return ("Paused and not used in previews", "pause.circle.fill", .secondary)
        }
    }

    private var learnedSummary: String? {
        guard let snapshot = directory.scanSnapshot else { return nil }
        let categories = snapshot.fileCategoryDistribution
            .filter { $0.value > 0 }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.rawValue < $1.key.rawValue
            }
            .prefix(3)
            .map { $0.key.rawValue.capitalized }
        let conventions = (snapshot.namingConventions + snapshot.fileNamingConventions)
            .orderedDeduplicated()
            .prefix(2)
        var parts = [
            "\(snapshot.totalFolderCount.formatted()) folders",
            "\(snapshot.totalFileCount.formatted()) files",
            "up to \(snapshot.maximumDepth.formatted()) levels deep",
        ]
        if categories.isEmpty == false {
            parts.append(categories.joined(separator: ", "))
        }
        if conventions.isEmpty == false {
            parts.append(conventions.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        var parts = [directory.displayName, status.text]
        if let learnedSummary {
            parts.append(learnedSummary)
        }
        if settingsViewModel.config.showStatsForNerds,
           let scannedAt = directory.lastScannedAt {
            parts.append("Last scanned \(scannedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: directory.isAccessible ? "folder.fill" : "folder.badge.questionmark")
                    .font(.body.bold())
                    .symbolReplaceTransition(animationValue: directory.isAccessible)
                    .foregroundStyle(status.color)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(directory.displayName)
                        .font(.subheadline.bold())
                        .foregroundStyle(directory.isEnabled ? .primary : .secondary)
                    PrivacySensitivePathText(path: directory.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        if scanState == .scanning {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: status.icon)
                                .accessibilityHidden(true)
                        }
                        Text(status.text)
                    }
                    .font(.caption)
                    .foregroundStyle(status.color)
                    .lineLimit(2)
                    if let learnedSummary {
                        Text(learnedSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if settingsViewModel.config.showStatsForNerds,
                       let scannedAt = directory.lastScannedAt {
                        Text("Last scanned \(scannedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityRepresentation {
                    Text(accessibilitySummary)
                }

                Spacer(minLength: 8)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons }
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(isHovered ? 0.08 : 0.03))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { HapticFeedbackManager.shared.selection() }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if directory.isAccessible {
            Button {
                HapticFeedbackManager.shared.tap()
                Task { @MainActor in
                    await manager.rescanModelDirectory(id: directory.id)
                    switch manager.modelDirectoryScanState(id: directory.id) {
                    case .ready, .warning:
                        HapticFeedbackManager.shared.success()
                        AccessibilityNotification.Announcement(
                            "Finished scanning \(directory.displayName)"
                        ).post()
                    case .failed, .unavailable:
                        HapticFeedbackManager.shared.error()
                        AccessibilityNotification.Announcement(
                            "Could not scan \(directory.displayName)"
                        ).post()
                    case .scanning, .paused:
                        break
                    }
                }
            } label: {
                Label(isFailedScan ? "Retry" : "Rescan", systemImage: "arrow.clockwise")
                    .font(.caption.bold())
            }
            .systemLiquidGlassButton()
            .disabled(scanState == .scanning)
            .accessibilityIdentifier("RescanModelDirectoryButton_\(directory.id)")

            Button {
                HapticFeedbackManager.shared.tap()
                let didToggle = manager.toggleModelDirectory(id: directory.id)
                if didToggle == false {
                    HapticFeedbackManager.shared.error()
                    NotificationManager.shared.showHUDInfo(
                        title: "Five Example Folders Active",
                        message: "Pause another folder before using this one.",
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .orange
                    )
                }
            } label: {
                Label(
                    directory.isEnabled ? "Pause" : "Use",
                    systemImage: directory.isEnabled ? "pause" : "play"
                )
                .font(.caption.bold())
            }
            .systemLiquidGlassButton()
            .accessibilityIdentifier("ModelDirectoryToggle_\(directory.id)")

            Button {
                HapticFeedbackManager.shared.tap()
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .font(.caption.bold())
            }
            .systemLiquidGlassButton()
            .accessibilityIdentifier("OpenModelDirectoryButton_\(directory.id)")
        }

        Button {
            HapticFeedbackManager.shared.tap()
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                manager.removeModelDirectory(id: directory.id)
            }
        } label: {
            Label("Remove", systemImage: "xmark")
                .font(.caption.bold())
        }
        .systemLiquidGlassButton()
        .accessibilityIdentifier("RemoveModelDirectoryButton_\(directory.id)")
    }

    private var isFailedScan: Bool {
        if case .failed = scanState { return true }
        return false
    }
}

// MARK: - Learning Exclusion Row

struct LearningExclusionRow: View {
    @SortyHotReload private var hotReload
    let pattern: String
    @ObservedObject var manager: LearningsManager
    @EnvironmentObject private var exclusionRules: ExclusionRulesManager
    @State private var isHovered = false

    private var displayName: String {
        let lastComponent = URL(fileURLWithPath: pattern).lastPathComponent
        return lastComponent.isEmpty ? pattern : lastComponent
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .font(.body.bold())
                .foregroundColor(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline.bold())
                PrivacySensitivePathText(path: pattern)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                HapticFeedbackManager.shared.tap()
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: pattern)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .font(.caption.bold())
            }
            .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))

            Button {
                HapticFeedbackManager.shared.tap()
                Task {
                    await manager.removeLearningExclusion(pattern)
                    exclusionRules.removeLegacyLearningsLinkedRules(
                        matchingLearningPattern: pattern)
                }
            } label: {
                Label("Remove", systemImage: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))
            .accessibilityLabel("Remove learnings exclusion for \(displayName)")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(isHovered ? 0.08 : 0.03))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            if hovering { HapticFeedbackManager.shared.selection() }
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    LearningsView()
}
