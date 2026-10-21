import Foundation
import AppKit
import SwiftUI

struct ReadyToOrganizeView: View {
    @SortyHotReload var hotReload
    let onStart: () -> Void
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var storageLocationsManager: StorageLocationsManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var automationManager: AutomationManager
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var customPersonaStore: CustomPersonaStore
    @StateObject var sessionManager = AISessionManager.shared
    @StateObject var steeringManager = SteeringPromptManager.shared
    @State var hasAppeared = false
    @State var isTextFieldFocused = false
    @State var showStorageLocations = false
    @State var showingFolderPicker = false
    @State var suggestedLocationName: String? = nil
    @State var addStorageLocationErrorMessage: String?
    @State var showSavePromptDialog = false
    @State var savePromptName = ""
    @State var isImprovingPrompt = false
    @State var showImprovePromptRequest = false
    @State var improvePromptRequestMessage = ""
    @State var showSavedPromptsSheet = false
    @State var showStorageLocationsInfo = false
    @State var referenceableFiles: [InstructionFileReference] = []
    @State var instructionSelection: NSRange = NSRange(location: 0, length: 0)
    @State var referenceRefreshTask: Task<Void, Never>?
    @State var startCTACompression: CGFloat = 0

    init(onStart: @escaping () -> Void, startsVisible: Bool = false) {
        self.onStart = onStart
        _hasAppeared = State(initialValue: startsVisible)
    }

    var mode: OrganizationMode {
        settingsViewModel.config.mode
    }

    var instructionSuggestions: [String] {
        InstructionSuggestionCatalog.suggestions(
            for: mode,
            personaManager: personaManager,
            customPersonaStore: customPersonaStore
        )
    }

    var isConnecting: Bool {
        sessionManager.prewarmingProvider != nil
    }

    var selectedStorageLocationCount: Int {
        storageLocationsManager.locations.filter(\.isEnabled).count
    }

    var unavailableSelectedStorageLocationCount: Int {
        max(0, selectedStorageLocationCount - storageLocationsManager.enabledLocations.count)
    }

    var storageLocationSummaryID: String {
        if selectedStorageLocationCount > 0 {
            return unavailableSelectedStorageLocationCount > 0
                ? "selected-unavailable"
                : "selected-available"
        }

        return storageLocationsManager.locations.isEmpty ? "unconfigured" : "inactive"
    }

