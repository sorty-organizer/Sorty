//
//  DeeplinkTests.swift
//  SortyTests
//
//  Tests for deeplink URL parsing and navigation
//

import XCTest
@testable import SortyLib
@testable import SortyCore

final class DeeplinkTests: XCTestCase {
    
    // MARK: - URL Parsing Table
    
    @MainActor
    func testDeeplinkParsingTable() {
        let entryID = UUID(uuidString: "93DC199E-F79F-436E-8F36-9EA949227CB6")!
        let cases: [(url: String, expected: DeeplinkDestination?)] = [
            (
                "sorty://organize?path=/Users/test/Downloads&persona=developer",
                .organize(path: "/Users/test/Downloads", persona: "developer", mode: nil, autostart: false)
            ),
            (
                "sorty://organize?path=/tmp&autostart=true",
                .organize(path: "/tmp", persona: nil, mode: nil, autostart: true)
            ),
            (
                "sorty://organize",
                .organize(path: nil, persona: nil, mode: nil, autostart: false)
            ),
            (
                "sorty://organize?path=/tmp&mode=renameOnly&autostart=true",
                .organize(path: "/tmp", persona: nil, mode: .renameOnly, autostart: true)
            ),
            (
                "sorty://scan?path=/tmp/Inbox",
                .organize(path: "/tmp/Inbox", persona: nil, mode: nil, autostart: true)
            ),
            (
                "sorty://organize?path=/Users/test/My%20Documents",
                .organize(path: "/Users/test/My Documents", persona: nil, mode: nil, autostart: false)
            ),
            (
                "sorty://organize?path=/tmp/%E6%96%87%E4%BB%B6",
                .organize(path: "/tmp/文件", persona: nil, mode: nil, autostart: false)
            ),
            (
                "sorty:///Users/test/Downloads",
                .organize(path: "/Users/test/Downloads", persona: nil, mode: nil, autostart: false)
            ),
            (
                "sorty://duplicates?path=/tmp/test",
                .duplicates(path: "/tmp/test", autostart: false)
            ),
            (
                "sorty://duplicates?path=/tmp/test&autostart=true",
                .duplicates(path: "/tmp/test", autostart: true)
            ),
            (
                "sorty://learnings?project=Photos",
                .learnings(action: nil, project: "Photos")
            ),
            (
                "sorty://settings",
                .settings(section: nil)
            ),
            (
                "sorty://settings?section=provider",
                .settings(section: "provider")
            ),
            (
                "sorty://settings?section=notifications",
                .settings(section: "notifications")
            ),
            (
                "sorty://SeTTings?section=help",
                .settings(section: "help")
            ),
            (
                "sorty://help?section=personas",
                .help(section: "personas")
            ),
            (
                "sorty://open",
                .open(path: nil)
            ),
            (
                "sorty://open?path=/tmp/test",
                .open(path: "/tmp/test")
            ),
            (
                "sorty://history",
                .history()
            ),
            (
                "sorty://history?entry=93DC199E-F79F-436E-8F36-9EA949227CB6",
                .history(entryID: entryID)
            ),
            (
                "sorty://persona?action=generate&prompt=Organize%20my%20music",
                .persona(action: "generate", prompt: "Organize my music", generate: false)
            ),
            (
                "sorty://watched?action=add&path=/Users/test/Code",
                .watched(action: "add", path: "/Users/test/Code")
            ),
            (
                "sorty://watched",
                .watched(action: nil, path: nil)
            ),
            (
                "sorty://rules?action=add&pattern=*.tmp",
                .rules(action: "add", type: nil, pattern: "*.tmp")
            ),
            (
                "sorty://exclusions?action=add&pattern=*.tmp",
                .exclusions(action: "add", pattern: "*.tmp")
            ),
            (
                "sorty://storage?action=add&path=/tmp/archive",
                .storage(action: "add", path: "/tmp/archive")
            ),
            ("sorty://unknown", nil),
        ]

        let handler = DeeplinkHandler.shared
        handler.clearPending()
        for testCase in cases {
            guard let url = URL(string: testCase.url) else {
                XCTFail("Invalid test URL: \(testCase.url)")
                continue
            }
            handler.handle(url: url)
            XCTAssertEqual(handler.pendingDestination, testCase.expected, "Parsing failed for \(testCase.url)")
            handler.clearPending()
        }
    }

    // MARK: - Pending-State Side Effects
    
    @MainActor
    func testUnknownDeeplinkClearsPriorDestination() {
        let handler = DeeplinkHandler.shared
        
        handler.handle(url: URL(string: "sorty://history")!)
        XCTAssertEqual(handler.pendingDestination, .history())
        
        handler.handle(url: URL(string: "sorty://unknown")!)
        XCTAssertNil(handler.pendingDestination)
    }
    
    @MainActor
    func testWrongScheme() {
        let handler = DeeplinkHandler.shared
        
        handler.handle(url: URL(string: "sorty://history")!)
        XCTAssertEqual(handler.pendingDestination, .history())
        
        let url = URL(string: "https://organize")!
        handler.handle(url: url)
        
        XCTAssertNil(handler.pendingDestination)
    }
    
    // MARK: - URL Generation Round-Trip
    
    @MainActor
    func testGenerateRoundTrip() {
        let entryID = UUID(uuidString: "93DC199E-F79F-436E-8F36-9EA949227CB6")!
        let cases: [(destination: DeeplinkDestination, urlString: String)] = [
            (.organize(path: "/test/path", persona: nil, mode: nil, autostart: false), "sorty://organize?path=/test/path"),
            (.organize(path: "/test/path", persona: nil, mode: .renameOnly, autostart: true), "sorty://organize?path=/test/path&mode=renameOnly&autostart=true"),
            (.settings(section: nil), "sorty://settings"),
            (.history(entryID: entryID), "sorty://history?entry=93DC199E-F79F-436E-8F36-9EA949227CB6"),
            (.open(path: nil), "sorty://open"),
            (.open(path: "/tmp/test"), "sorty://open?path=/tmp/test"),
            (.learnings(action: nil, project: "MyProject"), "sorty://learnings?project=MyProject"),
            (.persona(action: "generate", prompt: "Test prompt", generate: true), "sorty://persona?action=generate&prompt=Test%20prompt&generate=true"),
            (.exclusions(action: "add", pattern: "*.log"), "sorty://exclusions?action=add&pattern=*.log"),
            (.storage(action: "add", path: "/tmp/archive"), "sorty://storage?action=add&path=/tmp/archive"),
        ]

        let handler = DeeplinkHandler.shared
        for testCase in cases {
            let url = DeeplinkHandler.url(for: testCase.destination)
            XCTAssertEqual(url?.absoluteString, testCase.urlString, "Generated URL mismatch for \(testCase.destination)")

            guard let url else { continue }
            handler.handle(url: url)
            XCTAssertEqual(handler.pendingDestination, testCase.destination, "Round-trip failed for \(testCase.urlString)")
            handler.clearPending()
        }
    }
}
