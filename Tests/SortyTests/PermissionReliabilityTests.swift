import CoreServices
import Foundation
import XCTest

@testable import SortyLib
@testable import SortyCore

final class PermissionReliabilityTests: XCTestCase {
    func testAutomationCheckRunsAfterUserIntentEnablesChecks() {
        XCTAssertTrue(FinderAutomation.canCheckPermission(checksEnabled: true))
    }

    func testAutomationCheckDoesNotRunBeforeUserIntent() {
        XCTAssertFalse(FinderAutomation.canCheckPermission(checksEnabled: false))
    }

    func testAutomationPermissionChecksFinderReadAccess() {
        XCTAssertEqual(
            FinderAutomation.permissionEventClass,
            AEEventClass(kAECoreSuite)
        )
        XCTAssertEqual(
            FinderAutomation.permissionEventID,
            AEEventID(kAEGetData)
        )
        XCTAssertNotEqual(
            FinderAutomation.permissionEventID,
            AEEventID(kAEOpenApplication)
        )
    }

    func testFullDiskAccessProbeReadsAnActualFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let readableFile = directory.appendingPathComponent("probe.txt")
        try Data("ok".utf8).write(to: readableFile)

        XCTAssertTrue(FullDiskAccessProbe.hasReadAccess(toAny: [readableFile.path]))
        XCTAssertFalse(
            FullDiskAccessProbe.hasReadAccess(
                toAny: [directory.appendingPathComponent("missing").path]
            )
        )
    }
}
