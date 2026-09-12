//
//  LearningsManager.swift
//  Sorty
//
//  Observable manager coordinating all learnings functionality
//  Enhanced with secure storage, consent management, and behavior tracking
//

import Foundation
import CryptoKit
import SwiftUI
import Combine

public enum LearningExclusionReviewTarget: String, Codable, Sendable {
    case instructions
    case persona
    case watchedFolder
}

public struct LearningExclusionConcern: Equatable, Sendable {
    public let excludedRunCount: Int
    public let evaluatedRunCount: Int
    public let reviewTarget: LearningExclusionReviewTarget
}

public enum ReferenceDirectoryScanState: Equatable, Sendable {
    case scanning
    case ready
    case warning(String)
    case failed(String)
    case unavailable
    case paused
}

enum ReferenceDirectoryAddResult: Equatable {
    case added
    case duplicate
    case activeLimitReached
}

struct ReferenceDirectorySelection: Equatable, Sendable {
    let directoryIDs: [String]
    let reason: String
    let context: String
}

@MainActor
public final class LearningExclusionMonitor {
    private struct Event: Codable {
        let timestamp: Date
        let wasExcluded: Bool
        let reviewTarget: LearningExclusionReviewTarget
    }

    public static let shared = LearningExclusionMonitor()

    private let userDefaults: UserDefaults
    private let eventsKey = "learningToolDecisionEvents"
    private let lastAlertKey = "learningToolDecisionLastAlert"

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func recordDecision(
        wasExcluded: Bool,
        reviewTarget: LearningExclusionReviewTarget,
        now: Date = Date()
    ) -> LearningExclusionConcern? {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        var events = loadEvents()
            .filter { $0.timestamp >= cutoff }
        events.append(
            Event(
                timestamp: now,
                wasExcluded: wasExcluded,
                reviewTarget: reviewTarget
            )
        )
        events = Array(events.suffix(20))
        saveEvents(events)

        let evaluated = Array(events.suffix(10))
        let excluded = evaluated.filter(\.wasExcluded)
        guard evaluated.count >= 5,
              excluded.count >= 3,
              Double(excluded.count) / Double(evaluated.count) >= 0.3 else { return nil }

        if let lastAlert = userDefaults.object(forKey: lastAlertKey) as? Date,
           now.timeIntervalSince(lastAlert) < 7 * 24 * 60 * 60 {
            return nil
        }

        userDefaults.set(now, forKey: lastAlertKey)
        let target = Dictionary(grouping: excluded, by: \.reviewTarget)
            .max { $0.value.count < $1.value.count }?
            .key ?? reviewTarget
        return LearningExclusionConcern(
            excludedRunCount: excluded.count,
            evaluatedRunCount: evaluated.count,
            reviewTarget: target
        )
    }

    private func loadEvents() -> [Event] {
        guard let data = userDefaults.data(forKey: eventsKey) else { return [] }
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }

    private func saveEvents(_ events: [Event]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        userDefaults.set(data, forKey: eventsKey)
    }
}

