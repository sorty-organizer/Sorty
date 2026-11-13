import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyFileSystem

/// Folders a `sorty://` link may not turn into watched folders or storage
/// destinations, and the storage guard that applies however a location is added.
final class LinkPathProtectionTests: XCTestCase {
    private let home = "/Users/tester"

    func testProtectsLibraryHiddenAndSharedAppFolders() {
        let protected = [
            "/Users/tester/Library",
            "/Users/tester/Library/LaunchAgents",
            "/Users/tester/Library/Application Support/Sorty",
            "/Users/tester/.ssh",
            "/Users/tester/.config/fish",
            "/Applications",
            "/Applications/Utilities",
            "/Library/LaunchAgents",
        ]
        for path in protected {
            XCTAssertTrue(IncomingPathValidator.isProtectedFromLinks(path, homeDirectoryPath: home), path)
        }
    }

    func testAllowsUserDocumentsAndCloudStorage() {
        let allowed = [
            "/Users/tester",
            "/Users/tester/Downloads",
            "/Users/tester/Documents/.hidden-inside-documents",
            "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Taxes",
            "/Users/tester/Library/CloudStorage/Dropbox/Photos",
            "/Users/tester/LibraryBooks",
            "/Volumes/Archive",
            "/private/var/folders/xy/T/sorty-test",
        ]
        for path in allowed {
            XCTAssertFalse(IncomingPathValidator.isProtectedFromLinks(path, homeDirectoryPath: home), path)
        }
    }

    func testLinkValidatorRejectsSymlinkIntoProtectedFolder() throws {
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let library = realHome.appendingPathComponent("Library", isDirectory: true)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorty-link-protect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let link = tempRoot.appendingPathComponent("innocent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library)

        guard case .failure(.protectedLinkPath) = IncomingPathValidator.validatedLinkDirectoryURL(for: link.path) else {
            return XCTFail("A link through a symlink to ~/Library must be rejected")
        }
        guard case .success = IncomingPathValidator.validatedLinkDirectoryURL(for: tempRoot.path) else {
            return XCTFail("An ordinary temp folder must stay allowed")
        }
    }

    @MainActor
    func testStorageLocationsRefuseLaunchAgentsFolder() {
        let manager = StorageLocationsManager()
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

        XCTAssertThrowsError(try manager.addLocation(url: launchAgents)) { error in
            XCTAssertEqual(error as? StorageLocationError, .protectedLocation)
        }
    }
}