    var storageLocationSummaryTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.94, anchor: .leading))
    }

    var storageLocationTitle: String {
        selectedStorageLocationCount == 1 ? "Storage Location" : "Storage Locations"
    }

    var storageLocationSelectionTint: Color {
        unavailableSelectedStorageLocationCount > 0 ? .orange : .green
    }

    var storageLocationsVerticalPadding: CGFloat {
        if showStorageLocations {
            return 10
        }

        return storageLocationsManager.locations.isEmpty ? 4 : 6
    }

    var storageLocationListIDs: [StorageLocation.ID] {
        storageLocationsManager.locations.map(\.id)
    }

    var storageLocationInsertionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.32, dampingFraction: 0.84)
    }

    var storageLocationRowTransition: AnyTransition {
        .opacity
    }

    var addStorageLocationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { addStorageLocationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    addStorageLocationErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        WorkflowContainer(currentStep: .configure) {
            // Compact header
            VStack(spacing: 16) {
                iconSection
                ReadyToOrganizeTitle(
                    mode: mode,
                    showsWorkflowPicker: appState.showsFinderWorkflowPicker,
                    onSelectMode: selectWorkflow
                )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.96)
            .offset(y: hasAppeared ? 0 : 8)
            .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.04), value: hasAppeared)

            // Instructions card
            WorkflowCard(title: "Instructions", icon: "text.bubble") {
                instructionsContent
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.10), value: hasAppeared)

            if mode != .renameOnly {
                WorkflowCard(verticalPadding: storageLocationsVerticalPadding) {
                    storageLocationsContent
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
                .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.16), value: hasAppeared)
            }

            ReadyToOrganizeStartButton(
                mode: mode,
                isConnecting: isConnecting,
                hasAppeared: hasAppeared,
                reduceMotion: reduceMotion,
                compression: startCTACompression,
                onStart: runStartCTAAnimation
            )

            ReadyToOrganizeKeyboardHint(
                actionVerb: mode.actionVerb,
                isConnecting: isConnecting,
                hasAppeared: hasAppeared,
                reduceMotion: reduceMotion
            )

            // Connection status indicator
            connectionStatusView
                .opacity(hasAppeared ? 1 : 0)
                .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.32), value: hasAppeared)
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderImport(result)
        }
        .alert(
            "Couldn't Add Storage Location",
            isPresented: addStorageLocationErrorIsPresented
        ) {
            Button("OK", role: .cancel) {
                addStorageLocationErrorMessage = nil
            }
        } message: {
            Text(addStorageLocationErrorMessage ?? "Please try selecting the folder again.")
        }
        .onAppear(perform: prepareForDisplay)
        .onChange(of: appState.selectedDirectory) { _, _ in
            scheduleReferenceableFilesRefresh()
        }
        .onDisappear(perform: stopReferenceRefresh)
    }

    func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                HapticFeedbackManager.shared.success()
                do {
                    try withAnimation(storageLocationInsertionAnimation) {
                        try storageLocationsManager.addLocation(
                            url: url,
                            customName: suggestedLocationName
                        )
                    }
                } catch {
                    HapticFeedbackManager.shared.error()
                    addStorageLocationErrorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            HapticFeedbackManager.shared.error()
            addStorageLocationErrorMessage = error.localizedDescription
        }
        suggestedLocationName = nil
    }

    func prepareForDisplay() {
        scheduleReferenceableFilesRefresh()
        Task { await storageLocationsManager.refreshAccessStatus() }

        guard !hasAppeared else { return }
        guard !appState.hasPresentedReadyToOrganize else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hasAppeared = true
            }
            return
        }

        appState.hasPresentedReadyToOrganize = true
        hasAppeared = true
    }

    func stopReferenceRefresh() {
        referenceRefreshTask?.cancel()
        referenceRefreshTask = nil
    }

    func runStartCTAAnimation() {
        HapticFeedbackManager.shared.tap()
        guard !reduceMotion else {
            onStart()
            return
        }

        withAnimation(.spring(response: 0.18, dampingFraction: 0.56)) {
            startCTACompression = 1
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            onStart()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                startCTACompression = 0
            }
        }
    }

    func selectWorkflow(_ selectedMode: OrganizationMode) {
        guard selectedMode != mode else { return }
        HapticFeedbackManager.shared.selection()
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6)) {
            if selectedMode != .organize {
                settingsViewModel.config.enableSmartRename = true
            }
            settingsViewModel.config.mode = selectedMode
        }
    }

    func toggleStorageLocations() {
        HapticFeedbackManager.shared.selection()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            showStorageLocations.toggle()
        }
    }

    @ViewBuilder
    var iconSection: some View {
        if let image = SortyResources.image(named: "ReadyToOrganizeIcon") {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(Circle())
                .accessibilityLabel("Sorty is ready to \(mode.actionVerb.lowercased())")
        } else {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 104, height: 104)
                .accessibilityLabel("Sorty is ready to \(mode.actionVerb.lowercased())")
        }
    }

    @ViewBuilder
    var connectionStatusView: some View {
        HStack(spacing: 6) {
            if sessionManager.prewarmingProvider != nil {
                SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                    .frame(width: 12, height: 12)
                Text("Connecting to \(settingsViewModel.config.provider.displayName)...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if sessionManager.isPrewarmed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Connected to \(settingsViewModel.config.provider.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let error = sessionManager.prewarmError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Connection warning: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(minHeight: 16)
        .help(sessionManager.prewarmError ?? "Current AI connection state")
        .accessibilityLabel("Connection status")
        .accessibilityHint("Shows whether Sorty can reach the selected AI provider")
    }


}