/// Main manager for "The Learnings" feature
@MainActor
public class LearningsManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published public var currentProfile: LearningsProfile?
    @Published public var isLoading: Bool = false
    @Published public var error: String?
    @Published public var analysisResult: LearningsAnalysisResult?
    
    // Security & Consent
    @Published public var isLocked: Bool = false
    @Published public var requiresInitialSetup: Bool = false
    @Published public var showingImportPicker: Bool = false
    public let securityManager = SecurityManager.shared
    public let consentManager: LearningsConsentManager
    
    // Learning Controls
    @Published public var learningStrength: Double = 0.5 {
        didSet {
            userDefaults.set(learningStrength, forKey: "learningStrength")
        }
    }
    /// Learnings analysis always uses the configured AI provider.
    public let useAIForLearnings = true
    @Published public var sessionLearningPaused: Bool = false
    @Published public var modelDirectories: [ReferenceModelDirectory] = []
    @Published public private(set) var modelDirectoryScanStates: [String: ReferenceDirectoryScanState] = [:]
    private var activeModelDirectoryURLs: [String: URL] = [:]
    @Published public private(set) var learningsModelSelection: LearningsModelSelection?

    /// Suggestions for files that should be added to exceptions (e.g., related project files)
    @Published public var pendingExceptionSuggestions: [ExceptionSuggestion] = []

    public struct ExceptionSuggestion: Identifiable {
        public let id = UUID()
        public let message: String
        public let fileNames: [String]
        public let groupName: String
    }
    
    @Published public var dataRetentionDays: Int = 0 {
        didSet {
            userDefaults.set(dataRetentionDays, forKey: "learningDataRetentionDays")
            guard dataRetentionDays != oldValue else { return }
            Task { await applyDataRetentionPolicy() }
        }
    }
    
    // MARK: - Learnings Summary for UI
    
    /// A summary of the learnings state for UI consumption
    public struct LearningsSummary: Sendable {
        /// The overall state of learnings
        public enum State: String, Sendable {
            case noConsent      // User hasn't granted consent
            case locked         // Learnings exist but access is locked
            case paused         // Learning collection is temporarily paused
            case empty          // Consent granted but no data yet
            case building       // Some data, but still learning
            case established    // Rich learnings profile available
        }
        
        /// Profile maturity level for adaptive UX
        public enum Maturity: String, Sendable {
            case new            // < 3 sessions
            case growing        // 3-10 sessions
            case established    // > 10 sessions with rules
        }
        
        public let state: State
        public let maturity: Maturity
        public let sessionCount: Int
        public let activeRuleCount: Int
        public let recentSessionCount: Int // Sessions in last 7 days
        public let hasActiveRules: Bool
        public let statusText: String
        public let shortStatusText: String
        
        /// Whether learnings are actively contributing to organization
        public var isActive: Bool {
            state == .building || state == .established
        }
        
        /// Whether the badge should be visible in the UI
        public var shouldShowBadge: Bool {
            state != .noConsent
        }
        
        /// Whether feedback controls should be enabled
        public var canProvideFeedback: Bool {
            state != .noConsent && state != .locked && state != .paused
        }
    }
    
    /// Computed summary for UI display - updated reactively when profile changes
    public var summary: LearningsSummary {
        computeSummary()
    }
    
    private func computeSummary() -> LearningsSummary {
        // Check consent first
        guard consentManager.canCollectData else {
            return LearningsSummary(
                state: .noConsent,
                maturity: .new,
                sessionCount: 0,
                activeRuleCount: 0,
                recentSessionCount: 0,
                hasActiveRules: false,
                statusText: "Learning disabled",
                shortStatusText: "Off"
            )
        }
        
        // Check locked state
        if isLocked && consentManager.hasCompletedInitialSetup {
            return LearningsSummary(
                state: .locked,
                maturity: .new,
                sessionCount: 0,
                activeRuleCount: 0,
                recentSessionCount: 0,
                hasActiveRules: false,
                statusText: "Learnings locked",
                shortStatusText: "Locked"
            )
        }
        
        // Check paused state
        if sessionLearningPaused {
            let profile = currentProfile
            let sessionCount = profile?.sessions.count ?? 0
            let activeRuleCount = profile?.inferredRules.filter { $0.isEnabled && $0.status == .active }.count ?? 0
            let weekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let recentSessionCount = profile?.sessions.filter { ($0.completedAt ?? $0.timestamp) > weekAgo }.count ?? 0
            return LearningsSummary(
                state: .paused,
                maturity: computeMaturity(sessionCount: sessionCount, ruleCount: activeRuleCount),
                sessionCount: sessionCount,
                activeRuleCount: activeRuleCount,
                recentSessionCount: recentSessionCount,
                hasActiveRules: activeRuleCount > 0,
                statusText: activeRuleCount > 0 ? "Learning paused (\(activeRuleCount) active pattern\(activeRuleCount == 1 ? "" : "s"))" : "Learning paused",
                shortStatusText: "Paused"
            )
        }
        
        // Profile-based states
        guard let profile = currentProfile else {
            return LearningsSummary(
                state: .empty,
                maturity: .new,
                sessionCount: 0,
                activeRuleCount: 0,
                recentSessionCount: 0,
                hasActiveRules: false,
                statusText: "Ready to learn",
                shortStatusText: "Ready"
            )
        }
        
        let sessionCount = profile.sessions.count
        let activeRules = profile.inferredRules.filter { $0.isEnabled && $0.status == .active }
        let activeRuleCount = activeRules.count
        
        // Count recent sessions (last 7 days)
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let recentSessionCount = profile.sessions.filter { ($0.completedAt ?? $0.timestamp) > weekAgo }.count
        
        let maturity = computeMaturity(sessionCount: sessionCount, ruleCount: activeRuleCount)
        
        // Determine state based on data richness
        let state: LearningsSummary.State
        let statusText: String
        let shortStatusText: String
        
        if sessionCount == 0 {
            state = .empty
            statusText = "Ready to learn from your organization"
            shortStatusText = "Ready"
        } else if activeRuleCount == 0 && sessionCount < 5 {
            state = .building
            let remaining = 5 - sessionCount
            statusText = "Learning... \(remaining) more session\(remaining == 1 ? "" : "s") to build patterns"
            shortStatusText = "Learning"
        } else {
            state = .established
            if activeRuleCount > 0 {
                statusText = "\(activeRuleCount) learned pattern\(activeRuleCount == 1 ? "" : "s") active"
                shortStatusText = "\(activeRuleCount) pattern\(activeRuleCount == 1 ? "" : "s")"
            } else {
                statusText = "\(sessionCount) session\(sessionCount == 1 ? "" : "s") learned"
                shortStatusText = "\(sessionCount) session\(sessionCount == 1 ? "" : "s")"
            }
        }
        
        return LearningsSummary(
            state: state,
            maturity: maturity,
            sessionCount: sessionCount,
            activeRuleCount: activeRuleCount,
            recentSessionCount: recentSessionCount,
            hasActiveRules: activeRuleCount > 0,
            statusText: statusText,
            shortStatusText: shortStatusText
        )
    }
    
    private func computeMaturity(sessionCount: Int, ruleCount: Int) -> LearningsSummary.Maturity {
        if sessionCount < 3 {
            return .new
        } else if sessionCount < 10 || ruleCount == 0 {
            return .growing
        } else {
            return .established
        }
    }
    
    // MARK: - Dependencies
    
    private let userDefaults: UserDefaults
    private let persistedDataReader: UserDefaultsDataReader
    public let analyzer = LearningsAnalyzer()
    
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.persistedDataReader = UserDefaultsDataReader(userDefaults)
        self.consentManager = LearningsConsentManager(userDefaults: userDefaults)
        requiresInitialSetup = !consentManager.hasCompletedInitialSetup
        learningStrength = userDefaults.object(forKey: "learningStrength") as? Double ?? 0.5
        dataRetentionDays = userDefaults.integer(forKey: "learningDataRetentionDays")
        userDefaults.removeObject(forKey: "useAIForLearnings")
    }

    private struct PersistedState: Sendable {
        let modelSelection: LearningsModelSelection?
        let modelDirectories: [ReferenceModelDirectory]
    }

    private struct ModelDirectoryBookmarkSnapshot: Sendable {
        let id: String
        let bookmarkData: Data?
        let path: String
    }

    private struct ModelDirectoryBookmarkResult: Sendable {
        let id: String
        let originalBookmark: Data?
        let resolvedURL: URL?
        let renewedBookmark: Data?
        let didAccess: Bool
        let isAccessible: Bool
    }

    private var hasLoadedPersistedState = false
    private var persistedStateLoadTask: Task<PersistedState, Never>?
    private var persistedStateLoadGeneration = 0
    private var modelDirectoryRestoreTask: Task<Void, Never>?
    private var modelDirectoryGeneration = 0
    private var hasPendingModelSelectionChange = false
    private var hasPendingModelDirectoryChanges = false

    /// Loads the model selection and reference-model directories after launch.
    /// Directory loading resolves security-scoped bookmarks and stats each
    /// directory on disk, which is too slow for app construction, so callers
    /// run this once the first window is up (see `configureGlobalsIfNeeded`).
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = persistedStateLoadGeneration
        let task: Task<PersistedState, Never>
        if let persistedStateLoadTask {
            task = persistedStateLoadTask
        } else {
            let reader = persistedDataReader
            let modelSelectionKey = Self.learningsModelSelectionKey
            let modelDirectoriesKey = Self.modelDirectoriesKey
            task = Task.detached(priority: .userInitiated) {
                let selection = reader.data(forKey: modelSelectionKey)
                    .flatMap { try? JSONDecoder().decode(LearningsModelSelection.self, from: $0) }
                let directories = reader.data(forKey: modelDirectoriesKey)
                    .flatMap { try? JSONDecoder().decode([ReferenceModelDirectory].self, from: $0) } ?? []
                return PersistedState(modelSelection: selection, modelDirectories: directories)
            }
            persistedStateLoadTask = task
        }

        let persistedState = await task.value
        guard !hasLoadedPersistedState,
              generation == persistedStateLoadGeneration else { return }

        if learningsModelSelection == nil {
            learningsModelSelection = persistedState.modelSelection
        }
        var seenIDs: Set<String> = []
        var seenPaths: Set<String> = []
        modelDirectories = (persistedState.modelDirectories + modelDirectories).filter { directory in
            seenIDs.insert(directory.id).inserted
                && seenPaths.insert(directory.canonicalPath).inserted
        }
        hasLoadedPersistedState = true
        persistedStateLoadTask = nil

        if hasPendingModelSelectionChange {
            hasPendingModelSelectionChange = false
            saveLearningsModelSelection()
        }
        if hasPendingModelDirectoryChanges {
            hasPendingModelDirectoryChanges = false
            saveModelDirectories()
        }

        await restoreModelDirectoryAccess()
        let legacyIDs = modelDirectories.compactMap { directory in
            directory.scanSnapshot?.needsRescan == true ? directory.id : nil
        }
        for id in legacyIDs {
            Task { await rescanModelDirectory(id: id) }
        }
    }
    
    public func configure(with config: AIConfig) {
        do {
            let client = try AIClientFactory.createClient(config: effectiveAIConfig(from: config))
            analyzer.configure(aiClient: client)
        } catch {
            self.error = "Failed to configure AI: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Security & Authentication
    
    /// Unlock with Touch ID / password (required after initial setup)
    public func unlock() async {
        isLocked = false
        await loadProfile()
    }
    
    public func lock() {
        securityManager.lock()
        isLocked = true
        currentProfile = nil
        analysisResult = nil
    }
    
    /// Complete initial setup - future access will require Touch ID
    public func completeInitialSetup() {
        consentManager.completeInitialSetup()
        requiresInitialSetup = false
    }
    
    // MARK: - Consent Management
    
    /// Grant consent for data collection
    public func grantConsent() async {
        consentManager.grantConsent()
        
        loadProfileIfNeededForCollection()
        if var profile = currentProfile {
            profile.consentGranted = true
            profile.consentDate = Date()
            currentProfile = profile
            await saveProfile()
        }
    }
    
    /// Withdraw consent
    public func withdrawConsent() async {
        consentManager.withdrawConsent()
        
        if var profile = currentProfile {
            profile.consentGranted = false
            currentProfile = profile
            await saveProfile()
        }
    }
    
    /// Delete all learning data securely.
    /// - Returns: `true` when data was deleted, `false` when the operation could not run.
    @discardableResult
    public func clearAllData() async -> Bool {
        do {
            try await consentManager.deleteAllData()

            currentProfile = nil
            analysisResult = nil
            pendingExceptionSuggestions = []
            sessionLearningPaused = false
            showingImportPicker = false
            isLocked = false
            requiresInitialSetup = true
            learningsModelSelection = nil
            persistedStateLoadGeneration &+= 1
            persistedStateLoadTask?.cancel()
            persistedStateLoadTask = nil
            modelDirectoryGeneration &+= 1
            modelDirectoryRestoreTask?.cancel()
            modelDirectoryRestoreTask = nil
            hasPendingModelSelectionChange = false
            hasPendingModelDirectoryChanges = false
            stopAllModelDirectoryAccess()
            modelDirectories = []
            modelDirectoryScanStates = [:]
            learningStrength = 0.5
            dataRetentionDays = 0

            [
                "learningStrength",
                "learningDataRetentionDays",
                Self.learningsModelSelectionKey,
                Self.modelDirectoriesKey,
                "lastLocalRuleInference",
            ].forEach(userDefaults.removeObject(forKey:))

            return true
        } catch {
            ReliabilityManager.shared.capture(
                error: error,
                feature: "learnings",
                operation: "clear_data",
                recoverable: false
            )
            self.error = "Failed to clear data: \(error.localizedDescription)"
            return false
        }
    }
    
    // MARK: - Secure Profile Storage
    
    private func loadProfile() async {
        let loadStartedAt = Date()
        var loadOutcome = "success"
        isLoading = true
        do {
            if let profile = try LearningsFileManager.load() {
                currentProfile = prepareLoadedProfile(profile)
            } else {
                currentProfile = prepareLoadedProfile(LearningsProfile())
            }
        } catch {
            loadOutcome = "failed"
            ReliabilityManager.shared.capture(
                error: error,
                feature: "learnings",
                operation: "load_profile"
            )
            self.error = "Failed to load profile: \(error.localizedDescription)"
            currentProfile = prepareLoadedProfile(LearningsProfile())
        }
        isLoading = false
        AnalyticsManager.shared.captureWorkflow(
            workflow: "learnings_profile",
            stage: "loaded",
            outcome: loadOutcome,
            properties: AnalyticsManager.durationProperties(
                Date().timeIntervalSince(loadStartedAt)
            )
        )
    }
    
    /// Load profile synchronously for background collection (without authentication)
    /// This allows data collection to work even when the UI is locked
    public func loadProfileIfNeededForCollection() {
        guard currentProfile == nil else { return }
        
        do {
            if let profile = try LearningsFileManager.load() {
                currentProfile = prepareLoadedProfile(profile)
            } else {
                currentProfile = prepareLoadedProfile(LearningsProfile())
            }
        } catch {
            ReliabilityManager.shared.capture(
                error: error,
                feature: "learnings",
                operation: "load_profile_for_collection"
            )
            self.error = "Failed to load profile: \(error.localizedDescription)"
            currentProfile = prepareLoadedProfile(LearningsProfile())
        }
    }
    
    private func saveProfile() async {
        guard let profile = currentProfile else { return }
        
        // Prune before saving to keep file size manageable
        pruneOldData()
        
        do {
            try LearningsFileManager.save(profile: currentProfile ?? profile)
        } catch {
            ReliabilityManager.shared.capture(
                error: error,
                feature: "learnings",
                operation: "save_profile"
            )
            self.error = "Failed to save profile: \(error.localizedDescription)"
        }
    }

    private func prepareLoadedProfile(_ profile: LearningsProfile) -> LearningsProfile {
        var prepared = migrateLegacySessionsIfNeeded(in: profile)
        pruneOldData(in: &prepared)
        return prepared
    }

    public func upsertOrganizationSession(_ session: OrganizationSession) {
        guard consentManager.canCollectData else { return }
        guard !isPathExcludedFromLearning(session.folderPath) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }

        upsertOrganizationSession(&profile, session: session)
        currentProfile = profile
        debouncedSave()
    }

    public func discardOrganizationSession(id: String) {
        guard var profile = currentProfile else { return }
        let originalCount = profile.sessions.count
        profile.sessions.removeAll { $0.id == id }
        guard profile.sessions.count != originalCount else { return }
        currentProfile = profile
        debouncedSave()
    }

    public nonisolated static func instructionsExcludeCurrentRun(_ instructions: String?) -> Bool {
        guard let instructions else { return false }

        let normalized = String(instructions
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " "))

        let subjects = [
            "this organization",
            "this organisation",
            "this run",
            "this rename",
            "this watched folder run",
            "this watched folder organization",
            "this watched folder organisation",
        ]

        return subjects.contains { subject in
            normalized.contains("dont learn from \(subject)")
                || normalized.contains("do not learn from \(subject)")
                || normalized.contains("skip learning for \(subject)")
                || normalized.contains("exclude \(subject) from learning")
                || normalized.contains("do not use \(subject) for learning")
                || normalized.contains("dont use \(subject) for learning")
        }
    }

    private func upsertOrganizationSession(_ profile: inout LearningsProfile, session: OrganizationSession) {
        if let index = profile.sessions.firstIndex(where: { $0.id == session.id }) {
            profile.sessions[index] = session
        } else {
            profile.sessions.append(session)
        }
        profile.sessions.sort { lhs, rhs in
            let lhsDate = lhs.completedAt ?? lhs.timestamp
            let rhsDate = rhs.completedAt ?? rhs.timestamp
            return lhsDate > rhsDate
        }
    }

    private func mutateSession(
        in profile: inout LearningsProfile,
        sessionId: String? = nil,
        folderPath: String? = nil,
        timestamp: Date = Date(),
        createIfMissing: Bool = true,
        mutation: (inout OrganizationSession) -> Void
    ) {
        if let sessionId, let index = profile.sessions.firstIndex(where: { $0.id == sessionId }) {
            mutation(&profile.sessions[index])
            return
        }

        if let folderPath, let index = bestMatchingSessionIndex(in: profile.sessions, folderPath: folderPath, timestamp: timestamp) {
            mutation(&profile.sessions[index])
            return
        }

        guard createIfMissing, let folderPath else { return }
        var session = OrganizationSession(timestamp: timestamp, folderPath: folderPath)
        mutation(&session)
        upsertOrganizationSession(&profile, session: session)
    }

    private func bestMatchingSessionIndex(
        in sessions: [OrganizationSession],
        folderPath: String,
        timestamp: Date,
        maxDistance: TimeInterval = 6 * 60 * 60
    ) -> Int? {
        let normalizedFolder = URL(fileURLWithPath: folderPath).standardizedFileURL.path

        return sessions.enumerated()
            .filter { _, session in
                URL(fileURLWithPath: session.folderPath).standardizedFileURL.path == normalizedFolder
            }
            .filter { _, session in
                abs((session.completedAt ?? session.timestamp).timeIntervalSince(timestamp)) <= maxDistance
            }
            .sorted { lhs, rhs in
                let lhsDelta = abs((lhs.element.completedAt ?? lhs.element.timestamp).timeIntervalSince(timestamp))
                let rhsDelta = abs((rhs.element.completedAt ?? rhs.element.timestamp).timeIntervalSince(timestamp))
                return lhsDelta < rhsDelta
            }
            .map(\.offset)
            .first
    }

    private func migrateLegacySessionsIfNeeded(in profile: LearningsProfile) -> LearningsProfile {
        guard profile.sessions.isEmpty else { return profile }

        var migrated = profile
        var sessions: [OrganizationSession] = []

        func upsert(_ session: OrganizationSession) {
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = session
            } else {
                sessions.append(session)
            }
        }

        func appendEvent(
            folderPath: String,
            timestamp: Date,
            sessionId: String? = nil,
            createIfMissing: Bool = true,
            _ mutation: (inout OrganizationSession) -> Void
        ) {
            if let sessionId, let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                mutation(&sessions[index])
                return
            }

            if let index = bestMatchingSessionIndex(in: sessions, folderPath: folderPath, timestamp: timestamp) {
                mutation(&sessions[index])
                return
            }

            guard createIfMissing else { return }
            var session = OrganizationSession(timestamp: timestamp, folderPath: folderPath)
            mutation(&session)
            upsert(session)
        }

        for cancelled in profile.cancelledOrganizations {
            var session = OrganizationSession(
                timestamp: cancelled.timestamp,
                completedAt: cancelled.timestamp,
                folderPath: cancelled.folderPath,
                planSummary: cancelled.proposedStructureSummary,
                reaction: .cancelled,
                events: [
                    OrganizationSessionEvent(
                        timestamp: cancelled.timestamp,
                        kind: .cancelled,
                        summary: "Cancelled organization during \(cancelled.cancelledAtStage)"
                    )
                ]
            )
            if let instructions = cancelled.instructions, !instructions.isEmpty {
                session.additionalInstructions.append(
                    UserInstruction(
                        timestamp: cancelled.timestamp,
                        instruction: instructions,
                        context: "cancelled",
                        folderPath: cancelled.folderPath,
                        fileCount: cancelled.fileCount,
                        isRegeneration: false
                    )
                )
            }
            upsert(session)
        }

        for regenerated in profile.regeneratedOrganizations {
            let folderPath = regenerated.folderPath
            appendEvent(folderPath: folderPath, timestamp: regenerated.timestamp) { session in
                session.completedAt = max(session.completedAt ?? .distantPast, regenerated.timestamp)
                session.reaction = .regenerated
                if let guiding = regenerated.guidingInstruction, !guiding.isEmpty {
                    session.guidingInstructions.append(
                        UserInstruction(
                            timestamp: regenerated.timestamp,
                            instruction: guiding,
                            context: "regeneration",
                            folderPath: folderPath,
                            isRegeneration: true
                        )
                    )
                }
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: regenerated.timestamp,
                        kind: .regenerated,
                        summary: "Regenerated organization attempt #\(regenerated.regenerationCount)"
                    )
                )
            }
        }

        for change in profile.postOrganizationChanges.sorted(by: { $0.timestamp < $1.timestamp }) {
            let folderPath = sessionFolderPath(for: change)
            appendEvent(folderPath: folderPath, timestamp: change.timestamp, sessionId: change.aiSessionId) { session in
                session.userCorrections.append(change)
                session.reaction = session.wasReverted ? .reverted : .corrected
                session.timeToReaction = minNonNil(session.timeToReaction, change.timestamp.timeIntervalSince(session.timestamp))
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: change.timestamp,
                        kind: .correction,
                        summary: "User moved a file after organization",
                        sourcePath: change.originalPath,
                        destinationPath: change.newPath
                    )
                )
            }
        }

        for revert in profile.historyReverts {
            let folderPath = revert.folderPath ?? ""
            appendEvent(folderPath: folderPath, timestamp: revert.timestamp, createIfMissing: !folderPath.isEmpty) { session in
                session.wasReverted = true
                session.reaction = .reverted
                session.completedAt = max(session.completedAt ?? .distantPast, revert.timestamp)
                session.timeToReaction = minNonNil(session.timeToReaction, revert.timestamp.timeIntervalSince(session.timestamp))
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: revert.timestamp,
                        kind: .reverted,
                        summary: revert.reason ?? "Organization was reverted",
                        metadata: ["entryId": revert.entryId]
                    )
                )
            }
        }

        for prompt in profile.steeringPrompts {
            let folderPath = prompt.folderPath ?? inferredFolderPath(from: prompt.sessionId, sessions: sessions)
            guard let folderPath else { continue }
            appendEvent(folderPath: folderPath, timestamp: prompt.timestamp, sessionId: prompt.sessionId) { session in
                session.steeringPrompts.append(prompt.prompt)
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: prompt.timestamp,
                        kind: .steeringPrompt,
                        summary: prompt.prompt
                    )
                )
            }
        }

        for instruction in profile.additionalInstructionsHistory {
            guard let folderPath = instruction.folderPath else { continue }
            appendEvent(folderPath: folderPath, timestamp: instruction.timestamp) { session in
                session.additionalInstructions.append(instruction)
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: instruction.timestamp,
                        kind: .additionalInstruction,
                        summary: instruction.instruction
                    )
                )
            }
        }

        for instruction in profile.guidingInstructionsHistory {
            guard let folderPath = instruction.folderPath else { continue }
            appendEvent(folderPath: folderPath, timestamp: instruction.timestamp) { session in
                session.guidingInstructions.append(instruction)
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: instruction.timestamp,
                        kind: .guidingInstruction,
                        summary: instruction.instruction
                    )
                )
            }
        }

        for event in profile.renameFeedbackHistory {
            guard let folderPath = event.folderPath else { continue }
            appendEvent(folderPath: folderPath, timestamp: event.timestamp) { session in
                session.renameFeedback.append(event)
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: event.timestamp,
                        kind: .renameFeedback,
                        summary: "Rename feedback for \(event.originalName)"
                    )
                )
            }
        }

        for example in profile.positiveExamples.sorted(by: { $0.timestamp < $1.timestamp }) {
            let folderPath = sessionFolderPath(for: example)
            appendEvent(folderPath: folderPath, timestamp: example.timestamp) { session in
                session.completedAt = max(session.completedAt ?? .distantPast, example.timestamp)
                session.reaction = session.userCorrections.isEmpty && !session.wasReverted ? .accepted : session.reaction
                session.filesMoved.append(
                    OrganizationSessionMovedFile(
                        sourcePath: example.srcPath,
                        destinationPath: example.dstPath
                    )
                )
            }
        }

        for example in profile.corrections.sorted(by: { $0.timestamp < $1.timestamp }) {
            let folderPath = sessionFolderPath(for: example)
            appendEvent(folderPath: folderPath, timestamp: example.timestamp) { session in
                session.reaction = session.wasReverted ? .reverted : .corrected
                session.timeToReaction = minNonNil(session.timeToReaction, example.timestamp.timeIntervalSince(session.timestamp))
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: example.timestamp,
                        kind: .correction,
                        summary: "Manual correction learned",
                        sourcePath: example.srcPath,
                        destinationPath: example.dstPath
                    )
                )
            }
        }

        for example in profile.rejections.sorted(by: { $0.timestamp < $1.timestamp }) {
            let folderPath = sessionFolderPath(for: example)
            appendEvent(folderPath: folderPath, timestamp: example.timestamp) { session in
                session.reaction = session.wasReverted ? .reverted : .corrected
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: example.timestamp,
                        kind: .rejection,
                        summary: "Rejected suggested placement",
                        sourcePath: example.srcPath,
                        destinationPath: example.dstPath
                    )
                )
            }
        }

        sessions.sort { ($0.completedAt ?? $0.timestamp) > ($1.completedAt ?? $1.timestamp) }
        migrated.sessions = sessions
        return migrated
    }

    private func inferredFolderPath(from sessionId: String?, sessions: [OrganizationSession]) -> String? {
        guard let sessionId else { return nil }
        return sessions.first(where: { $0.id == sessionId })?.folderPath
    }

    private func sessionFolderPath(for change: DirectoryChange) -> String {
        let originalFolder = URL(fileURLWithPath: change.originalPath).deletingLastPathComponent().path
        let newFolder = change.newPath.isEmpty ? originalFolder : URL(fileURLWithPath: change.newPath).deletingLastPathComponent().path
        return commonAncestorPath([originalFolder, newFolder]) ?? originalFolder
    }

    private func sessionFolderPath(for example: LabeledExample) -> String {
        let sourceFolder = URL(fileURLWithPath: example.srcPath).deletingLastPathComponent().path
        let destinationFolder = URL(fileURLWithPath: example.dstPath).deletingLastPathComponent().path
        return commonAncestorPath([sourceFolder, destinationFolder]) ?? sourceFolder
    }

    private func commonAncestorPath(_ paths: [String]) -> String? {
        let components = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path.split(separator: "/").map(String.init) }
            .filter { !$0.isEmpty }

        guard let first = components.first else { return nil }
        var prefix: [String] = []

        for index in first.indices {
            let component = first[index]
            guard components.allSatisfy({ $0.indices.contains(index) && $0[index] == component }) else {
                break
            }
            prefix.append(component)
        }

        guard !prefix.isEmpty else { return "/" }
        return "/" + prefix.joined(separator: "/")
    }

    private func minNonNil(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case let (left?, right?):
            return min(left, right)
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Behavior Tracking
    
    /// Record additional instructions provided by user
    public func recordAdditionalInstruction(_ instruction: String, for folderPath: String, fileCount: Int? = nil) {
        guard consentManager.canCollectData else { return }
        guard !isPathExcludedFromLearning(folderPath) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let userInstruction = UserInstruction(
            instruction: instruction,
            context: "pre_organization",
            folderPath: folderPath,
            fileCount: fileCount,
            isRegeneration: false
        )
        profile.additionalInstructionsHistory.append(userInstruction)
        mutateSession(in: &profile, folderPath: folderPath, timestamp: userInstruction.timestamp) { session in
            session.additionalInstructions.append(userInstruction)
            session.events.append(
                OrganizationSessionEvent(
                    timestamp: userInstruction.timestamp,
                    kind: .additionalInstruction,
                    summary: instruction
                )
            )
        }
        currentProfile = profile
        Task { await saveProfile() }
    }
    
    /// Record guiding instructions for next attempt
    public func recordGuidingInstruction(_ instruction: String, for folderPath: String? = nil, fileCount: Int? = nil) {
        guard consentManager.canCollectData else { return }
        if let folderPath, isPathExcludedFromLearning(folderPath) { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let userInstruction = UserInstruction(
            instruction: instruction,
            context: "regeneration",
            folderPath: folderPath,
            fileCount: fileCount,
            isRegeneration: true
        )
        profile.guidingInstructionsHistory.append(userInstruction)
        if let folderPath {
            mutateSession(in: &profile, folderPath: folderPath, timestamp: userInstruction.timestamp) { session in
                session.guidingInstructions.append(userInstruction)
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: userInstruction.timestamp,
                        kind: .guidingInstruction,
                        summary: instruction
                    )
                )
            }
        }
        currentProfile = profile
        debouncedSave()
    }

    /// Record a cancelled organization session with rich context for learning
    public func recordCancelledOrganization(
        folderPath: String,
        fileCount: Int,
        proposedFolderCount: Int,
        instructions: String? = nil,
        stage: String,
        proposedFolderNames: [String]? = nil,
        proposedStructureSummary: String? = nil,
        fileExtensionCounts: [String: Int]? = nil,
        regenerationCount: Int = 0,
        regenerationInstructions: [String]? = nil,
        aiModel: String? = nil
    ) {
        guard consentManager.canCollectData else { return }
        guard !isPathExcludedFromLearning(folderPath) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let cancelled = CancelledOrganization(
            folderPath: folderPath,
            fileCount: fileCount,
            proposedFolderCount: proposedFolderCount,
            instructions: instructions,
            cancelledAtStage: stage,
            proposedFolderNames: proposedFolderNames,
            proposedStructureSummary: proposedStructureSummary,
            fileExtensionCounts: fileExtensionCounts,
            regenerationCount: regenerationCount,
            regenerationInstructions: regenerationInstructions,
            aiModel: aiModel
        )
        profile.cancelledOrganizations.append(cancelled)
        mutateSession(in: &profile, folderPath: folderPath, timestamp: cancelled.timestamp) { session in
            session.completedAt = cancelled.timestamp
            session.planSummary = proposedStructureSummary ?? session.planSummary
            session.reaction = .cancelled
            session.events.append(
                OrganizationSessionEvent(
                    timestamp: cancelled.timestamp,
                    kind: .cancelled,
                    summary: "Cancelled organization during \(stage)"
                )
            )
        }
        currentProfile = profile
        debouncedSave()
    }
    
    /// Record a regenerated organization session
    public func recordRegeneratedOrganization(folderPath: String, previousPlanSummary: String? = nil, guidingInstruction: String? = nil, regenerationCount: Int) {
        guard consentManager.canCollectData else { return }
        guard !isPathExcludedFromLearning(folderPath) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let regenerated = RegeneratedOrganization(
            folderPath: folderPath,
            previousPlanSummary: previousPlanSummary,
            guidingInstruction: guidingInstruction,
            regenerationCount: regenerationCount
        )
        profile.regeneratedOrganizations.append(regenerated)
        mutateSession(in: &profile, folderPath: folderPath, timestamp: regenerated.timestamp) { session in
            session.completedAt = regenerated.timestamp
            session.reaction = .regenerated
            session.planSummary = previousPlanSummary ?? session.planSummary
            session.events.append(
                OrganizationSessionEvent(
                    timestamp: regenerated.timestamp,
                    kind: .regenerated,
                    summary: "Regenerated organization attempt #\(regenerationCount)"
                )
            )
        }
        currentProfile = profile
        debouncedSave()
    }

    /// Record what the applied plan changed compared with the previews the user regenerated.
    public func recordRegenerationPreferenceEvidence(_ evidence: RegenerationPreferenceEvidence) {
        guard consentManager.canCollectData, !sessionLearningPaused else { return }
        guard !isPathExcludedFromLearning(evidence.folderPath) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }

        profile.regenerationPreferenceEvidence.append(evidence)
        currentProfile = profile
        debouncedSave()
    }
    
    /// Record a steering prompt (post-organization feedback)
    public func recordSteeringPrompt(_ prompt: String, folderPath: String?, sessionId: String?) {
        guard consentManager.canCollectData else { return }
        if let folderPath, isPathExcludedFromLearning(folderPath) { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let steeringPrompt = SteeringPrompt(
            prompt: prompt,
            folderPath: folderPath,
            sessionId: sessionId
        )
        profile.steeringPrompts.append(steeringPrompt)
        mutateSession(in: &profile, sessionId: sessionId, folderPath: folderPath, timestamp: steeringPrompt.timestamp, createIfMissing: folderPath != nil) { session in
            session.steeringPrompts.append(prompt)
            session.events.append(
                OrganizationSessionEvent(
                    timestamp: steeringPrompt.timestamp,
                    kind: .steeringPrompt,
                    summary: prompt
                )
            )
        }
        currentProfile = profile
        debouncedSave()
    }
    
    /// Record a directory change made after AI organization
    public func recordDirectoryChange(from original: String, to new: String, wasAIOrganized: Bool, sessionId: String? = nil) {
        guard consentManager.canCollectData else { return }
        guard !shouldExcludeLearning(paths: [original, new]) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let change = DirectoryChange(
            originalPath: original,
            newPath: new,
            wasAIOrganized: wasAIOrganized,
            aiSessionId: sessionId
        )
        profile.postOrganizationChanges.append(change)
        currentProfile = profile
        debouncedSave()
        
        // Trigger auto-inference check after recording change
        Task { await checkAndTriggerAutoInference() }
    }

    public func recordRenameFeedback(
        originalName: String,
        suggestedName: String?,
        finalName: String?,
        folderPath: String?,
        action: ExampleAction,
        confidence: Double?
    ) {
        guard consentManager.canCollectData else { return }
        if let folderPath, isPathExcludedFromLearning(folderPath) { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }

        let event = RenameFeedbackEvent(
            originalName: originalName,
            suggestedName: suggestedName,
            finalName: finalName,
            folderPath: folderPath,
            action: action,
            confidence: confidence
        )
        profile.renameFeedbackHistory.append(event)
        if let folderPath {
            mutateSession(in: &profile, folderPath: folderPath, timestamp: event.timestamp) { session in
                session.renameFeedback.append(event)
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: event.timestamp,
                        kind: .renameFeedback,
                        summary: "Rename feedback for \(originalName)"
                    )
                )
            }
        }
        currentProfile = profile

        // Rename feedback has different semantics from placement examples. Keeping it
        // in its own history prevents filename edits and rejections from inducing
        // folder-move or broad avoidance rules.
        debouncedSave()
    }
    
    /// Record a history revert event
    public func recordHistoryRevert(entryId: String, operationCount: Int, folderPath: String? = nil, revertReason: String? = nil) {
        guard consentManager.canCollectData else { return }
        if let folderPath, isPathExcludedFromLearning(folderPath) { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let event = RevertEvent(
            entryId: entryId,
            operationCount: operationCount,
            folderPath: folderPath,
            reason: revertReason
        )
        profile.historyReverts.append(event)
        currentProfile = profile
        debouncedSave()
    }
    
    // MARK: - Session Outcome Feedback
    
    /// Outcome feedback for a completed organization session
    public enum SessionOutcome: String, Sendable {
        case useful
        case notUseful
    }
    
    /// Record quick outcome feedback for a session from history view
    public func recordSessionOutcomeFeedback(sessionId: String, outcome: SessionOutcome, folderPath: String? = nil) {
        guard consentManager.canCollectData else { return }
        guard !sessionLearningPaused else { return }
        if let folderPath, isPathExcludedFromLearning(folderPath) { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }

        let resolvedSessionID: String
        if profile.sessions.contains(where: { $0.id == sessionId }) {
            resolvedSessionID = sessionId
        } else if let matchedSession = profile.sessions.first(where: { $0.historyEntryId == sessionId }) {
            resolvedSessionID = matchedSession.id
        } else {
            resolvedSessionID = sessionId
        }
        
        mutateSession(in: &profile, sessionId: resolvedSessionID, folderPath: folderPath, createIfMissing: false) { session in
            switch outcome {
            case .useful:
                // Mark as accepted if not already corrected/reverted
                if session.reaction == .inProgress {
                    session.reaction = .accepted
                }
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: Date(),
                        kind: .feedback,
                        summary: "User marked session as useful"
                    )
                )
            case .notUseful:
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: Date(),
                        kind: .feedback,
                        summary: "User marked session as not useful"
                    )
                )
            }
        }
        
        currentProfile = profile
        debouncedSave()
    }
    
    /// Get the count of active rules applicable to a specific folder
    public func activeRuleCount(forFolder folderPath: String) -> Int {
        guard let profile = currentProfile else { return 0 }
        return profile.inferredRules
            .filter { $0.isEnabled && $0.status == .active }
            .filter { ruleMatchesScope(rule: $0, folderPath: folderPath, personaId: nil) }
            .count
    }
    
    /// Record a successfully completed organization run
    public func recordSuccessfulRun(folderPath: String, fileCount: Int, ruleIdsUsed: Set<String>) {
        guard consentManager.canCollectData else { return }
        guard !isPathExcludedFromLearning(folderPath) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        // Use the actual file count if 0 was passed
        let count = fileCount > 0 ? fileCount : 0
        
        let job = JobManifest(
            projectName: "Automated Run",
            entries: Array(repeating: JobManifestEntry(originalPath: "", destinationPath: "", status: .success), count: count),
            status: .completed
        )
        profile.jobHistory.append(job)
        
        currentProfile = profile
        debouncedSave()
    }
    
    // MARK: - Inline Learning Moments
    
    /// Generate a post-organization learning moment based on the most uncertain decision
    public func generateInlineLearningMoment(
        from session: OrganizationSession,
        proposedFolders: [String]
    ) -> InlineLearningMoment? {
        guard !session.filesMoved.isEmpty else { return nil }
        
        let existingFolderNames = Set(session.folderPatterns.map(\.folderName))
        
        // Priority 1: Files moved to newly-created folders (highest uncertainty)
        let movedToNewFolders = session.filesMoved.filter { moved in
            let destFolder = URL(fileURLWithPath: moved.destinationPath).deletingLastPathComponent().lastPathComponent
            return !existingFolderNames.contains(destFolder) && proposedFolders.contains(destFolder)
        }
        
        if let candidate = movedToNewFolders.first {
            let destFolder = URL(fileURLWithPath: candidate.destinationPath).deletingLastPathComponent().lastPathComponent
            let fileExt = URL(fileURLWithPath: candidate.sourcePath).pathExtension.lowercased()
            let fileDesc = fileExt.isEmpty ? candidate.fileName : ".\(fileExt) files"
            
            // Find alternative folders from the session
            let alternativeFolders = session.folderPatterns
                .map(\.folderName)
                .filter { $0 != destFolder }
                .prefix(2)
            
            guard !alternativeFolders.isEmpty else { return nil }
            
            var options = [destFolder] + alternativeFolders
            options.append("Create a different folder")
            
            return InlineLearningMoment(
                sessionId: session.id,
                folderPath: session.folderPath,
                prompt: "Should \(fileDesc) like '\(candidate.fileName)' go in '\(destFolder)' or '\(alternativeFolders.first!)'?",
                options: options,
                kind: .folderPlacement,
                relatedFilePath: candidate.sourcePath
            )
        }
        
        // Priority 2: Files with common extensions moved to unusual locations
        var extensionDestinations: [String: [String]] = [:]
        for moved in session.filesMoved {
            let ext = URL(fileURLWithPath: moved.sourcePath).pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            let destFolder = URL(fileURLWithPath: moved.destinationPath).deletingLastPathComponent().lastPathComponent
            extensionDestinations[ext, default: []].append(destFolder)
        }
        
        // Find extensions that went to multiple different folders
        for (ext, destinations) in extensionDestinations {
            let uniqueDestinations = Array(Set(destinations))
            guard uniqueDestinations.count >= 2 else { continue }
            
            let options = Array(uniqueDestinations.prefix(3)) + ["Keep them together in one folder"]
            
            return InlineLearningMoment(
                sessionId: session.id,
                folderPath: session.folderPath,
                prompt: ".\(ext) files were sorted into multiple folders. Should all .\(ext) files go together?",
                options: options,
                kind: .fileGrouping
            )
        }
        
        // No meaningful uncertainty — session was straightforward
        return nil
    }
    
    /// Record the user's answer to an inline learning moment
    public func recordInlineLearningMomentAnswer(_ answer: InlineLearningMomentAnswer) async {
        guard consentManager.canCollectData else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        profile.inlineLearningMomentAnswers.append(answer)
        
        // Record as a steering prompt if the answer implies a clear preference
        let steeringPrompt = SteeringPrompt(
            prompt: "User preference: \(answer.selectedOption)",
            folderPath: nil,
            sessionId: answer.sessionId
        )
        profile.steeringPrompts.append(steeringPrompt)
        
        currentProfile = profile
        await saveProfile()
    }
    
    // MARK: - Debounced Saving
    
    private var saveTask: Task<Void, Never>?
    private let saveDebounceInterval: UInt64 = 2_000_000_000 // 2 seconds in nanoseconds
    
    /// Debounced save to prevent rapid successive writes
    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: saveDebounceInterval)
            guard !Task.isCancelled else { return }
            await saveProfile()
        }
    }
    
    /// Force immediate save (for critical operations)
    public func forceSave() async {
        saveTask?.cancel()
        pruneOldData()
        await saveProfile()
    }

    public func forceSaveSynchronously() {
        saveTask?.cancel()
        pruneOldData()
        guard let profile = currentProfile else { return }
        do {
            try LearningsFileManager.save(profile: profile)
        } catch {
            self.error = "Failed to save profile: \(error.localizedDescription)"
        }
    }
    
    /// Caps history arrays at 100 items to prevent bloat
    private func pruneOldData() {
        guard var profile = currentProfile else { return }
        pruneOldData(in: &profile)
        currentProfile = profile
    }

    /// Applies the selected retention period immediately and persists the deletion.
    /// This is also used after loading so expired records are never exposed or reused.
    public func applyDataRetentionPolicy(now: Date = Date()) async {
        guard var profile = currentProfile else { return }
        let previousSnapshot = learningProfileSnapshot(profile)
        pruneOldData(in: &profile, now: now)
        guard learningProfileSnapshot(profile) != previousSnapshot else { return }
        currentProfile = profile
        await saveProfile()
    }

    private func pruneOldData(in profile: inout LearningsProfile, now: Date = Date()) {
        if dataRetentionDays > 0,
           let cutoff = Calendar.current.date(byAdding: .day, value: -dataRetentionDays, to: now) {
            profile.additionalInstructionsHistory.removeAll { $0.timestamp < cutoff }
            profile.guidingInstructionsHistory.removeAll { $0.timestamp < cutoff }
            profile.steeringPrompts.removeAll { $0.timestamp < cutoff }
            profile.postOrganizationChanges.removeAll { $0.timestamp < cutoff }
            profile.renameFeedbackHistory.removeAll { $0.timestamp < cutoff }
            profile.historyReverts.removeAll { $0.timestamp < cutoff }
            profile.positiveExamples.removeAll { $0.timestamp < cutoff }
            profile.rejections.removeAll { $0.timestamp < cutoff }
            profile.corrections.removeAll { $0.timestamp < cutoff }
            profile.jobHistory.removeAll { $0.timestamp < cutoff }
            profile.cancelledOrganizations.removeAll { $0.timestamp < cutoff }
            profile.regeneratedOrganizations.removeAll { $0.timestamp < cutoff }
            profile.regenerationPreferenceEvidence.removeAll { $0.timestamp < cutoff }
            profile.sessions.removeAll { ($0.completedAt ?? $0.timestamp) < cutoff }
            profile.inlineLearningMomentAnswers.removeAll { $0.timestamp < cutoff }

            let retainedEvidenceIDs = Set(profile.positiveExamples.map(\.id))
                .union(profile.rejections.map(\.id))
                .union(profile.corrections.map(\.id))
            profile.inferredRules.removeAll { rule in
                let evidenceIDs = Set(rule.exampleIds).union(rule.evidenceIds)
                return !evidenceIDs.isEmpty && evidenceIDs.isDisjoint(with: retainedEvidenceIDs)
            }
            profile.rejectedRuleCooldowns = profile.rejectedRuleCooldowns.filter { $0.value >= cutoff }
        }

        let cap = 100
        profile.additionalInstructionsHistory = Array(profile.additionalInstructionsHistory.suffix(cap))
        profile.guidingInstructionsHistory = Array(profile.guidingInstructionsHistory.suffix(cap))
        profile.steeringPrompts = Array(profile.steeringPrompts.suffix(cap))
        profile.postOrganizationChanges = Array(profile.postOrganizationChanges.suffix(cap))
        profile.renameFeedbackHistory = Array(profile.renameFeedbackHistory.suffix(cap))
        profile.historyReverts = Array(profile.historyReverts.suffix(cap))
        profile.positiveExamples = Array(profile.positiveExamples.suffix(cap))
        profile.rejections = Array(profile.rejections.suffix(cap))
        profile.corrections = Array(profile.corrections.suffix(cap))
        profile.jobHistory = Array(profile.jobHistory.suffix(cap))
        profile.cancelledOrganizations = Array(profile.cancelledOrganizations.suffix(cap))
        profile.regeneratedOrganizations = Array(profile.regeneratedOrganizations.suffix(cap))
        profile.regenerationPreferenceEvidence = Array(profile.regenerationPreferenceEvidence.suffix(cap))
        profile.sessions = Array(profile.sessions.prefix(cap))
        profile.inlineLearningMomentAnswers = Array(profile.inlineLearningMomentAnswers.suffix(cap))
    }
    
    // MARK: - Feedback Loop (Continuous Learning)
    
    /// Record a manual correction (File moved manually after AI organization)
    public func recordCorrection(originalPath: String, newPath: String, folderPath: String? = nil) {
        guard consentManager.canCollectData else { return }
        guard !shouldExcludeLearning(paths: [originalPath, newPath]) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let example = LabeledExample(
            srcPath: originalPath,
            dstPath: newPath,
            metadata: folderPath.map { ["folder_scope": $0] },
            action: .edit
        )
        profile.corrections.append(example)
        currentProfile = profile
        debouncedSave()
        
        // Trigger auto-inference check after recording correction
        Task { await checkAndTriggerAutoInference() }
    }
    
    /// Record a rejection (File reverted or explicitly rejected)
    public func recordRejection(originalPath: String) {
        guard consentManager.canCollectData else { return }
        guard !isPathExcludedFromLearning(originalPath) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let example = LabeledExample(
            srcPath: originalPath,
            dstPath: originalPath,
            action: .reject
        )
        profile.rejections.append(example)
        currentProfile = profile
        Task { 
            await saveProfile() 
            await checkAndTriggerAutoInference()
        }
    }
    
    // MARK: - Legacy Project Method Removals
    // Removing createProject, loadProject, saveProject (replaced by saveProfile), listProjects
    
    // MARK: - Example Management
    
    // MARK: - Path Management
    // Removed legacy project folder paths. Learnings now operates globally on user behavior.
    
    /// Add a positive example (User organized correctly)
    public func addPositiveExample(srcPath: String, dstPath: String) {
        addLabeledExample(srcPath: srcPath, dstPath: dstPath, action: .accept)
    }
    
    /// Internal helper to add a labeled example
    public func addLabeledExample(srcPath: String, dstPath: String, action: ExampleAction) {
        guard consentManager.canCollectData else { return }
        guard !shouldExcludeLearning(paths: [srcPath, dstPath]) else { return }
        loadProfileIfNeededForCollection()
        guard var profile = currentProfile else { return }
        
        let example = LabeledExample(
            srcPath: srcPath,
            dstPath: dstPath,
            action: action
        )
        
        switch action {
        case .accept:
            profile.positiveExamples.append(example)
        case .reject:
            profile.rejections.append(example)
        case .edit:
            profile.corrections.append(example)
        default:
            break
        }
        
        currentProfile = profile
        Task { 
            await saveProfile()
            // Trigger auto-inference check after adding example
            await checkAndTriggerAutoInference()
        }
    }
    
    // MARK: - Analysis

    private func runAnalysis(rootPaths: [String], examplePaths: [String]) async {
        guard let profile = currentProfile else {
            error = "No profile loaded"
            return
        }

        let sanitizedProfile = filteredLearningProfile(from: profile)
        if learningProfileSnapshot(sanitizedProfile) != learningProfileSnapshot(profile) {
            currentProfile = sanitizedProfile
        }

        error = nil

        let filteredRootPaths = rootPaths.filter { !isPathExcludedFromLearning($0) }.orderedDeduplicated()
        let filteredExamplePaths = examplePaths.filter { !isPathExcludedFromLearning($0) }.orderedDeduplicated()

        do {
            analysisResult = try await analyzer.analyze(
                profile: sanitizedProfile,
                rootPaths: filteredRootPaths,
                examplePaths: filteredExamplePaths
            )

            if let result = analysisResult {
                var updatedProfile = sanitizedProfile
                updatedProfile.inferredRules = mergeInferredRules(existing: sanitizedProfile.inferredRules, new: result.inferredRules)
                currentProfile = updatedProfile
                await saveProfile()
            }
        } catch {
            self.error = "Analysis failed: \(error.localizedDescription)"
        }
    }
    
    /// Run analysis on current profile and paths
    public func analyze(rootPaths: [String], examplePaths: [String]) async {
        // Use configured model directories as example paths when none are explicitly provided
        let effectiveExamplePaths: [String]
        if examplePaths.isEmpty {
            effectiveExamplePaths = enabledModelDirectoryPaths()
        } else {
            effectiveExamplePaths = examplePaths
        }

        await runAnalysis(rootPaths: rootPaths, examplePaths: effectiveExamplePaths)
    }

    /// Re-synthesize learning insights without requiring scan roots.
    public func synthesizeLearnings() async {
        await runAnalysis(rootPaths: [], examplePaths: enabledModelDirectoryPaths())
    }
    
    /// Accept a proposed mapping
    public func acceptMapping(_ mapping: ProposedMapping) {
        addLabeledExample(
            srcPath: mapping.srcPath,
            dstPath: mapping.proposedDstPath,
            action: .accept
        )
    }
    
    /// Reject a proposed mapping
    public func rejectMapping(_ mapping: ProposedMapping) {
        addLabeledExample(
            srcPath: mapping.srcPath,
            dstPath: mapping.srcPath,  // Keep in place
            action: .reject
        )
    }
    
    /// Edit a proposed mapping
    public func editMapping(_ mapping: ProposedMapping, newDstPath: String) {
        addLabeledExample(
            srcPath: mapping.srcPath,
            dstPath: newDstPath,
            action: .edit
        )
    }
    
    // MARK: - Export
    
    /// Export preview to JSON file
    public func exportPreview(to url: URL) async throws {
        guard let result = analysisResult else {
            throw LearningsError.noAnalysisResult
        }
        
        let data = try result.toJSON()
        try data.write(to: url)
    }
    
    /// Export rules to JSON file
    public func exportRules(to url: URL) async throws {
        guard let profile = currentProfile else {
            throw LearningsError.noProject
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let data = try encoder.encode(profile.inferredRules)
        try data.write(to: url)
    }

    /// Export a portable, integrity-checked profile archive.
    @discardableResult
    func exportProfile(to url: URL) throws -> LearningsProfileArchiveSummary {
        let data = try makeProfileArchiveData()
        try data.write(to: url, options: .atomic)
        guard let profile = currentProfile else {
            throw LearningsProfileTransferError.noProfile
        }
        return LearningsProfileArchiveSummary(profile: profile)
    }

    func makeProfileArchiveData(
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        buildVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        exportedAt: Date = Date()
    ) throws -> Data {
        guard let profile = currentProfile else {
            throw LearningsProfileTransferError.noProfile
        }

        let archive = LearningsProfileArchive(
            schemaVersion: LearningsProfileArchive.currentSchemaVersion,
            exportedAt: exportedAt,
            appVersion: appVersion,
            buildVersion: buildVersion,
            profileCreatedAt: profile.createdAt,
            summary: LearningsProfileArchiveSummary(profile: profile),
            settings: LearningsProfileSettingsSnapshot(
                learningStrength: learningStrength,
                usesAIForAnalysis: useAIForLearnings,
                dataRetentionDays: dataRetentionDays,
                modelSelection: learningsModelSelection
            ),
            profileDigestSHA256: try profileDigest(profile),
            profile: profile
        )

        let encoder = Self.profileJSONEncoder()
        return try encoder.encode(archive)
    }
    
    // MARK: - Import
    
    /// Import and merge a portable profile without importing its consent state.
    public func importProfile(from url: URL) async throws -> LearningsProfileImportResult {
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "learnings" || fileExtension == "json" else {
            throw LearningsProfileTransferError.unsupportedFile
        }

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile == true else {
            throw LearningsProfileTransferError.unsupportedFile
        }
        guard (resourceValues.fileSize ?? 0) <= Self.maximumProfileImportBytes else {
            throw LearningsProfileTransferError.fileTooLarge
        }

        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try await importProfile(data: data)
    }

    func importProfile(data: Data) async throws -> LearningsProfileImportResult {
        guard data.count <= Self.maximumProfileImportBytes else {
            throw LearningsProfileTransferError.fileTooLarge
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let topLevel = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let archive: LearningsProfileArchive?
        let importedProfile: LearningsProfile
        let wasLegacyProfile: Bool

        if topLevel?["schemaVersion"] != nil {
            do {
                let decodedArchive = try decoder.decode(LearningsProfileArchive.self, from: data)
                try validateArchive(decodedArchive)
                archive = decodedArchive
                importedProfile = decodedArchive.profile
                wasLegacyProfile = false
            } catch let error as LearningsProfileTransferError {
                throw error
            } catch {
                throw LearningsProfileTransferError.inconsistentArchive
            }
        } else {
            do {
                importedProfile = try decoder.decode(LearningsProfile.self, from: data)
                archive = nil
                wasLegacyProfile = true
            } catch {
                throw LearningsProfileTransferError.unsupportedFile
            }
        }

        let importedSummary = LearningsProfileArchiveSummary(profile: importedProfile)
        guard importedSummary.totalRecordCount <= Self.maximumProfileImportRecords else {
            throw LearningsProfileTransferError.tooManyRecords
        }

        let existingProfile = currentProfile ?? LearningsProfile(
            consentGranted: consentManager.hasConsented
        )
        let previousRecordCount = LearningsProfileArchiveSummary(profile: existingProfile).totalRecordCount
        let preparedImport = migrateLegacySessionsIfNeeded(in: importedProfile)
        var mergedProfile = mergeProfiles(existing: existingProfile, imported: preparedImport)

        let restoredSettingCount: Int
        if let settings = archive?.settings {
            try validateSettings(settings)
            applyImportedSettings(settings)
            restoredSettingCount = 3
        } else {
            restoredSettingCount = 0
        }

        let mergedRecordCount = LearningsProfileArchiveSummary(profile: mergedProfile).totalRecordCount
        pruneOldData(in: &mergedProfile)
        currentProfile = mergedProfile
        await saveProfile()

        let resultingRecordCount = LearningsProfileArchiveSummary(
            profile: currentProfile ?? mergedProfile
        ).totalRecordCount
        return LearningsProfileImportResult(
            importedRecordCount: importedSummary.totalRecordCount,
            previousRecordCount: previousRecordCount,
            resultingRecordCount: resultingRecordCount,
            omittedByRetentionPolicy: max(0, mergedRecordCount - resultingRecordCount),
            restoredSettingCount: restoredSettingCount,
            wasLegacyProfile: wasLegacyProfile
        )
    }

    private static let maximumProfileImportBytes = 25 * 1_024 * 1_024
    private static let maximumProfileImportRecords = 10_000

    private static func profileJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func profileDigest(_ profile: LearningsProfile) throws -> String {
        let data = try Self.profileJSONEncoder().encode(profile)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateArchive(_ archive: LearningsProfileArchive) throws {
        guard (1...LearningsProfileArchive.currentSchemaVersion).contains(archive.schemaVersion) else {
            throw LearningsProfileTransferError.unsupportedSchema(archive.schemaVersion)
        }
        guard archive.profileCreatedAt == archive.profile.createdAt,
              archive.summary == LearningsProfileArchiveSummary(profile: archive.profile),
              archive.profileDigestSHA256 == (try profileDigest(archive.profile)) else {
            throw LearningsProfileTransferError.inconsistentArchive
        }
        guard archive.summary.totalRecordCount <= Self.maximumProfileImportRecords else {
            throw LearningsProfileTransferError.tooManyRecords
        }
        try validateSettings(archive.settings)
    }

    private func validateSettings(_ settings: LearningsProfileSettingsSnapshot) throws {
        guard settings.learningStrength.isFinite,
              (0...1).contains(settings.learningStrength),
              [0, 30, 90, 365].contains(settings.dataRetentionDays),
              settings.modelSelection?.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw LearningsProfileTransferError.invalidSettings
        }
    }

    private func applyImportedSettings(_ settings: LearningsProfileSettingsSnapshot) {
        learningStrength = settings.learningStrength
        dataRetentionDays = settings.dataRetentionDays

        if let selection = settings.modelSelection {
            setLearningsModelOverride(provider: selection.provider, model: selection.model)
        } else {
            clearLearningsModelOverride()
        }
    }

    private func mergeProfiles(
        existing: LearningsProfile,
        imported: LearningsProfile
    ) -> LearningsProfile {
        // Mutate a copy of the existing profile so fields introduced by newer app
        // versions remain intact even when an older archive does not know about them.
        var mergedProfile = existing
        var rejectedRuleCooldowns = existing.rejectedRuleCooldowns
        for (ruleID, importedDate) in imported.rejectedRuleCooldowns {
            rejectedRuleCooldowns[ruleID] = max(rejectedRuleCooldowns[ruleID] ?? .distantPast, importedDate)
        }

        mergedProfile.additionalInstructionsHistory = mergedByID(
            existing.additionalInstructionsHistory,
            imported.additionalInstructionsHistory
        ).sorted { $0.timestamp < $1.timestamp }
        mergedProfile.guidingInstructionsHistory = mergedByID(
            existing.guidingInstructionsHistory,
            imported.guidingInstructionsHistory
        ).sorted { $0.timestamp < $1.timestamp }
        mergedProfile.steeringPrompts = mergedByID(existing.steeringPrompts, imported.steeringPrompts)
            .sorted { $0.timestamp < $1.timestamp }
        mergedProfile.postOrganizationChanges = mergedByID(
            existing.postOrganizationChanges,
            imported.postOrganizationChanges
        ).sorted { $0.timestamp < $1.timestamp }
        mergedProfile.renameFeedbackHistory = mergedByID(
            existing.renameFeedbackHistory,
            imported.renameFeedbackHistory
        ).sorted { $0.timestamp < $1.timestamp }
        mergedProfile.historyReverts = mergedByID(existing.historyReverts, imported.historyReverts)
            .sorted { $0.timestamp < $1.timestamp }
        mergedProfile.cancelledOrganizations = mergedByID(
            existing.cancelledOrganizations,
            imported.cancelledOrganizations
        ).sorted { $0.timestamp < $1.timestamp }
        mergedProfile.regeneratedOrganizations = mergedByID(
            existing.regeneratedOrganizations,
            imported.regeneratedOrganizations
        ).sorted { $0.timestamp < $1.timestamp }
        mergedProfile.regenerationPreferenceEvidence = mergedByID(
            existing.regenerationPreferenceEvidence,
            imported.regenerationPreferenceEvidence
        ).sorted { $0.timestamp < $1.timestamp }
        mergedProfile.inferredRules = mergedByID(existing.inferredRules, imported.inferredRules)
        mergedProfile.corrections = mergedByID(existing.corrections, imported.corrections)
            .sorted { $0.timestamp < $1.timestamp }
        mergedProfile.rejections = mergedByID(existing.rejections, imported.rejections)
            .sorted { $0.timestamp < $1.timestamp }
        mergedProfile.positiveExamples = mergedByID(existing.positiveExamples, imported.positiveExamples)
            .sorted { $0.timestamp < $1.timestamp }
        mergedProfile.jobHistory = mergedByID(existing.jobHistory, imported.jobHistory)
            .sorted { $0.timestamp < $1.timestamp }
        mergedProfile.rejectedRuleCooldowns = rejectedRuleCooldowns
        mergedProfile.learningExclusionPatterns = Array(
            Set(existing.learningExclusionPatterns + imported.learningExclusionPatterns)
        ).sorted()
        mergedProfile.sessions = mergedByID(existing.sessions, imported.sessions)
            .sorted { ($0.completedAt ?? $0.timestamp) > ($1.completedAt ?? $1.timestamp) }
        mergedProfile.inlineLearningMomentAnswers = mergedByID(
            existing.inlineLearningMomentAnswers,
            imported.inlineLearningMomentAnswers
        ).sorted { $0.timestamp < $1.timestamp }
        return mergedProfile
    }

    private func mergedByID<Element: Identifiable>(
        _ existing: [Element],
        _ imported: [Element]
    ) -> [Element] where Element.ID: Hashable {
        var merged = existing
        var indexes = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($1.id, $0) })

        for element in imported {
            if let index = indexes[element.id] {
                merged[index] = element
            } else {
                indexes[element.id] = merged.count
                merged.append(element)
            }
        }

        return merged
    }
    
    // MARK: - Apply & Rollback
    
    @Published public var applyProgress: Double = 0
    @Published public var isApplying: Bool = false
    @Published public var lastJobId: String?
    
    /// Apply proposed mappings with optional backup
    public func applyMappings(backupDirectory: URL?, onlyHighConfidence: Bool = false) async {
        guard var profile = currentProfile, let result = analysisResult else {
            error = "No profile or analysis result"
            return
        }
        
        isApplying = true
        applyProgress = 0
        error = nil
        
        let fm = FileManager.default
        let backupMode: BackupMode = backupDirectory != nil ? .copyToBackupDir : .none
        
        // Filter mappings based on confidence
        let mappingsToApply = result.proposedMappings.filter {
            !onlyHighConfidence || $0.confidenceLevel == .high
        }
        
        var entries: [JobManifestEntry] = []
        var successCount = 0
        var failCount = 0
        
        for (index, mapping) in mappingsToApply.enumerated() {
            do {
                var backupPath: String?
                
                // Create backup if needed
                if let backupDir = backupDirectory {
                    backupPath = backupDir.appendingPathComponent(
                        "\(UUID().uuidString)_\(URL(fileURLWithPath: mapping.srcPath).lastPathComponent)"
                    ).path
                    
                    try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                    try fm.copyItem(atPath: mapping.srcPath, toPath: backupPath!)
                }
                
                // Create destination directory
                let destDir = URL(fileURLWithPath: mapping.proposedDstPath).deletingLastPathComponent()
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                
                // Move file
                try fm.moveItem(atPath: mapping.srcPath, toPath: mapping.proposedDstPath)
                
                entries.append(JobManifestEntry(
                    originalPath: mapping.srcPath,
                    destinationPath: mapping.proposedDstPath,
                    backupPath: backupPath,
                    status: .success
                ))
                successCount += 1
            } catch {
                entries.append(JobManifestEntry(
                    originalPath: mapping.srcPath,
                    destinationPath: mapping.proposedDstPath,
                    status: .failed
                ))
                failCount += 1
            }
            
            applyProgress = Double(index + 1) / Double(mappingsToApply.count)
        }
        
        // Save job manifest
        let job = JobManifest(
            projectName: "User Profile",
            entries: entries,
            backupMode: backupMode,
            status: .completed
        )
        
        // Append to profile history
        profile.jobHistory.append(job)
        currentProfile = profile
        lastJobId = job.id
        
        await saveProfile()
        
        isApplying = false
        applyProgress = 1.0
        
        if failCount > 0 {
            self.error = "Applied \(successCount) files, \(failCount) failed"
        }
    }
    
    /// Rollback a job by its ID
    public func rollbackJob(jobId: String) async {
        guard var profile = currentProfile else {
            error = "No profile loaded"
            return
        }
        
        guard let job = profile.jobHistory.first(where: { $0.id == jobId }) else {
            error = "Job not found: \(jobId)"
            return
        }
        
        isApplying = true
        applyProgress = 0
        error = nil
        
        let fm = FileManager.default
        var successCount = 0
        var failCount = 0
        
        for (index, entry) in job.entries.enumerated() {
            do {
                if let backupPath = entry.backupPath, fm.fileExists(atPath: backupPath) {
                    // Remove current destination
                    if fm.fileExists(atPath: entry.destinationPath) {
                        try fm.removeItem(atPath: entry.destinationPath)
                    }
                    // Restore from backup
                    try fm.moveItem(atPath: backupPath, toPath: entry.originalPath)
                } else if fm.fileExists(atPath: entry.destinationPath) {
                    // Move back without backup
                    try fm.moveItem(atPath: entry.destinationPath, toPath: entry.originalPath)
                }
                successCount += 1
            } catch {
                failCount += 1
            }
            
            applyProgress = Double(index + 1) / Double(job.entries.count)
        }
        
        // Update job status
        if let jobIndex = profile.jobHistory.firstIndex(where: { $0.id == jobId }) {
            profile.jobHistory[jobIndex].status = .rolledBack
            currentProfile = profile
            await saveProfile()
        }
        
        isApplying = false
        applyProgress = 1.0
        
        if failCount > 0 {
            self.error = "Rolled back \(successCount) files, \(failCount) failed"
        }
    }
    // MARK: - Prompt Context Generation
    
    /// Generates a prompt context string based on the current profile
    /// This is the bridge between learned data and the AI organization engine.
    /// The context is intentionally short and session-centric so the model gets
    /// recent, attributable signals instead of a long undifferentiated dump.
    public func generatePromptContext(forFolder folderPath: String? = nil) -> String {
        guard let profile = currentProfile, (profile.consentGranted || consentManager.hasConsented) else {
            return ""
        }

        let preparedProfile = prepareLoadedProfile(profile)
        if preparedProfile.sessions.count != profile.sessions.count {
            currentProfile = preparedProfile
        }

        let filteredProfile = filteredLearningProfile(from: preparedProfile)
        if !filteredProfile.consentGranted && !consentManager.hasConsented {
            return ""
        }

        let scopedSessions = filteredProfile.sessions
            .filter { session in
                guard let folderPath else { return true }
                return session.folderPath.hasPrefix(folderPath) || folderPath.hasPrefix(session.folderPath)
            }
            .sorted(by: { ($0.completedAt ?? $0.timestamp) > ($1.completedAt ?? $1.timestamp) })

        var hardRules: [String] = []

        let recentInstructions = (filteredProfile.additionalInstructionsHistory + filteredProfile.guidingInstructionsHistory)
            .sorted(by: { $0.timestamp > $1.timestamp })
            .prefix(4)
            .map { "Recent instruction (\(promptDateString($0.timestamp))): \($0.instruction)" }
        hardRules.append(contentsOf: recentInstructions)

        // activeRules(from:) already ranks by effective confidence (outcomes + support + recency).
        let promptRuleDate = Date()
        let activeRules = activeRules(
            from: filteredProfile,
            folderPath: folderPath,
            personaId: nil
        )
            .prefix(4)
            .map { rule in
                let confidence = Int(rule.effectiveConfidence(at: promptRuleDate) * 100)
                let label = rule.isAvoidRule ? "Avoid rule" : "Learned rule"
                return "\(label) [rule_id: \(rule.id)] (confidence \(confidence)%): \(rule.explanation)"
            }
        hardRules.append(contentsOf: activeRules)
        hardRules = Array(hardRules.orderedDeduplicated().prefix(5))

        let recentContext = scopedSessions.prefix(5).map(summarizePromptSession)
        let learnedPatterns = buildPromptPatterns(from: filteredProfile, sessions: Array(scopedSessions.prefix(12)), folderPath: folderPath)

        let sections: [(String, [String])] = [
            ("HARD RULES, USER INSTRUCTIONS, AND PREFERENCES", hardRules),
            ("RECENT SESSION CONTEXT", recentContext),
            ("LEARNED PATTERNS", learnedPatterns)
        ]

        var output: [String] = [
            "LEARNINGS CONTEXT",
            "Use the following user-specific learnings to guide the organization plan. Prioritize explicit preferences first, then reference examples, then recent accepted/corrected sessions, then repeated patterns.",
            "When learnings apply, mirror their destination folder names, hierarchy depth, and filename conventions instead of falling back to generic categories."
        ]

        if let folderPath {
            output.append("Current folder: \(folderPath)")
        }

        for (title, items) in sections where !items.isEmpty {
            output.append("")
            output.append("## \(title)")
            output.append(contentsOf: items.prefix(5).map { "- \($0)" })
        }

        guard output.count > 2 else { return "" }
        return "<learnings_context>\n\(output.joined(separator: "\n"))\n</learnings_context>"
    }
    
    // MARK: - Prompt Context Helpers

    private func promptDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func summarizePromptSession(_ session: OrganizationSession) -> String {
        let date = promptDateString(session.completedAt ?? session.timestamp)
        let folderName = URL(fileURLWithPath: session.folderPath).lastPathComponent
        let movedCount = max(session.filesMoved.count, session.appliedRules.count)

        switch session.reaction {
        case .accepted:
            let destinations = session.folderPatterns.prefix(3).map(\.relativePath).joined(separator: ", ")
            if !destinations.isEmpty {
                return "\(date): Accepted run in \(folderName). \(movedCount) files stayed in place, using \(destinations)."
            }
            return "\(date): Accepted run in \(folderName). \(movedCount) files needed no corrections."
        case .corrected:
            let changeSummary = session.userCorrections.prefix(2).map { change in
                let from = URL(fileURLWithPath: change.originalPath).deletingLastPathComponent().lastPathComponent
                let to = URL(fileURLWithPath: change.newPath).deletingLastPathComponent().lastPathComponent
                return "\(from) -> \(to)"
            }.joined(separator: ", ")
            return "\(date): Corrected run in \(folderName). User changed \(session.userCorrections.count) placements\(changeSummary.isEmpty ? "." : ": \(changeSummary).")"
        case .reverted:
            return "\(date): Reverted run in \(folderName). Be more conservative with this folder."
        case .cancelled:
            return "\(date): Cancelled run in \(folderName). The proposed structure was not accepted."
        case .regenerated:
            return "\(date): Regenerated run in \(folderName). The first plan needed a second attempt."
        case .inProgress:
            return "\(date): Recent run in \(folderName) is still collecting feedback."
        }
    }

    private func buildPromptPatterns(
        from profile: LearningsProfile,
        sessions: [OrganizationSession],
        folderPath: String?
    ) -> [String] {
        var patterns: [String] = []

        let acceptedSessions = sessions.filter(\.acceptedWithoutCorrections)
        let correctedSessions = sessions.filter { $0.reaction == .corrected || !$0.userCorrections.isEmpty }

        var acceptedFolderPatterns: [String: (count: Int, extensions: [String: Int])] = [:]
        for session in acceptedSessions {
            for pattern in session.folderPatterns {
                var entry = acceptedFolderPatterns[pattern.relativePath] ?? (count: 0, extensions: [:])
                entry.count += pattern.fileCount
                for ext in pattern.fileExtensions {
                    entry.extensions[ext, default: 0] += 1
                }
                acceptedFolderPatterns[pattern.relativePath] = entry
            }
        }

        let topAcceptedPatterns = acceptedFolderPatterns
            .sorted { $0.value.count > $1.value.count }
            .prefix(4)
        for (path, payload) in topAcceptedPatterns {
            let topExtensions = payload.extensions
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { key, _ in key.isEmpty ? "files" : ".\(key)" }
                .joined(separator: ", ")
            patterns.append("Accepted structure: \(path) is a good destination for \(topExtensions.isEmpty ? "similar files" : topExtensions).")
        }

        var correctionPatterns: [String: Int] = [:]
        for session in correctedSessions {
            for change in session.userCorrections where change.wasAIOrganized {
                let from = URL(fileURLWithPath: change.originalPath).deletingLastPathComponent().lastPathComponent
                let to = URL(fileURLWithPath: change.newPath).deletingLastPathComponent().lastPathComponent
                let ext = URL(fileURLWithPath: change.originalPath).pathExtension.lowercased()
                let label = ext.isEmpty
                    ? "Prefer \(to) over \(from) for similar files."
                    : "CORRECTIONS: .\(ext) files were moved from \(from) to \(to)."
                correctionPatterns[label, default: 0] += 1
            }
        }

        patterns.append(contentsOf: correctionPatterns.sorted { $0.value > $1.value }.prefix(4).map(\.key))

        let positiveExamples = profile.positiveExamples
            .filter { example in
                guard let folderPath else { return true }
                return example.dstPath.hasPrefix(folderPath)
            }
            .sorted(by: { $0.timestamp > $1.timestamp })
            .prefix(4)
            .map { example in
                let ext = URL(fileURLWithPath: example.srcPath).pathExtension.lowercased()
                let sourceName = URL(fileURLWithPath: example.srcPath).lastPathComponent
                let destinationName = URL(fileURLWithPath: example.dstPath).lastPathComponent
                let folder = URL(fileURLWithPath: example.dstPath).deletingLastPathComponent().path
                return ext.isEmpty
                    ? "Accepted example: \(sourceName) belonged in \(folder) as \(destinationName)."
                    : "Accepted example: .\(ext) files like \(sourceName) belonged in \(folder) as \(destinationName)."
            }
        patterns.append(contentsOf: positiveExamples)

        let scopedRenameFeedback = profile.renameFeedbackHistory.filter { event in
            guard let folderPath else { return true }
            guard let eventFolder = event.folderPath else { return false }
            return eventFolder.hasPrefix(folderPath) || folderPath.hasPrefix(eventFolder)
        }
        let renameGroups = Dictionary(grouping: scopedRenameFeedback) { event in
            let folder = event.folderPath ?? ""
            let ext = URL(fileURLWithPath: event.originalName).pathExtension.lowercased()
            return "\(folder)|\(ext)"
        }
        let renameConventions = renameGroups.values.compactMap { events -> (Date, String)? in
            let positive = events.filter { $0.action == .accept || $0.action == .edit }
            guard let convention = inferRenameConvention(from: positive) else { return nil }
            let matchingRejections = events.filter { event in
                event.action == .reject
                    && event.suggestedName.map(convention.matches) == true
            }.count
            let netSupport = positive.count - matchingRejections
            guard netSupport >= 2 else { return nil }
            let newest = positive.map(\.timestamp).max() ?? .distantPast
            let scope = events.compactMap(\.folderPath).first.map { _ in
                "In this folder, "
            } ?? ""
            let rejectionNote = matchingRejections > 0
                ? " One matching suggestion was rejected, so apply it conservatively."
                : ""
            return (newest, "Filename rule: \(scope)use `\(convention.displayPattern)`.\(rejectionNote)")
        }
        patterns.insert(contentsOf: renameConventions.sorted { $0.0 > $1.0 }.prefix(3).map { $0.1 }, at: 0)

        let protectedBundleRules = renameGroups.values.compactMap { events -> (Date, String)? in
            let rejectedBundles = events.filter { event in
                event.action == .reject
                    && URL(fileURLWithPath: event.originalName).pathExtension.lowercased() == "app"
                    && event.suggestedName != nil
            }
            guard rejectedBundles.count >= 2 else { return nil }
            let newest = rejectedBundles.map(\.timestamp).max() ?? .distantPast
            return (newest, "Protected naming rule: Never rename exported .app bundles in this folder.")
        }
        patterns.insert(contentsOf: protectedBundleRules.sorted { $0.0 > $1.0 }.prefix(2).map { $0.1 }, at: 0)

        return Array(patterns.orderedDeduplicated().prefix(8))
    }

    private struct RenameConventionPattern {
        let extensionName: String
        let hasDatePrefix: Bool
        let suffixTokens: [String]

        var displayPattern: String {
            var parts: [String] = []
            if hasDatePrefix { parts.append("YYYY-MM-DD") }
            parts.append("{name}")
            parts.append(contentsOf: suffixTokens)
            let base = parts.joined(separator: " ")
            return extensionName.isEmpty ? base : "\(base).\(extensionName)"
        }

        func matches(_ filename: String) -> Bool {
            let url = URL(fileURLWithPath: filename)
            guard url.pathExtension.lowercased() == extensionName else { return false }
            let base = url.deletingPathExtension().lastPathComponent
            if hasDatePrefix && base.range(of: #"^\d{4}-\d{2}-\d{2}(?:\s|[-_])"#, options: .regularExpression) == nil {
                return false
            }
            let normalized = base.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let suffix = suffixTokens.map { $0.lowercased() }
            return normalized.count >= suffix.count
                && Array(normalized.suffix(suffix.count)) == suffix
        }
    }

    private func inferRenameConvention(from events: [RenameFeedbackEvent]) -> RenameConventionPattern? {
        let names = events.compactMap { event -> String? in
            let name = event.finalName ?? event.suggestedName
            guard let name, name != event.originalName else { return nil }
            return name
        }
        guard names.count >= 2 else { return nil }

        let extensions = Set(names.map { URL(fileURLWithPath: $0).pathExtension.lowercased() })
        guard extensions.count == 1, let extensionName = extensions.first else { return nil }
        let bases = names.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        let datePrefixPattern = #"^\d{4}-\d{2}-\d{2}(?:\s|[-_])"#
        let hasDatePrefix = bases.allSatisfy {
            $0.range(of: datePrefixPattern, options: .regularExpression) != nil
        }
        let tokenLists = bases.map { base -> [String] in
            let withoutDate = hasDatePrefix
                ? base.replacingOccurrences(of: datePrefixPattern, with: "", options: .regularExpression)
                : base
            return withoutDate.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        guard let firstTokens = tokenLists.first else { return nil }
        var suffix: [String] = []
        for offset in 1...firstTokens.count {
            let candidate = firstTokens[firstTokens.count - offset]
            guard tokenLists.allSatisfy({ tokens in
                tokens.count >= offset
                    && tokens[tokens.count - offset].caseInsensitiveCompare(candidate) == .orderedSame
            }) else { break }
            suffix.insert(candidate, at: 0)
        }
        guard hasDatePrefix || !suffix.isEmpty else { return nil }
        return RenameConventionPattern(
            extensionName: extensionName,
            hasDatePrefix: hasDatePrefix,
            suffixTokens: suffix
        )
    }

    // MARK: - Rule Management
    
    /// Enable or disable a specific inferred rule
    public func setRuleEnabled(ruleId: String, enabled: Bool) async {
        guard var profile = currentProfile else { return }
        
        if let index = profile.inferredRules.firstIndex(where: { $0.id == ruleId }) {
            profile.inferredRules[index].isEnabled = enabled
            currentProfile = profile
            await saveProfile()
        }
    }
    
    /// Record a rule success (applied and no correction followed)
    public func recordRuleSuccess(ruleId: String) {
        guard consentManager.canCollectData else { return }
        guard var profile = currentProfile else { return }
        
        if let index = profile.inferredRules.firstIndex(where: { $0.id == ruleId }) {
            profile.inferredRules[index].successCount += 1
            profile.inferredRules[index].lastAppliedAt = Date()
            currentProfile = profile
            debouncedSave()
        }
    }
    
    /// Record a rule failure (applied but user corrected)
    public func recordRuleFailure(ruleId: String) {
        guard consentManager.canCollectData else { return }
        guard var profile = currentProfile else { return }
        
        if let index = profile.inferredRules.firstIndex(where: { $0.id == ruleId }) {
            profile.inferredRules[index].failureCount += 1
            
            // Auto-disable rules with high failure rate
            let rule = profile.inferredRules[index]
            if rule.failureRate > 0.3 && (rule.successCount + rule.failureCount) >= 5 {
                profile.inferredRules[index].isEnabled = false
                DebugLogger.log("Auto-disabled rule '\(rule.explanation)' due to high failure rate")
            }
            
            currentProfile = profile
            debouncedSave()
        }
    }
    
    /// Get active rules filtered by learning strength and optionally by scope
    public func getActiveRules(forFolder folderPath: String? = nil, forPersona personaId: UUID? = nil) -> [InferredRule] {
        guard let profile = currentProfile else { return [] }

        return activeRules(from: profile, folderPath: folderPath, personaId: personaId)
    }

    private func activeRules(
        from profile: LearningsProfile,
        folderPath: String?,
        personaId: UUID?
    ) -> [InferredRule] {
        let now = Date()
        let eligibleRules = profile.inferredRules
            .filter { $0.isEligible(at: now) }
            .filter { ruleMatchesScope(rule: $0, folderPath: folderPath, personaId: personaId) }
            .sorted {
                let lhs = $0.effectiveConfidence(at: now)
                let rhs = $1.effectiveConfidence(at: now)
                if lhs == rhs { return $0.priority > $1.priority }
                return lhs > rhs
            }

        guard !eligibleRules.isEmpty else { return [] }

        // Keep one strongest rule at the minimum setting so Learnings remains useful,
        // then progressively admit more rules as the user increases the strength.
        let maxRules = min(
            eligibleRules.count,
            Int(Double(eligibleRules.count) * learningStrength) + 1
        )
        return Array(eligibleRules.prefix(maxRules))
    }
    
    // MARK: - Rule Suggestion Inbox
    
    /// Get pending approval rules
    public func getPendingRules() -> [InferredRule] {
        guard let profile = currentProfile else { return [] }
        return profile.inferredRules.filter { $0.status == .pendingApproval }
    }
    
    /// Approve a pending rule
    public func approveRule(ruleId: String) async {
        guard var profile = currentProfile else { return }
        
        if let index = profile.inferredRules.firstIndex(where: { $0.id == ruleId }) {
            profile.inferredRules[index].status = .active
            currentProfile = profile
            await saveProfile()
        }
    }
    
    /// Reject a pending rule with cooling-off period
    public func rejectRule(ruleId: String, cooldownDays: Int = 30) async {
        guard var profile = currentProfile else { return }
        
        if let index = profile.inferredRules.firstIndex(where: { $0.id == ruleId }) {
            profile.inferredRules[index].status = .rejected
            profile.inferredRules[index].rejectedAt = Date()
            profile.inferredRules[index].cooldownUntil = Date().addingTimeInterval(Double(cooldownDays) * 86400)
            profile.inferredRules[index].isEnabled = false
            
            // Track cooldown
            profile.rejectedRuleCooldowns[ruleId] = Date().addingTimeInterval(Double(cooldownDays) * 86400)
            
            currentProfile = profile
            await saveProfile()
        }
    }
    
    /// Edit a pending rule's explanation and approve it
    public func editAndApproveRule(ruleId: String, newExplanation: String? = nil, newPriority: Int? = nil, newScope: RuleScope? = nil) async {
        guard var profile = currentProfile else { return }
        
        if let index = profile.inferredRules.firstIndex(where: { $0.id == ruleId }) {
            profile.inferredRules[index].status = .active
            if let explanation = newExplanation {
                let rule = profile.inferredRules[index]
                let updatedRule = InferredRule(
                    id: rule.id,
                    pattern: rule.pattern,
                    template: rule.template,
                    metadataCues: rule.metadataCues,
                    priority: newPriority ?? rule.priority,
                    exampleIds: rule.exampleIds,
                    explanation: explanation,
                    successCount: rule.successCount,
                    failureCount: rule.failureCount,
                    isEnabled: true,
                    lastAppliedAt: rule.lastAppliedAt,
                    supportCount: rule.supportCount,
                    initialConfidence: rule.initialConfidence,
                    scope: newScope ?? rule.scope,
                    status: .active,
                    evidenceIds: rule.evidenceIds,
                    evidenceDescription: rule.evidenceDescription,
                    rejectedAt: rule.rejectedAt,
                    cooldownUntil: rule.cooldownUntil
                )
                profile.inferredRules[index] = updatedRule
            } else {
                if let priority = newPriority {
                    profile.inferredRules[index].priority = priority
                }
                if let scope = newScope {
                    profile.inferredRules[index].scope = scope
                }
            }
            currentProfile = profile
            await saveProfile()
        }
    }
    
    /// Check if a rule pattern is in cooldown (was recently rejected)
    public func isRuleInCooldown(pattern: String) -> Bool {
        guard let profile = currentProfile else { return false }
        let now = Date()
        
        return profile.inferredRules.contains { rule in
            rule.pattern == pattern && rule.status == .rejected &&
            (rule.cooldownUntil ?? .distantPast) > now
        }
    }
    
    // MARK: - Learning Exclusion Patterns
    
    /// Add a path exclusion pattern (learning will be skipped for matching paths)
    public func addLearningExclusion(_ pattern: String) async {
        guard var profile = currentProfile else { return }
        let storedPattern = normalizedLearningPatternForStorage(pattern)
        guard !storedPattern.isEmpty else { return }

        let normalizedPattern = normalizedLearningPattern(storedPattern)

        if !profile.learningExclusionPatterns.map(normalizedLearningPattern).contains(normalizedPattern) {
            profile.learningExclusionPatterns.append(storedPattern)
            currentProfile = profile
            analysisResult = nil
            await pruneExcludedLearningData()
            await saveProfile()
        }
    }
    
    /// Remove a learning exclusion pattern
    public func removeLearningExclusion(_ pattern: String) async {
        guard var profile = currentProfile else { return }
        let normalizedPattern = normalizedLearningPattern(pattern)
        profile.learningExclusionPatterns.removeAll {
            normalizedLearningPattern($0) == normalizedPattern
        }
        currentProfile = profile
        analysisResult = nil
        await saveProfile()
    }
    
    /// Check if a path should be excluded from learning
    public func isPathExcludedFromLearning(_ path: String) -> Bool {
        guard let profile = currentProfile else { return false }
        let normalizedPath = normalizedLearningPath(path)
        let pathComponents = normalizedPath.split(separator: "/").map(String.init)
        let fileName = URL(fileURLWithPath: normalizedPath).lastPathComponent.lowercased()

        return profile.learningExclusionPatterns.contains { pattern in
            let normalizedPattern = normalizedLearningPattern(pattern)
            guard !normalizedPattern.isEmpty else { return false }

            if normalizedPath == normalizedPattern || normalizedPath.hasSuffix("/" + normalizedPattern) {
                return true
            }

            let patternComponents = normalizedPattern.split(separator: "/").map(String.init)
            if !patternComponents.isEmpty && pathComponents.count >= patternComponents.count {
                for start in 0...(pathComponents.count - patternComponents.count) {
                    if Array(pathComponents[start..<(start + patternComponents.count)]) == patternComponents {
                        return true
                    }
                }
            }

            return fileName == normalizedPattern || pathComponents.contains(normalizedPattern)
        }
    }
    
    // MARK: - Model Directories (Local Persistence)
    
    private static let learningsModelSelectionKey = "learningsModelSelection"
    private static let modelDirectoriesKey = "learningsModelDirectories"
    private static let maxEnabledModelDirectories = 5
    private static let maxRelevantModelDirectories = 2
    private static let maxFolderEntriesPerDirectory = 20

    private func saveLearningsModelSelection() {
        guard hasLoadedPersistedState else {
            hasPendingModelSelectionChange = true
            return
        }
        if let learningsModelSelection {
            do {
                let data = try JSONEncoder().encode(learningsModelSelection)
                userDefaults.set(data, forKey: Self.learningsModelSelectionKey)
            } catch {
                ReliabilityManager.shared.capture(
                    error: error,
                    feature: "learnings",
                    operation: "save_model_selection"
                )
                DebugLogger.log("Failed to save learnings model selection: \(error.localizedDescription)")
            }
        } else {
            userDefaults.removeObject(forKey: Self.learningsModelSelectionKey)
        }
    }

    public func setLearningsModelOverride(provider: AIProvider, model: String) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        learningsModelSelection = LearningsModelSelection(provider: provider, model: trimmedModel)
        saveLearningsModelSelection()
    }

    public func clearLearningsModelOverride() {
        learningsModelSelection = nil
        saveLearningsModelSelection()
    }

    public func effectiveAIConfig(from config: AIConfig) -> AIConfig {
        guard
            let learningsModelSelection,
            learningsModelSelection.provider == config.provider
        else {
            return config
        }

        var effectiveConfig = config
        effectiveConfig.model = learningsModelSelection.model
        return effectiveConfig
    }
    
    private func saveModelDirectories() {
        guard hasLoadedPersistedState else {
            hasPendingModelDirectoryChanges = true
            return
        }
        do {
            let data = try JSONEncoder().encode(modelDirectories)
            userDefaults.set(data, forKey: Self.modelDirectoriesKey)
        } catch {
            ReliabilityManager.shared.capture(
                error: error,
                feature: "learnings",
                operation: "save_model_directories"
            )
            DebugLogger.log("Failed to save model directories: \(error.localizedDescription)")
        }
    }
    
    /// Add a reference model directory from a URL, creating a security-scoped bookmark
    /// and triggering an initial scan. Deduplicates by canonical path.
    public func addModelDirectory(url: URL) -> Bool {
        addModelDirectoryWithResult(url: url) == .added
    }

    @discardableResult
    func addModelDirectoryWithResult(url: URL) -> ReferenceDirectoryAddResult {
        let canonical = url.standardizedFileURL.path
        guard !modelDirectories.contains(where: { $0.canonicalPath == canonical }) else {
            return .duplicate
        }
        guard modelDirectories.filter(\.isEnabled).count < Self.maxEnabledModelDirectories else {
            return .activeLimitReached
        }
        
        var bookmark: Data?
        do {
            bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            DebugLogger.log("Failed to create security-scoped bookmark for \(url.path): \(error.localizedDescription)")
        }
        
        let directory = ReferenceModelDirectory(
            path: url.path,
            bookmarkData: bookmark
        )
        modelDirectoryGeneration &+= 1
        modelDirectories.append(directory)
        modelDirectoryScanStates[directory.id] = .scanning
        saveModelDirectories()
        
        let directoryId = directory.id
        Task {
            await restoreModelDirectoryAccess()
            await rescanModelDirectory(id: directoryId)
        }
        
        return .added
    }
    
    /// Add a reference model directory by path (legacy convenience).
    /// Prefer `addModelDirectory(url:)` for proper bookmark persistence.
    public func addModelDirectory(path: String) -> Bool {
        addModelDirectory(url: URL(fileURLWithPath: path))
    }
    
    /// Add multiple directories at once, returning the count of newly added ones
    @discardableResult
    public func addModelDirectories(paths: [String]) -> Int {
        var added = 0
        for path in paths {
            if addModelDirectory(path: path) {
                added += 1
            }
        }
        return added
    }
    
    /// Remove a model directory by its ID
    public func removeModelDirectory(id: String) {
        modelDirectoryGeneration &+= 1
        stopModelDirectoryAccess(id: id)
        modelDirectories.removeAll { $0.id == id }
        modelDirectoryScanStates.removeValue(forKey: id)
        saveModelDirectories()
    }
    
    /// Toggle the enabled state of a model directory
    @discardableResult
    public func toggleModelDirectory(id: String) -> Bool {
        guard let index = modelDirectories.firstIndex(where: { $0.id == id }) else { return false }
        if modelDirectories[index].isEnabled == false,
           modelDirectories.filter(\.isEnabled).count >= Self.maxEnabledModelDirectories {
            modelDirectoryScanStates[id] = .paused
            return false
        }
        modelDirectories[index].isEnabled.toggle()
        modelDirectoryScanStates[id] = scanState(for: modelDirectories[index])
        saveModelDirectories()
        return true
    }
    
    /// Validate all directories, restoring bookmark access where needed
    public func validateModelDirectories() {
        Task { await restoreModelDirectoryAccess() }
    }
    
    /// Restore security-scoped access for all saved directories by resolving bookmarks.
    /// Updates stale bookmarks automatically.
    private func restoreModelDirectoryAccess() async {
        if let modelDirectoryRestoreTask {
            await modelDirectoryRestoreTask.value
            return
        }

        let generation = modelDirectoryGeneration
        let snapshots = modelDirectories.map { directory in
            ModelDirectoryBookmarkSnapshot(
                id: directory.id,
                bookmarkData: directory.bookmarkData,
                path: directory.path
            )
        }
        let task = Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                Self.resolveModelDirectoryBookmarks(snapshots)
            }.value
            guard let self else {
                Self.releaseModelDirectoryResults(results)
                return
            }
            self.applyModelDirectoryBookmarkResults(results, generation: generation)
        }
        modelDirectoryRestoreTask = task
        await task.value
        modelDirectoryRestoreTask = nil
    }

    private nonisolated static func resolveModelDirectoryBookmarks(
        _ snapshots: [ModelDirectoryBookmarkSnapshot]
    ) -> [ModelDirectoryBookmarkResult] {
        snapshots.map { snapshot in
            guard let bookmarkData = snapshot.bookmarkData else {
                var isDirectory = ObjCBool(false)
                let exists = FileManager.default.fileExists(
                    atPath: snapshot.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
                return ModelDirectoryBookmarkResult(
                    id: snapshot.id,
                    originalBookmark: nil,
                    resolvedURL: nil,
                    renewedBookmark: nil,
                    didAccess: false,
                    isAccessible: exists
                )
            }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), url.startAccessingSecurityScopedResource() else {
                return ModelDirectoryBookmarkResult(
                    id: snapshot.id,
                    originalBookmark: bookmarkData,
                    resolvedURL: nil,
                    renewedBookmark: nil,
                    didAccess: false,
                    isAccessible: false
                )
            }
            var isDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            let renewedBookmark = isStale ? try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) : nil
            return ModelDirectoryBookmarkResult(
                id: snapshot.id,
                originalBookmark: bookmarkData,
                resolvedURL: url,
                renewedBookmark: renewedBookmark,
                didAccess: true,
                isAccessible: exists
            )
        }
    }

    private func applyModelDirectoryBookmarkResults(
        _ results: [ModelDirectoryBookmarkResult],
        generation: Int
    ) {
        guard generation == modelDirectoryGeneration else {
            Self.releaseModelDirectoryResults(results)
            return
        }

        var didUpdate = false
        for result in results {
            guard let index = modelDirectories.firstIndex(where: { $0.id == result.id }),
                  modelDirectories[index].bookmarkData == result.originalBookmark else {
                if result.didAccess { result.resolvedURL?.stopAccessingSecurityScopedResource() }
                continue
            }
            stopModelDirectoryAccess(id: result.id)
            modelDirectoryScanStates[result.id] = scanState(
                for: modelDirectories[index],
                isAccessible: result.isAccessible
            )
            guard result.didAccess, let resolvedURL = result.resolvedURL else { continue }
            activeModelDirectoryURLs[result.id] = resolvedURL
            let resolvedPath = resolvedURL.standardizedFileURL.path
            if modelDirectories[index].path != resolvedPath {
                let directory = modelDirectories[index]
                modelDirectories[index] = ReferenceModelDirectory(
                    id: directory.id,
                    path: resolvedPath,
                    displayName: directory.displayName,
                    isEnabled: directory.isEnabled,
                    bookmarkData: directory.bookmarkData,
                    lastScannedAt: directory.lastScannedAt,
                    scanSnapshot: directory.scanSnapshot
                )
                didUpdate = true
            }
            if let renewedBookmark = result.renewedBookmark {
                modelDirectories[index].bookmarkData = renewedBookmark
                didUpdate = true
            }
        }
        if didUpdate { saveModelDirectories() }
    }

    private nonisolated static func releaseModelDirectoryResults(
        _ results: [ModelDirectoryBookmarkResult]
    ) {
        for result in results where result.didAccess {
            result.resolvedURL?.stopAccessingSecurityScopedResource()
        }
    }
    
    /// Re-scan a model directory and update its cached snapshot
    public func rescanModelDirectory(id: String) async {
        guard let index = modelDirectories.firstIndex(where: { $0.id == id }) else { return }
        
        let directory = modelDirectories[index]
        modelDirectoryScanStates[id] = .scanning
        let directoryURL = activeModelDirectoryURLs[id] ?? URL(fileURLWithPath: directory.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            DebugLogger.log("Cannot scan inaccessible directory: \(directory.displayName)")
            modelDirectoryScanStates[id] = .unavailable
            return
        }
        
        let snapshot: ReferenceDirectorySnapshot
        do {
            snapshot = try await ReferenceDirectoryScanner.scan(url: directoryURL)
        } catch is CancellationError {
            modelDirectoryScanStates[id] = scanState(for: directory)
            return
        } catch {
            DebugLogger.log(
                "Preserving previous snapshot for \(directory.displayName) after scan failure: \(error.localizedDescription)"
            )
            modelDirectoryScanStates[id] = .failed(error.localizedDescription)
            return
        }
        
        guard let currentIndex = modelDirectories.firstIndex(where: { $0.id == id }) else { return }
        modelDirectories[currentIndex].scanSnapshot = snapshot
        modelDirectories[currentIndex].lastScannedAt = snapshot.scannedAt
        modelDirectoryScanStates[id] = snapshot.warnings.isEmpty
            ? .ready
            : .warning(snapshot.warnings.joined(separator: ". "))
        saveModelDirectories()
    }

    public func modelDirectoryScanState(id: String) -> ReferenceDirectoryScanState {
        if let state = modelDirectoryScanStates[id] { return state }
        guard let directory = modelDirectories.first(where: { $0.id == id }) else {
            return .unavailable
        }
        return scanState(for: directory)
    }

    private func refreshModelDirectoryScanStates() {
        modelDirectoryScanStates = Dictionary(
            uniqueKeysWithValues: modelDirectories.map { ($0.id, scanState(for: $0)) }
        )
    }

    private func scanState(for directory: ReferenceModelDirectory) -> ReferenceDirectoryScanState {
        scanState(for: directory, isAccessible: directory.isAccessible)
    }

    private func scanState(
        for directory: ReferenceModelDirectory,
        isAccessible: Bool
    ) -> ReferenceDirectoryScanState {
        guard isAccessible else { return .unavailable }
        guard directory.isEnabled else { return .paused }
        guard let snapshot = directory.scanSnapshot else { return .scanning }
        guard snapshot.warnings.isEmpty else {
            return .warning(snapshot.warnings.joined(separator: ". "))
        }
        return .ready
    }

    private func stopModelDirectoryAccess(id: String) {
        guard let url = activeModelDirectoryURLs.removeValue(forKey: id) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    private func stopAllModelDirectoryAccess() {
        for url in activeModelDirectoryURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        activeModelDirectoryURLs.removeAll()
    }
    
    /// Returns enabled, accessible reference directory paths (capped at maxEnabledModelDirectories)
    public func enabledModelDirectoryPaths() -> [String] {
        modelDirectories
            .filter { $0.isEnabled && $0.isAccessible }
            .prefix(Self.maxEnabledModelDirectories)
            .map { $0.path }
    }
    
    /// Build a reference-directory context string for prompt injection.
    /// Uses cached snapshots when available, falling back to live scan via PromptBuilder.
    public func generateModelDirectoryContext() -> String {
        let enabledDirs = modelDirectories
            .filter { $0.isEnabled && $0.isAccessible }
            .prefix(Self.maxEnabledModelDirectories)
        
        let snapshots = enabledDirs.compactMap { dir -> (String, ReferenceDirectorySnapshot)? in
            guard let snapshot = dir.scanSnapshot else { return nil }
            return (dir.displayName, snapshot)
        }
        
        guard !snapshots.isEmpty else {
            let paths = enabledDirs.map(\.path)
            guard !paths.isEmpty else { return "" }
            return PromptBuilder.buildReferenceDirectoryContext(paths: Array(paths))
        }
        
        return formatSnapshotContext(snapshots: snapshots)
    }

    func selectModelDirectoryContext(for files: [FileItem]) -> ReferenceDirectorySelection? {
        let incomingFileExtensions = files.lazy
            .filter { $0.isDirectory == false }
            .map { file in
                let explicitExtension = file.extension.trimmingCharacters(in: .whitespacesAndNewlines)
                return explicitExtension.isEmpty
                    ? URL(fileURLWithPath: file.path).pathExtension.lowercased()
                    : explicitExtension.lowercased()
            }
        let incomingCategories = Set(
            incomingFileExtensions.map { FileCategory.from(extension: $0) }
        )
        let incomingExtensions = Set(
            incomingFileExtensions.filter { $0.isEmpty == false }
        )
        guard incomingCategories.isEmpty == false else { return nil }

        let matches = modelDirectories.compactMap { directory -> (ReferenceModelDirectory, Int)? in
            guard directory.isEnabled,
                  directory.isAccessible,
                  let snapshot = directory.scanSnapshot,
                  snapshot.needsRescan == false else { return nil }
            let exampleCategories = Set(
                snapshot.fileCategoryDistribution.compactMap { $0.value > 0 ? $0.key : nil }
            )
            let categoryOverlap = incomingCategories.intersection(exampleCategories).count
            guard categoryOverlap > 0 else { return nil }
            let exampleExtensions = Set(snapshot.fileExtensionDistribution.keys)
            let extensionOverlap = incomingExtensions.intersection(exampleExtensions).count
            return (directory, categoryOverlap * 100 + extensionOverlap)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.id < rhs.0.id
        }
        .prefix(Self.maxRelevantModelDirectories)

        guard matches.isEmpty == false else { return nil }
        let selected = matches.map { $0.0 }
        let snapshots = selected.compactMap { directory in
            directory.scanSnapshot.map { (directory.displayName, $0) }
        }
        let names = selected.map(\.displayName).joined(separator: ", ")
        return ReferenceDirectorySelection(
            directoryIDs: selected.map(\.id),
            reason: "Matched incoming file types to \(names)",
            context: formatSnapshotContext(snapshots: snapshots)
        )
    }

    public func generateModelDirectoryContext(for files: [FileItem]) -> String {
        selectModelDirectoryContext(for: files)?.context ?? ""
    }
    
    /// Format cached snapshots into a compact prompt context string (~15 lines max)
    private func formatSnapshotContext(snapshots: [(String, ReferenceDirectorySnapshot)]) -> String {
        var lines: [String] = [
            "## REFERENCE MODEL DIRECTORIES",
            "The user has provided the following well-organized directories as examples of their preferred folder structure and naming conventions. Treat these as few-shot examples: infer the convention, then apply the same style to similar incoming files. Match hierarchy depth, folder names, ordering, and filename patterns when relevant."
        ]
        
        for (name, snapshot) in snapshots {
            lines.append("")
            lines.append("Reference: \"\(name)\" (\(snapshot.totalFolderCount) folders, \(snapshot.totalFileCount) files)")
            
            if !snapshot.namingConventions.isEmpty {
                lines.append("  Folder naming: \(snapshot.namingConventions.joined(separator: ", "))")
            }
            if !snapshot.fileNamingConventions.isEmpty {
                lines.append("  File naming: \(snapshot.fileNamingConventions.joined(separator: ", "))")
            }
            
            let topFolders = snapshot.folderHierarchy.prefix(Self.maxFolderEntriesPerDirectory)
            for folder in topFolders {
                let typeInfo = folder.fileTypeDistribution
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { "\($0.key):\($0.value)" }
                    .joined(separator: ", ")
                let suffix = typeInfo.isEmpty ? "" : " [\(typeInfo)]"
                lines.append("  - \(folder.relativePath)\(suffix)")
                if !folder.sampleFileNames.isEmpty {
                    lines.append("    examples: \(folder.sampleFileNames.prefix(3).joined(separator: ", "))")
                }
            }
            
            if snapshot.folderHierarchy.count > Self.maxFolderEntriesPerDirectory {
                lines.append("  ... (\(snapshot.folderHierarchy.count - Self.maxFolderEntriesPerDirectory) more folders)")
            }
        }
        
        lines.append("")
        lines.append("IMPORTANT: These are reference examples only — do NOT move files into the reference directories. Instead, recreate analogous destination folders and names in the current organization plan. Sample filenames may come from the user's reference folders. If the input resembles a media library, prefer inferred media conventions such as Artist/Album/Track, Movie (Year), Season/Episode, or date/event folders when the examples demonstrate them.")
        
        return lines.joined(separator: "\n")
    }

    private func shouldExcludeLearning(paths: [String]) -> Bool {
        paths.contains(where: isPathExcludedFromLearning)
    }

    private func normalizedLearningPattern(_ pattern: String) -> String {
        var normalized = pattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\", with: "/")

        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }

        if normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }

        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        return normalized
    }

    private func normalizedLearningPatternForStorage(_ pattern: String) -> String {
        var normalized = pattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }

        if normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }

        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        return normalized
    }

    private func normalizedLearningPath(_ path: String) -> String {
        normalizedLearningPattern(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    func filteredLearningProfile(from profile: LearningsProfile) -> LearningsProfile {
        guard !profile.learningExclusionPatterns.isEmpty else { return profile }

        var filtered = profile

        filtered.additionalInstructionsHistory = profile.additionalInstructionsHistory.filter { instruction in
            guard let folderPath = instruction.folderPath else { return true }
            return !isPathExcludedFromLearning(folderPath)
        }
        filtered.guidingInstructionsHistory = profile.guidingInstructionsHistory.filter { instruction in
            guard let folderPath = instruction.folderPath else { return true }
            return !isPathExcludedFromLearning(folderPath)
        }
        filtered.steeringPrompts = profile.steeringPrompts.filter { prompt in
            guard let folderPath = prompt.folderPath else { return true }
            return !isPathExcludedFromLearning(folderPath)
        }
        filtered.postOrganizationChanges = profile.postOrganizationChanges.filter {
            !shouldExcludeLearning(paths: [$0.originalPath, $0.newPath].filter { !$0.isEmpty })
        }
        filtered.renameFeedbackHistory = profile.renameFeedbackHistory.filter { event in
            guard let folderPath = event.folderPath else { return true }
            return !isPathExcludedFromLearning(folderPath)
        }
        filtered.cancelledOrganizations = profile.cancelledOrganizations.filter {
            !isPathExcludedFromLearning($0.folderPath)
        }
        filtered.regeneratedOrganizations = profile.regeneratedOrganizations.filter {
            !isPathExcludedFromLearning($0.folderPath)
        }
        filtered.regenerationPreferenceEvidence = profile.regenerationPreferenceEvidence.filter {
            !isPathExcludedFromLearning($0.folderPath)
        }
        filtered.historyReverts = profile.historyReverts.filter { revert in
            guard let folderPath = revert.folderPath else { return true }
            return !isPathExcludedFromLearning(folderPath)
        }
        filtered.corrections = profile.corrections.filter {
            !shouldExcludeLearning(paths: [$0.srcPath, $0.dstPath])
        }
        filtered.rejections = profile.rejections.filter {
            !shouldExcludeLearning(paths: [$0.srcPath, $0.dstPath])
        }
        filtered.positiveExamples = profile.positiveExamples.filter {
            !shouldExcludeLearning(paths: [$0.srcPath, $0.dstPath])
        }
        filtered.sessions = profile.sessions.filter { session in
            !isPathExcludedFromLearning(session.folderPath)
        }.map { session in
            var updated = session
            updated.filesMoved = session.filesMoved.filter {
                !shouldExcludeLearning(paths: [$0.sourcePath, $0.destinationPath])
            }
            updated.userCorrections = session.userCorrections.filter {
                !shouldExcludeLearning(paths: [$0.originalPath, $0.newPath].filter { !$0.isEmpty })
            }
            updated.folderPatterns = session.folderPatterns.filter { pattern in
                !pattern.relativePath.isEmpty
            }
            return updated
        }

        let excludedExampleIDs = Set(profile.corrections.map(\.id))
            .subtracting(Set(filtered.corrections.map(\.id)))
            .union(Set(profile.rejections.map(\.id)).subtracting(Set(filtered.rejections.map(\.id))))
            .union(Set(profile.positiveExamples.map(\.id)).subtracting(Set(filtered.positiveExamples.map(\.id))))
            .union(
                Set(profile.regenerationPreferenceEvidence.map(\.id))
                    .subtracting(Set(filtered.regenerationPreferenceEvidence.map(\.id)))
            )

        if !excludedExampleIDs.isEmpty {
            filtered.inferredRules = filtered.inferredRules.filter { rule in
                let usesExcludedExample = !Set(rule.exampleIds).isDisjoint(with: excludedExampleIDs)
                let usesExcludedEvidence = !Set(rule.evidenceIds).isDisjoint(with: excludedExampleIDs)
                return !usesExcludedExample && !usesExcludedEvidence
            }
        }

        return filtered
    }

    private func learningProfileSnapshot(_ profile: LearningsProfile) -> [Int] {
        [
            profile.additionalInstructionsHistory.count,
            profile.guidingInstructionsHistory.count,
            profile.steeringPrompts.count,
            profile.postOrganizationChanges.count,
            profile.renameFeedbackHistory.count,
            profile.historyReverts.count,
            profile.cancelledOrganizations.count,
            profile.regeneratedOrganizations.count,
            profile.regenerationPreferenceEvidence.count,
            profile.corrections.count,
            profile.rejections.count,
            profile.positiveExamples.count,
            profile.inferredRules.count,
            profile.sessions.count
        ]
    }

    private func pruneExcludedLearningData() async {
        guard let profile = currentProfile else { return }
        let filtered = filteredLearningProfile(from: profile)
        guard learningProfileSnapshot(filtered) != learningProfileSnapshot(profile) else { return }
        currentProfile = filtered
        await saveProfile()
    }

    private func ruleMatchesScope(rule: InferredRule, folderPath: String?, personaId: UUID?) -> Bool {
        if folderPath == nil && personaId == nil {
            return true
        }

        switch rule.scope {
        case .global:
            return true
        case .folder(let rulePath):
            guard let folderPath else { return false }
            return folderPath.hasPrefix(rulePath) || rulePath == folderPath
        case .activePersona(let rulePersonaId):
            guard let personaId else { return false }
            return rulePersonaId == personaId
        }
    }

    private func mergeInferredRules(existing: [InferredRule], new: [InferredRule]) -> [InferredRule] {
        var merged: [String: InferredRule] = [:]

        for rule in existing {
            merged["\(rule.pattern)|\(rule.template)"] = rule
        }

        for rule in new {
            let key = "\(rule.pattern)|\(rule.template)"
            if let existingRule = merged[key] {
                merged[key] = InferredRule(
                    id: existingRule.id,
                    pattern: rule.pattern,
                    template: rule.template,
                    metadataCues: Array(Set(existingRule.metadataCues + rule.metadataCues)),
                    priority: max(existingRule.priority, rule.priority),
                    exampleIds: Array(Set(existingRule.exampleIds + rule.exampleIds)),
                    explanation: rule.explanation,
                    successCount: existingRule.successCount,
                    failureCount: existingRule.failureCount,
                    isEnabled: existingRule.isEnabled,
                    lastAppliedAt: existingRule.lastAppliedAt ?? rule.lastAppliedAt,
                    supportCount: max(existingRule.supportCount, rule.supportCount),
                    initialConfidence: rule.initialConfidence ?? existingRule.initialConfidence,
                    scope: rule.scope,
                    status: existingRule.status,
                    evidenceIds: Array(Set(existingRule.evidenceIds + rule.evidenceIds)),
                    evidenceDescription: rule.evidenceDescription ?? existingRule.evidenceDescription,
                    rejectedAt: existingRule.rejectedAt,
                    cooldownUntil: existingRule.cooldownUntil
                )
            } else {
                merged[key] = rule
            }
        }

        return merged.values.sorted { $0.priority > $1.priority }
    }
}

// MARK: - Errors

public enum LearningsError: LocalizedError {
    case noProject
    case noAnalysisResult

    public var errorDescription: String? {
        switch self {
        case .noProject:
            return "No project is currently loaded"
        case .noAnalysisResult:
            return "No analysis result available. Run analysis first."
        }
    }
}
