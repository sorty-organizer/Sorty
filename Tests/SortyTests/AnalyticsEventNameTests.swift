import Foundation
import XCTest
@testable import SortyCore

final class AnalyticsEventNameTests: XCTestCase {
    func testReadableNamesFromIdentifiers() {
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "organize", stage: "plan_ready", outcome: "success"), "Organize Plan Ready")
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "organize", stage: "plan_generation", outcome: "failed"), "Organize Plan Generation Failed")
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "duplicate_scan", stage: "cancelled", outcome: "cancelled"), "Duplicate Scan Cancelled")
        XCTAssertEqual(AnalyticsEventName.feature(subfeature: "health_check", action: "completed", outcome: "success"), "Health Check Completed")
        XCTAssertEqual(AnalyticsEventName.feature(subfeature: "custom_personas", action: "persona_selected", outcome: "success"), "Custom Personas Selected")
        XCTAssertEqual(AnalyticsEventName.buttonClicked("apply_changes"), "Apply Changes Clicked")
        XCTAssertEqual(AnalyticsEventName.screenName(screen: "settings", section: "advanced"), "Settings › Advanced")
        XCTAssertEqual(AnalyticsEventName.screenName(screen: "settings_ai_provider", section: "ai_provider"), "Settings › AI Provider")
    }

    func testAppLifecycleNames() {
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "app", stage: "deleted", outcome: "success"), "App Deleted")
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "app", stage: "moved", outcome: "success"), "App Moved")
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "app", stage: "move", outcome: "failed"), "App Move Failed")
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "app", stage: "move", outcome: "cancelled"), "App Move Cancelled")
    }

    func testMoveFailureClassification() {
        XCTAssertEqual(AppRelocationService.classifyMoveFailure("execution error: User canceled. (-128)"), .cancelled)
        guard case let .failed(_, reason) = AppRelocationService.classifyMoveFailure("execution error: The administrator user name or password was incorrect. (-60007)") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(reason, "not_authorized")
        guard case let .failed(message, other) = AppRelocationService.classifyMoveFailure("") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(other, "script_failed")
        XCTAssertFalse(message.isEmpty)
    }

    @MainActor
    func testMoveScriptReplacesExistingCopyAndRestoresItOnFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SortyMoveScript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Downloads/Sorty.app", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let destination = applications.appendingPathComponent("Sorty.app", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        for directory in [source, destination, trash] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("new".utf8).write(to: source.appendingPathComponent("marker"))
        try Data("old".utf8).write(to: destination.appendingPathComponent("marker"))

        @MainActor func run(_ source: URL) -> (status: Int32, error: String) {
            // Same script without the password prompt; temp paths need no root.
            let script = AppRelocationService.moveScript(source: source, destination: destination, trashDirectory: trash)
                .replacingOccurrences(of: " with administrator privileges", with: "")
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardError = errors
            try? process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let missing = run(root.appendingPathComponent("Missing.app"))
        XCTAssertNotEqual(missing.status, 0)
        guard case let .failed(_, reason) = AppRelocationService.classifyMoveFailure(missing.error) else {
            return XCTFail("expected failure, got \(missing.error)")
        }
        XCTAssertEqual(reason, "source_missing")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Sorty.app"])

        XCTAssertEqual(run(source).status, 0)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Sorty.app"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
    }

    func testMoveFailureNamesTheBlockedStep() {
        let replace = AppRelocationService.classifyMoveFailure(
            "0:412: execution error: mv: rename /Applications/Sorty.app to /Applications/.Sorty-replaced.app: Operation not permitted (10)"
        )
        guard case let .failed(_, replaceReason) = replace else { return XCTFail("expected failure") }
        XCTAssertEqual(replaceReason, "replace_blocked")

        let source = AppRelocationService.classifyMoveFailure(
            "0:412: execution error: mv: /Users/me/Downloads/Sorty.app: Operation not permitted (11)"
        )
        guard case let .failed(message, sourceReason) = source else { return XCTFail("expected failure") }
        XCTAssertEqual(sourceReason, "source_blocked")
        XCTAssertFalse(message.contains("/Users/me"))
    }

    func testValidationRejectsUnboundedNames() {
        XCTAssertTrue(AnalyticsEventName.isValid("Organize Plan Ready"))
        XCTAssertFalse(AnalyticsEventName.isValid("app:feature_used"))
        XCTAssertFalse(AnalyticsEventName.isValid("/Users/me/Documents"))
        XCTAssertFalse(AnalyticsEventName.isValid(String(repeating: "A", count: 81)))
    }

    func testCountryCodeComesFromRegionSetting() {
        XCTAssertEqual(AnalyticsManager.countryCode(locale: Locale(identifier: "en_GB")), "GB")
    }
}
