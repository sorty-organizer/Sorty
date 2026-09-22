import Combine
import Foundation
import SwiftUI

public enum MenuBarActivity: String, CaseIterable, Sendable {
    case idle
    case greeting
    case organizing
    case renaming
    case watchedFolder
    case duplicateScanning
    case learning

    var resourceName: String {
        switch self {
        case .idle: "SortyMenuIdle"
        case .greeting: "SortyMenuGreeting"
        case .organizing: "SortyMenuOrganizing"
        case .renaming: "SortyMenuRenaming"
        case .watchedFolder: "SortyMenuWatchedFolder"
        case .duplicateScanning: "SortyMenuDuplicateScanning"
        case .learning: "SortyMenuLearning"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Sorty"
        case .greeting: "Sorty says hi"
        case .organizing: "Sorty is organizing"
        case .renaming: "Sorty is renaming"
        case .watchedFolder: "Sorty is organizing a watched folder"
        case .duplicateScanning: "Sorty is scanning for duplicates"
        case .learning: "Sorty is learning"
        }
    }
}

@MainActor
public final class MenuBarController: ObservableObject {
    private struct ActiveOperation {
        let activity: MenuBarActivity
        let order: UInt64
    }

    @Published public private(set) var activity: MenuBarActivity = .idle

    private var activeOperations: [String: ActiveOperation] = [:]
    private var nextActivityOrder: UInt64 = 0
    private var greetingResetTask: Task<Void, Never>?
    private var automationActivitySubscription: AnyCancellable?
    private var learningActivitySubscription: AnyCancellable?

    public init() {}

    public func configure(
        settings: SettingsViewModel,
        automationOrganizer: FolderOrganizer? = nil,
        learningsManager: LearningsManager? = nil
    ) {
        if let automationOrganizer {
            automationActivitySubscription = Publishers.CombineLatest(
                automationOrganizer.statePublisher,
                settings.$config
            )
            .removeDuplicates(by: { previous, next in
                previous.0 == next.0 && previous.1 == next.1
            })
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] state, config in
                self?.updateOrganizationActivity(
                    state: state,
                    mode: config.mode,
                    sourceID: "global.watched-folder",
                    isWatchedFolder: true
                )
            }
        }

        if let learningsManager {
            learningActivitySubscription = learningsManager.analyzer.$isAnalyzing
                .removeDuplicates()
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .sink { [weak self] isAnalyzing in
                    self?.setActivity(
                        isAnalyzing ? .learning : nil,
                        sourceID: "global.learning"
                    )
                }
        }
    }

    public func updateOrganizationActivity(
        state: OrganizationState,
        mode: OrganizationMode,
        sourceID: String,
        isWatchedFolder: Bool = false
    ) {
        let isWorking: Bool
        switch state {
        case .scanning, .organizing, .applying:
            isWorking = true
        case .idle, .ready, .completed, .error:
            isWorking = false
        }

        guard isWorking else {
            setActivity(nil, sourceID: sourceID)
            return
        }

        if isWatchedFolder {
            setActivity(.watchedFolder, sourceID: sourceID)
        } else if mode == .renameOnly {
            setActivity(.renaming, sourceID: sourceID)
        } else {
            setActivity(.organizing, sourceID: sourceID)
        }
    }

    public func setActivity(_ activity: MenuBarActivity?, sourceID: String) {
        guard let activity else {
            guard activeOperations.removeValue(forKey: sourceID) != nil else { return }
            refreshActivity()
            return
        }

        guard activeOperations[sourceID]?.activity != activity else { return }
        nextActivityOrder &+= 1
        activeOperations[sourceID] = ActiveOperation(
            activity: activity,
            order: nextActivityOrder
        )
        refreshActivity()
    }

    public func showGreeting(
        for duration: Duration = .seconds(NotificationManager.transientHUDDuration)
    ) {
        let sourceID = "interaction.open-menu"
        greetingResetTask?.cancel()
        activeOperations.removeValue(forKey: sourceID)
        setActivity(.greeting, sourceID: sourceID)

        greetingResetTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.setActivity(nil, sourceID: sourceID)
        }
    }

    private func refreshActivity() {
        let nextActivity = activeOperations.values
            .max(by: { $0.order < $1.order })?
            .activity ?? .idle
        guard activity != nextActivity else { return }
        activity = nextActivity
    }
}
