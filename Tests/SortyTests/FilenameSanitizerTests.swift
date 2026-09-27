import XCTest
@testable import SortyLib
@testable import SortyCore

final class FilenameSanitizerTests: XCTestCase {

    func testInvalidCharactersAreReplaced() {
        let result = FilenameSanitizer.sanitize("inv:alid/na\\me.txt", preservingExtension: "txt")

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitizedName, "inv-alid-na-me.txt")
        XCTAssertTrue(result.hadInvalidCharacters)
    }

    func testWhitespaceAndTrailingDotsAreTrimmed() {
        let result = FilenameSanitizer.sanitize("  report.final.  ", preservingExtension: "pdf")

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitizedName, "report.pdf")
        XCTAssertTrue(result.hadTrimming)
        XCTAssertTrue(result.extensionAdjusted)
    }

    func testRejectsReservedNames() {
        let dot = FilenameSanitizer.sanitize(".")
        let dotDot = FilenameSanitizer.sanitize("..")

        XCTAssertFalse(dot.isValid)
        XCTAssertNil(dot.sanitizedName)
        XCTAssertTrue(dot.isReservedName)

        XCTAssertFalse(dotDot.isValid)
        XCTAssertNil(dotDot.sanitizedName)
        XCTAssertTrue(dotDot.isReservedName)
    }

    func testRejectsExtensionOnlyNames() {
        let result = FilenameSanitizer.sanitize(".pdf", preservingExtension: "pdf")

        XCTAssertFalse(result.isValid)
        XCTAssertNil(result.sanitizedName)
        XCTAssertTrue(result.isExtensionOnly)
    }

    func testRejectsEmptyNames() {
        let result = FilenameSanitizer.sanitize("   ")

        XCTAssertFalse(result.isValid)
        XCTAssertNil(result.sanitizedName)
        XCTAssertTrue(result.isEmpty)
    }

    func testPreservesOriginalExtension() {
        let result = FilenameSanitizer.sanitize("photo.png", preservingExtension: "jpg", enforceExtension: true)

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitizedName, "photo.jpg")
        XCTAssertTrue(result.extensionAdjusted)
    }

    func testHandlesUnicodeAndEmojiWithoutBreakingScalars() {
        let result = FilenameSanitizer.sanitize("Q4_レポート_😀.pdf", preservingExtension: "pdf")

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitizedName, "Q4_レポート_😀.pdf")
        XCTAssertFalse(result.exceededMaxBytes)
    }

    func testTruncatesToMaxBytes() {
        let veryLong = String(repeating: "a", count: 400) + ".txt"
        let result = FilenameSanitizer.sanitize(veryLong, preservingExtension: "txt")

        XCTAssertTrue(result.isValid)
        let sanitized = try? XCTUnwrap(result.sanitizedName)
        XCTAssertNotNil(sanitized)
        if let sanitized {
            XCTAssertLessThanOrEqual(FilenameSanitizer.utf8ByteCount(sanitized), FilenameSanitizer.maxFilenameBytes)
            XCTAssertTrue(sanitized.hasSuffix(".txt"))
        }
        XCTAssertTrue(result.exceededMaxBytes)
    }

    func testRecommendedLengthWarning() {
        let longName = String(repeating: "b", count: 80) + ".txt"
        let result = FilenameSanitizer.sanitize(longName, preservingExtension: "txt")

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.exceededRecommendedLength)
        XCTAssertFalse(result.warnings.isEmpty)
    }
}
