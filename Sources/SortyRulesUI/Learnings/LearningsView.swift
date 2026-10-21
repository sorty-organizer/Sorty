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

package struct LearningsView: View {
    @SortyHotReload var hotReload
    @EnvironmentObject var manager: LearningsManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var exclusionRules: ExclusionRulesManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State var showingDeleteConfirmation = false
    @State var showingWithdrawConfirmation = false
    @State var activeFileImporter: ActiveFileImporter?
    @State var isShowingFileImporter = false
    @State var emptyLearningsHasAppeared = false
    @State var emptyExampleFoldersHasAppeared = false
    @State var pendingControlAction: PendingControlAction?
    @State var selectedLearningRecordsCategory: LearningRecordsCategory?
    @AppStorage("learnings.activePatternsExpanded") var isActivePatternsExpanded = true

    package init() {}

    enum PendingControlAction: Equatable {
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

    enum ActiveFileImporter: Int, Identifiable {
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

    enum LearningRecordsCategory: String, Identifiable {
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

    struct LearningDataMetric: Identifiable {
        let category: LearningRecordsCategory
        let count: Int

        var id: String { category.id }
    }

    struct LearningRecordField: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    package var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Learnings Dashboard")
        .task {
            // No-op after the app's normal post-launch load; covers harness
            // mode and any path that shows Learnings before globals configure.
            await manager.loadPersistedState()
            if !manager.isLocked {
                await manager.loadProfileIfNeededForCollectionAsync()
            }
        }
        .navigationTitle("Learnings")
    }

    // MARK: - Onboarding

    var onboardingView: some View {
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

    func featureRow(icon: String, title: String, description: String) -> some View {
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

    var dashboardView: some View {
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
        .onChange(of: manager.showingImportPicker) { _, showing in
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

    var dashboardHeader: some View {
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

    func confirmWithdrawConsent() {
        guard pendingControlAction == nil else { return }
        HapticFeedbackManager.shared.light()
        showPendingControlAction(.withdrawConsent)
        showingWithdrawConfirmation = true
    }

    func confirmDeleteAllLearningData() {
        requestSensitiveAction(
            reason: "Authenticate to delete all learning data.",
            pendingAction: .deleteData
        ) {
            HapticFeedbackManager.shared.error()
            showingDeleteConfirmation = true
        }
    }

    func withdrawConsent() {
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

    func deleteAllLearningData() {
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

    func showPendingControlAction(_ action: PendingControlAction) {
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

    func cancelPendingControlAction() {
        guard pendingControlAction != nil else { return }
        pendingControlAction = nil
        NotificationManager.shared.dismissHUD(identifier: "learnings-control-action")
    }

    func finishPendingControlAction(
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

}

#Preview {
    LearningsView()
}
