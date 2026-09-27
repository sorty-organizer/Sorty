//
//  NotificationCompletionTests.swift
//  SortyTests
//
//  Regression tests for completion notifications: the Processing Complete
//  toggle must gate batch summaries (the event real flows fire), and the
//  completion sound must only play for successful completions.
//

import XCTest
@testable import SortyLib
@testable import SortyCore

@MainActor
final class NotificationCompletionTests: XCTestCase {
    private var savedSettings: NotificationSettings!

    override func setUp() async throws {
        savedSettings = NotificationSettingsManager.shared.settings
        NotificationManager.shared.clearAnalytics()
    }

    override func tearDown() async throws {
        NotificationSettingsManager.shared.settings = savedSettings
        NotificationManager.shared.clearAnalytics()
        savedSettings = nil
    }

    private func setCompletionSettings(processingComplete: Bool, batchSummary: Bool) {
        var settings = NotificationSettingsManager.shared.settings
        settings.processingComplete = processingComplete
        settings.batchSummary = batchSummary
        // Keep the suite silent; sound gating is covered below without audio.
        settings.playCompletionSound = false
        NotificationSettingsManager.shared.settings = settings
    }

    private func successfulStats() -> BatchSummaryStats {
        BatchSummaryStats(
            filesMoved: 12,
            foldersCreated: 3,
            duration: 8,
            folderName: "Downloads",
            folderPath: NSHomeDirectory() + "/Downloads"
        )
    }

    private func suppressedBatchSummaries() -> [NotificationAnalyticsEvent] {
        NotificationManager.shared.analyticsEvents.filter {
            $0.eventType == .suppressed && $0.notificationType == "batchSummary"
        }
    }

    func testBatchSummarySuppressedWhenProcessingCompleteDisabled() {
        setCompletionSettings(processingComplete: false, batchSummary: true)

        NotificationManager.shared.show(.batchSummary(stats: successfulStats()))

        XCTAssertFalse(
            suppressedBatchSummaries().isEmpty,
            "batchSummary must be suppressed when Processing Complete is off"
        )
    }

    func testBatchSummaryShownWhenProcessingCompleteEnabled() {
        setCompletionSettings(processingComplete: true, batchSummary: true)

        NotificationManager.shared.show(.batchSummary(stats: successfulStats()))

        XCTAssertTrue(
            suppressedBatchSummaries().isEmpty,
            "batchSummary must fire when Processing Complete is on"
        )
    }

    func testCompletionSoundOnlyForSuccessfulCompletions() {
        let manager = NotificationManager.shared

        XCTAssertTrue(manager.shouldPlayCompletionSound(
            for: .processingComplete(fileCount: 5, folderName: "Downloads", folderPath: nil, canUndo: false)
        ))
        XCTAssertTrue(manager.shouldPlayCompletionSound(for: .batchSummary(stats: successfulStats())))

        XCTAssertFalse(manager.shouldPlayCompletionSound(for: .batchSummary(stats: BatchSummaryStats())))
        XCTAssertFalse(manager.shouldPlayCompletionSound(for: .batchSummary(stats: BatchSummaryStats(
            filesMoved: 1,
            errorsEncountered: 1,
            duration: 2,
            folderName: "Downloads"
        ))))
        XCTAssertFalse(manager.shouldPlayCompletionSound(for: .previewReady(folderName: "Downloads")))
        XCTAssertFalse(manager.shouldPlayCompletionSound(for: .processingError(message: "boom", isCritical: false)))
        XCTAssertFalse(manager.shouldPlayCompletionSound(for: .info(title: "t", message: "m")))
    }
}
