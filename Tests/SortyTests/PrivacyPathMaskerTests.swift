import XCTest
@testable import SortyLib
@testable import SortyCore

final class PrivacyPathMaskerTests: XCTestCase {

    func testExtractsUsernameFromUsersDirectoryPath() {
        let path = "/Users/shirishpothi/Downloads/AyuGram Desktop"

        let segments = PrivacyPathMasker.userPathSegments(in: path, currentUsername: "ignored-user")

        XCTAssertEqual(segments?.leading, "/Users/")
        XCTAssertEqual(segments?.username, "shirishpothi")
        XCTAssertEqual(segments?.trailing, "/Downloads/AyuGram Desktop")
    }

    func testExtractsUsernameFromUsersDirectoryPathCaseInsensitive() {
        let path = "/users/John/Documents"

        let segments = PrivacyPathMasker.userPathSegments(in: path, currentUsername: "ignored-user")

        XCTAssertEqual(segments?.leading, "/users/")
        XCTAssertEqual(segments?.username, "John")
        XCTAssertEqual(segments?.trailing, "/Documents")
    }

    func testExtractsCurrentUsernameFromNonUsersPathSegment() {
        let path = "/home/shirishpothi/Documents"

        let segments = PrivacyPathMasker.userPathSegments(in: path, currentUsername: "shirishpothi")

        XCTAssertEqual(segments?.leading, "/home/")
        XCTAssertEqual(segments?.username, "shirishpothi")
        XCTAssertEqual(segments?.trailing, "/Documents")
    }

    func testDoesNotMaskUsernameInsideLargerSegment() {
        let path = "/tmp/shirishpothi_backup/files"

        let segments = PrivacyPathMasker.userPathSegments(in: path, currentUsername: "shirishpothi")

        XCTAssertNil(segments)
    }

    func testRedactedPathReplacesUsernameSegment() {
        let path = "/Users/shirishpothi/Downloads/AyuGram Desktop"

        let redacted = PrivacyPathMasker.redactedPath(path)

        XCTAssertEqual(redacted, "/Users/[REDACTED_USER]/Downloads/AyuGram Desktop")
    }

    func testRedactedTextReplacesAllUsersDirectoryOccurrences() {
        let text = "Primary: /Users/alex/Desktop | Secondary: /users/jordan/Documents"

        let redacted = PrivacyPathMasker.redactedText(text, currentUsername: "ignored")

        XCTAssertEqual(redacted, "Primary: /Users/[REDACTED_USER]/Desktop | Secondary: /users/[REDACTED_USER]/Documents")
    }

    func testRedactedTextReplacesCurrentUsernamePathSegmentOutsideUsersDirectory() {
        let text = "scan /Volumes/Data/shirishpothi/Invoices and /home/shirishpothi/.config"

        let redacted = PrivacyPathMasker.redactedText(text, currentUsername: "shirishpothi")

        XCTAssertEqual(redacted, "scan /Volumes/Data/[REDACTED_USER]/Invoices and /home/[REDACTED_USER]/.config")
    }
}
