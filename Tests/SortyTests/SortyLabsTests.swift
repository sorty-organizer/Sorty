//
//  SortyLabsTests.swift
//  SortyTests
//
//  Routing rules, project clusters and expiring files (Labs).
//

import Foundation
import XCTest
@testable import SortyAI
@testable import SortyCore
@testable import SortyFS
@testable import SortyModels
@testable import SortyOrganizer

final class SortyLabsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SortyLabsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Routing Rules

    func testRoutingDestinationsStayInsideTheOrganizedFolder() {
        XCTAssertEqual(RoutingRule.sanitizedTemplate("/Finance//Statements/"), "Finance/Statements")
        XCTAssertEqual(RoutingRule.sanitizedTemplate("~/Taxes/{YYYY}"), "Taxes/{YYYY}")
        XCTAssertEqual(RoutingRule.sanitizedTemplate("../Elsewhere"), "")
    }

    func testFirstMatchingRoutingRuleFillsDateTokens() throws {
        let statements = RoutingRule(
            sourceText: "Bank statements go to Finance",
            conditions: [ExclusionRule(type: .fileName, pattern: "statement")],
            destinationTemplate: "Finance/{YYYY}-{MM}"
        )
        let images = RoutingRule(
            sourceText: "Images go to Pictures",
            conditions: [ExclusionRule(type: .fileType, fileTypeCategory: .images)],
            destinationTemplate: "Pictures"
        )
        let matcher = RoutingRuleMatcher(rules: [statements, images])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let created = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))

        let pdf = FileItem(path: "/tmp/Chase Statement.pdf", name: "Chase Statement", extension: "pdf", creationDate: created)
        let rule = try XCTUnwrap(matcher.firstMatch(for: pdf))
        XCTAssertEqual(rule.id, statements.id)
        XCTAssertEqual(rule.destination(for: pdf, calendar: calendar), "Finance/2026-03")

        let note = FileItem(path: "/tmp/notes.txt", name: "notes", extension: "txt")
        XCTAssertNil(matcher.firstMatch(for: note))
    }

    func testDisabledRoutingRulesNeverMatch() {
        let rule = RoutingRule(
            sourceText: "Statements",
            conditions: [ExclusionRule(type: .fileName, pattern: "statement")],
            destinationTemplate: "Finance",
            isEnabled: false
        )
        XCTAssertTrue(RoutingRuleMatcher(rules: [rule]).isEmpty)
    }

    func testRoutingResolutionDecodesConditionsAndDestination() throws {
        let response = """
        {"destination":"/Finance/Statements/{YYYY}","tools":[{"kind":"file_name_contains","pattern":"statement","description":"Statements"}]}
        """
        let resolution = try NaturalLanguageExclusionResolver.decodeRouting(from: response)
        XCTAssertEqual(resolution.destinationTemplate, "Finance/Statements/{YYYY}")
        XCTAssertEqual(resolution.conditions.map(\.type), [.fileName])
    }

    func testRoutingResolutionRequiresADestination() {
        let response = #"{"destination":"","tools":[{"kind":"file_extension","pattern":"pdf"}]}"#
        XCTAssertThrowsError(try NaturalLanguageExclusionResolver.decodeRouting(from: response))
    }

    // MARK: - Project Detection

    func testClustersNeedSharedWordAcrossFileKinds() {
        let files = [
            file("Tokyo-Day1.jpg"), file("Tokyo-Day2.heic"), file("Tokyo Hotel Booking.pdf"),
            file("invoice-1.pdf"), file("invoice-2.pdf"), file("invoice-3.pdf"),
            file("IMG_0001.jpg"), file("IMG_0002.jpg"), file("IMG_0003.png"),
        ]
        let clusters = ProjectClusterDetector.detect(in: files)
        XCTAssertEqual(clusters.map(\.label), ["tokyo"])
        XCTAssertEqual(clusters.first?.fileNames.count, 3)
    }

    func testProjectRootsAreRecognizedByMarkers() throws {
        let repo = tempDirectory.appendingPathComponent("App", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let plain = tempDirectory.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        XCTAssertTrue(ProjectFolderDetector.isProjectRoot(repo))
        XCTAssertFalse(ProjectFolderDetector.isProjectRoot(plain))
    }

    // MARK: - Expiring Files

    func testOnlyShortLivedKindsExpireAutomatically() {
        XCTAssertEqual(ExpiringFilesManager.reasonForKind(of: URL(fileURLWithPath: "/x/Setup.dmg")), .installer)
        XCTAssertEqual(ExpiringFilesManager.reasonForKind(of: URL(fileURLWithPath: "/x/Archive.zip")), .archive)
        XCTAssertEqual(ExpiringFilesManager.reasonForKind(of: URL(fileURLWithPath: "/x/Screenshot 1.png")), .screenshot)
        XCTAssertNil(ExpiringFilesManager.reasonForKind(of: URL(fileURLWithPath: "/x/Report.pdf")))
    }

    func testMarkedFilesExpireRegardlessOfKind() {
        let url = tempDirectory.appendingPathComponent("Notes.txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        let candidates = ExpiringFilesManager.scan(
            folders: [tempDirectory],
            cutoff: Date().addingTimeInterval(-14 * 86_400),
            kept: [],
            marks: [ExpiringFilesManager.key(for: url): Date().addingTimeInterval(-60)]
        )
        XCTAssertEqual(candidates.map(\.reason), [.markedByYou])
    }

    func testInboxMoveNeverOverwrites() throws {
        let destination = tempDirectory.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destination.appendingPathComponent("a.png").path, contents: Data())
        let source = tempDirectory.appendingPathComponent("a.png")
        FileManager.default.createFile(atPath: source.path, contents: Data())

        let moved = try DownloadsInboxManager.move(source, into: destination)
        XCTAssertEqual(moved.lastPathComponent, "a 2.png")
    }

    private func file(_ name: String) -> FileItem {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return FileItem(path: url.path, name: url.deletingPathExtension().lastPathComponent, extension: url.pathExtension)
    }
}
