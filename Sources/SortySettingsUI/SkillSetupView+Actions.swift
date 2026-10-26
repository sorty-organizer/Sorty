import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import SortyFileSystem

// MARK: - Actions
extension SkillSetupView {
    var primaryTitle: String {
        switch step {
        case .rethink: "Meet the Skill"
        case .about: "Continue"
        case .welcome: "Get Started"
        case .location, .preferences: "Continue"
        case .review:
            if selected.isEmpty {
                if case .installed = installer.state { "Finish Setup" }
                else { "Install Skill" }
            } else if case .installed = installer.state { "Import Settings" }
            else { "Install and Import" }
        case .complete: "Done"
        }
    }

    var selectedOptions: [SkillImportOption] {
        options.filter { selected.contains($0.selectionID) }
    }

    var allSelected: Bool {
        !options.isEmpty && options.allSatisfy { selected.contains($0.selectionID) }
    }

    var isCheckingLocation: Bool {
        switch installer.state {
        case .checking, .installing, .replacing, .removing: true
        default: false
        }
    }

    var canUseLocation: Bool {
        !isCheckingLocation && installer.state != .unavailable
    }

    var exampleRequest: String {
        "Use the Sorty skill to preview how you'd organize my Downloads folder with my preferences."
    }

    func closeWithFeedback() {
        HapticFeedbackManager.shared.tap()
        onClose()
    }

    func changeStep(_ next: Step) {
        HapticFeedbackManager.shared.selection()
        if next == .review { hasReachedReviewBottom = false }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            introductionStage = 0
            step = next
        }
    }

    func advance() {
        switch step {
        case .rethink: changeStep(.about)
        case .about: changeStep(.welcome)
        case .welcome: changeStep(.location)
        case .location: changeStep(.preferences)
        case .preferences: changeStep(.review)
        case .review:
            guard hasReachedReviewBottom else { return }
            if installer.state == .conflict {
                HapticFeedbackManager.shared.tap()
                isConfirmingReplacement = true
            } else {
                importSelected()
            }
        case .complete: closeWithFeedback()
        }
    }

    func loadOptions() async {
        async let settingsLoad: Void = settings.loadPersistedState()
        async let exclusionsLoad: Void = exclusions.loadPersistedState()
        async let foldersLoad: Void = watchedFolders.loadPersistedState()
        _ = await (settingsLoad, exclusionsLoad, foldersLoad)
        guard !Task.isCancelled else { return }
        refreshOptions()
        hasLoadedOptions = true
        isLoading = false
    }

    func refreshOptions() {
        do {
            options = try SkillImportOption.options(
                config: settings.config, openFolder: automation.autoSelectOrganizedFolders,
                exclusions: exclusions.rules, exceptions: exclusions.naturalLanguageExceptions,
                folders: watchedFolders.folders, learnings: learnings.isLocked ? nil : learnings.currentProfile
            )
        } catch { errorMessage = error.userFacingMessage }
    }

    func toggleAll() {
        Task {
            if allSelected { selected.removeAll() }
            else {
                if learnings.isLocked || learnings.currentProfile == nil { await unlockLearnings() }
                selected = Set(options.map(\.selectionID))
            }
            HapticFeedbackManager.shared.selection()
        }
    }

    func unlockLearnings() async {
        isLoading = true
        defer { isLoading = false }
        guard await SecurityManager.shared.authenticateForSensitiveAction(reason: "Authenticate to import your Learnings into the skill.") else { return }
        await learnings.unlock()
        refreshOptions()
        if let error = learnings.error { errorMessage = error }
    }

    func chooseLocation() {
        HapticFeedbackManager.shared.tap()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = installer.destinationURL.deletingLastPathComponent()
        panel.message = "Choose the folder where your agent loads skills. Sorty creates a sorty folder inside it."
        panel.prompt = "Choose Skills Folder"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        HapticFeedbackManager.shared.selection()
        installer.selectedSkillsDirectory = directory
        customFolderIcon = NSWorkspace.shared.icon(forFile: directory.path)
        errorMessage = nil
        Task { await installer.refresh(trackUsage: false, showsCheckingState: false) }
    }

    func importSelected() {
        guard step == .review, hasReachedReviewBottom, !isLoading, !isSaving,
              canUseLocation else { return }
        HapticFeedbackManager.shared.tap()
        isSaving = true
        onSavingChanged(true)
        errorMessage = nil
        Task { @MainActor in
            defer {
                if isSaving {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isSaving = false
                        importProgressDeadline = nil
                    }
                }
                onSavingChanged(false)
            }
            if selectedOptions.contains(where: { $0.section == .learnings }) {
                guard await SecurityManager.shared.authenticateForSensitiveAction(reason: "Authenticate to import your Learnings into the skill.") else { return }
            }
            if installer.state == .conflict {
                await installer.replace()
            } else if installer.state == .available || installer.state == .failed {
                await installer.install()
            }
            guard case .installed = installer.state else {
                errorMessage = "The skill couldn't be installed here. Go back to check the location, then try again."
                HapticFeedbackManager.shared.error()
                return
            }
            do {
                if !selected.isEmpty {
                    try await installer.importSettings(options: options, selected: selected)
                } else {
                    HapticFeedbackManager.shared.success()
                }
                if let importProgressDeadline {
                    try await ContinuousClock().sleep(until: importProgressDeadline)
                }
                AccessibilityNotification.Announcement("Your Sorty skill is ready").post()
                if !isOnboarding, let sound = NSSound(named: "Glass") {
                    sound.volume = 0.20
                    sound.play()
                }
                // Reveal the ready page and dismiss progress in one animated update.
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    step = .complete
                    isSaving = false
                    importProgressDeadline = nil
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.userFacingMessage
                HapticFeedbackManager.shared.error()
            }
        }
    }
}
