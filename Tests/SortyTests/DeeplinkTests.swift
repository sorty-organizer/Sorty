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
    
    // MARK: - URL Parsing Tests
    
    @MainActor
    func testOrganizeDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://organize?path=/Users/test/Downloads&persona=developer")!
        handler.handle(url: url)
        
        if case .organize(let path, let persona, let mode, let autostart) = handler.pendingDestination {
            XCTAssertEqual(path, "/Users/test/Downloads")
            XCTAssertEqual(persona, "developer")
            XCTAssertNil(mode)
            XCTAssertFalse(autostart)
        } else {
            XCTFail("Expected organize destination")
        }
        
        handler.clearPending()
        XCTAssertNil(handler.pendingDestination)
    }

    @MainActor
    func testOrganizeDeeplinkWithAutostart() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://organize?path=/tmp&autostart=true")!
        handler.handle(url: url)
        
        if case let .organize(path, _, mode, autostart) = handler.pendingDestination {
            XCTAssertEqual(path, "/tmp")
            XCTAssertNil(mode)
            XCTAssertTrue(autostart)
        } else {
            XCTFail("Expected .organize destination with autostart")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testOrganizeDeeplinkNoPath() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://organize")!
        handler.handle(url: url)
        
        if case .organize(let path, _, _, _) = handler.pendingDestination {
            XCTAssertNil(path)
        } else {
            XCTFail("Expected organize destination")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testDuplicatesDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://duplicates?path=/tmp/test")!
        handler.handle(url: url)
        
        if case .duplicates(let path, let autostart) = handler.pendingDestination {
            XCTAssertEqual(path, "/tmp/test")
            XCTAssertFalse(autostart)
        } else {
            XCTFail("Expected duplicates destination")
        }
        
        handler.clearPending()
    }

    @MainActor
    func testDuplicatesDeeplinkWithAutostart() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://duplicates?path=/tmp/test&autostart=true")!
        handler.handle(url: url)
        
        if case .duplicates(let path, let autostart) = handler.pendingDestination {
            XCTAssertEqual(path, "/tmp/test")
            XCTAssertTrue(autostart)
        } else {
            XCTFail("Expected duplicates destination")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testLearningsDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://learnings?project=Photos")!
        handler.handle(url: url)
        
        if case .learnings(let action, let project) = handler.pendingDestination {
            XCTAssertNil(action)
            XCTAssertEqual(project, "Photos")
        } else {
            XCTFail("Expected learnings destination")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testSettingsDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://settings")!
        handler.handle(url: url)
        
        XCTAssertEqual(handler.pendingDestination, .settings(section: nil))
        handler.clearPending()
    }

    @MainActor
    func testSettingsWithSectionDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://settings?section=provider")!
        handler.handle(url: url)
        
        XCTAssertEqual(handler.pendingDestination, .settings(section: "provider"))
        handler.clearPending()
        
        let url2 = URL(string: "sorty://settings?section=notifications")!
        handler.handle(url: url2)
        XCTAssertEqual(handler.pendingDestination, .settings(section: "notifications"))
        handler.clearPending()
    }
    
    @MainActor
    func testHelpDeeplinkWithSection() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://help?section=personas")!
        handler.handle(url: url)
        
        if case .help(let section) = handler.pendingDestination {
            XCTAssertEqual(section, "personas")
        } else {
            XCTFail("Expected help destination")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testOpenDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://open")!
        handler.handle(url: url)
        
        XCTAssertEqual(handler.pendingDestination, .open(path: nil))
        handler.clearPending()
    }
    
    @MainActor
    func testOpenDeeplinkWithPath() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://open?path=/tmp/test")!
        handler.handle(url: url)
        
        XCTAssertEqual(handler.pendingDestination, .open(path: "/tmp/test"))
        handler.clearPending()
    }
    
    @MainActor
    func testHistoryDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://history")!
        handler.handle(url: url)
        
        XCTAssertEqual(handler.pendingDestination, .history())
        handler.clearPending()
    }

    @MainActor
    func testHistoryEntryDeeplink() {
        let handler = DeeplinkHandler.shared
        let entryID = UUID(uuidString: "93DC199E-F79F-436E-8F36-9EA949227CB6")!

        handler.handle(url: URL(string: "sorty://history?entry=\(entryID.uuidString)")!)

        XCTAssertEqual(handler.pendingDestination, .history(entryID: entryID))
        handler.clearPending()
    }
    
    @MainActor
    func testPersonaDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://persona?action=generate&prompt=Organize%20my%20music")!
        handler.handle(url: url)
        
        if case .persona(let action, let prompt, let generate) = handler.pendingDestination {
            XCTAssertEqual(action, "generate")
            XCTAssertEqual(prompt, "Organize my music")
            XCTAssertFalse(generate)
        } else {
            XCTFail("Expected persona destination")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testWatchedDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://watched?action=add&path=/Users/test/Code")!
        handler.handle(url: url)
        
        if case .watched(let action, let path) = handler.pendingDestination {
            XCTAssertEqual(action, "add")
            XCTAssertEqual(path, "/Users/test/Code")
        } else {
            XCTFail("Expected watched destination")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testRulesDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://rules?action=add&pattern=*.tmp")!
        handler.handle(url: url)
        
        if case .rules(let action, _, let pattern) = handler.pendingDestination {
            XCTAssertEqual(action, "add")
            XCTAssertEqual(pattern, "*.tmp")
        } else {
            XCTFail("Expected rules destination")
        }
        
        handler.clearPending()
    }

    @MainActor
    func testExclusionsDeeplink() {
        let handler = DeeplinkHandler.shared

        let url = URL(string: "sorty://exclusions?action=add&pattern=*.tmp")!
        handler.handle(url: url)

        if case .exclusions(let action, let pattern) = handler.pendingDestination {
            XCTAssertEqual(action, "add")
            XCTAssertEqual(pattern, "*.tmp")
        } else {
            XCTFail("Expected exclusions destination")
        }

        handler.clearPending()
    }

    @MainActor
    func testStorageDeeplink() {
        let handler = DeeplinkHandler.shared

        let url = URL(string: "sorty://storage?action=add&path=/tmp/archive")!
        handler.handle(url: url)

        if case .storage(let action, let path) = handler.pendingDestination {
            XCTAssertEqual(action, "add")
            XCTAssertEqual(path, "/tmp/archive")
        } else {
            XCTFail("Expected storage destination")
        }

        handler.clearPending()
    }

    @MainActor
    func testHostMatchingIsCaseInsensitive() {
        let handler = DeeplinkHandler.shared

        let url = URL(string: "sorty://SeTTings?section=help")!
        handler.handle(url: url)

        XCTAssertEqual(handler.pendingDestination, .settings(section: "help"))
        handler.clearPending()
    }
    
    @MainActor
    func testWatchedListDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://watched")!
        handler.handle(url: url)
        
        if case .watched(let action, let path) = handler.pendingDestination {
            XCTAssertNil(action)
            XCTAssertNil(path)
        } else {
            XCTFail("Expected watched destination")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testUnknownDeeplink() {
        let handler = DeeplinkHandler.shared
        handler.clearPending()
        
        let url = URL(string: "sorty://unknown")!
        handler.handle(url: url)
        
        XCTAssertNil(handler.pendingDestination)
    }
    
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
    
    @MainActor
    func testDeeplinkWithEncodedSpaces() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty://organize?path=/Users/test/My%20Documents")!
        handler.handle(url: url)
        
        if case .organize(let path, _, _, _) = handler.pendingDestination {
            XCTAssertEqual(path, "/Users/test/My Documents", "Should decode URL-encoded spaces")
        } else {
            XCTFail("Expected organize destination")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testDeeplinkWithEncodedUnicode() {
        let handler = DeeplinkHandler.shared
        
        // "文件" URL-encoded
        let url = URL(string: "sorty://organize?path=/tmp/%E6%96%87%E4%BB%B6")!
        handler.handle(url: url)
        
        if case .organize(let path, _, _, _) = handler.pendingDestination {
            XCTAssertEqual(path, "/tmp/文件", "Should decode URL-encoded unicode")
        } else {
            XCTFail("Expected organize destination")
        }
        
        handler.clearPending()
    }
    
    @MainActor
    func testLegacyPathDeeplink() {
        let handler = DeeplinkHandler.shared
        
        let url = URL(string: "sorty:///Users/test/Downloads")!
        handler.handle(url: url)
        
        XCTAssertEqual(handler.pendingDestination, .organize(path: "/Users/test/Downloads", persona: nil, mode: nil, autostart: false))
        handler.clearPending()
    }
    
    // MARK: - URL Generation Tests
    
    @MainActor
    func testGenerateOrganizeURL() {
        let url = DeeplinkHandler.url(for: .organize(path: "/test/path", persona: nil, mode: nil, autostart: false))
        XCTAssertEqual(url?.absoluteString, "sorty://organize?path=/test/path")
    }

    @MainActor
    func testOrganizeDeeplinkWithMode() {
        let handler = DeeplinkHandler.shared

        let url = URL(string: "sorty://organize?path=/tmp&mode=renameOnly&autostart=true")!
        handler.handle(url: url)

        if case let .organize(path, _, mode, autostart) = handler.pendingDestination {
            XCTAssertEqual(path, "/tmp")
            XCTAssertEqual(mode, .renameOnly)
            XCTAssertTrue(autostart)
        } else {
            XCTFail("Expected organize destination with mode")
        }

        handler.clearPending()
    }

    @MainActor
    func testScanDeeplinkRoutesToAutostartOrganization() {
        let handler = DeeplinkHandler.shared

        handler.handle(url: URL(string: "sorty://scan?path=/tmp/Inbox")!)

        XCTAssertEqual(
            handler.pendingDestination,
            .organize(path: "/tmp/Inbox", persona: nil, mode: nil, autostart: true)
        )
        handler.clearPending()
    }

    @MainActor
    func testGenerateOrganizeURLWithMode() {
        let url = DeeplinkHandler.url(for: .organize(path: "/test/path", persona: nil, mode: .renameOnly, autostart: true))
        XCTAssertEqual(url?.absoluteString, "sorty://organize?path=/test/path&mode=renameOnly&autostart=true")
    }
    
    @MainActor
    func testGenerateSettingsURL() {
        let url = DeeplinkHandler.url(for: .settings(section: nil))
        XCTAssertEqual(url?.absoluteString, "sorty://settings")
    }

    @MainActor
    func testGenerateHistoryEntryURL() {
        let entryID = UUID(uuidString: "93DC199E-F79F-436E-8F36-9EA949227CB6")!
        let url = DeeplinkHandler.url(for: .history(entryID: entryID))

        XCTAssertEqual(url?.absoluteString, "sorty://history?entry=93DC199E-F79F-436E-8F36-9EA949227CB6")
    }
    
    @MainActor
    func testGenerateOpenURL() {
        let url = DeeplinkHandler.url(for: .open(path: nil))
        XCTAssertEqual(url?.absoluteString, "sorty://open")
        
        let urlWithPath = DeeplinkHandler.url(for: .open(path: "/tmp/test"))
        XCTAssertEqual(urlWithPath?.absoluteString, "sorty://open?path=/tmp/test")
    }
    
    @MainActor
    func testGenerateLearningsURL() {
        let url = DeeplinkHandler.url(for: .learnings(action: nil, project: "MyProject"))
        XCTAssertEqual(url?.absoluteString, "sorty://learnings?project=MyProject")
        
    }
    
    @MainActor
    func testGeneratePersonaURL() {
        let url = DeeplinkHandler.url(for: .persona(action: "generate", prompt: "Test prompt", generate: true))
        XCTAssertEqual(url?.absoluteString, "sorty://persona?action=generate&prompt=Test%20prompt&generate=true")
    }

    @MainActor
    func testGenerateExclusionsURL() {
        let url = DeeplinkHandler.url(for: .exclusions(action: "add", pattern: "*.log"))
        XCTAssertEqual(url?.absoluteString, "sorty://exclusions?action=add&pattern=*.log")
    }

    @MainActor
    func testGenerateStorageURL() {
        let url = DeeplinkHandler.url(for: .storage(action: "add", path: "/tmp/archive"))
        XCTAssertEqual(url?.absoluteString, "sorty://storage?action=add&path=/tmp/archive")
    }
}
