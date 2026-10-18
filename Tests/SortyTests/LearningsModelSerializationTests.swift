import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyLearnings

final class LearningsModelSerializationTests: XCTestCase {
    // MARK: - File Category Tests
    
    func testFileCategoryFromExtension() {
        XCTAssertEqual(FileCategory.from(extension: "jpg"), .photo)
        XCTAssertEqual(FileCategory.from(extension: "JPEG"), .photo)
        XCTAssertEqual(FileCategory.from(extension: "mp3"), .music)
        XCTAssertEqual(FileCategory.from(extension: "mp4"), .video)
        XCTAssertEqual(FileCategory.from(extension: "pdf"), .document)
        XCTAssertEqual(FileCategory.from(extension: "swift"), .code)
        XCTAssertEqual(FileCategory.from(extension: "zip"), .archive)
        XCTAssertEqual(FileCategory.from(extension: "xyz"), .other)
    }
}
