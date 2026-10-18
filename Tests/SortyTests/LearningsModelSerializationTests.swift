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
    
    // MARK: - Confidence Level Tests
    
    func testProposedMappingConfidenceLevels() {
        let highConfidence = ProposedMapping(
            srcPath: "/test.jpg",
            proposedDstPath: "/out/test.jpg",
            confidence: 0.85,
            explanation: "Test"
        )
        XCTAssertEqual(highConfidence.confidenceLevel, .high)
        
        let mediumConfidence = ProposedMapping(
            srcPath: "/test.jpg",
            proposedDstPath: "/out/test.jpg",
            confidence: 0.6,
            explanation: "Test"
        )
        XCTAssertEqual(mediumConfidence.confidenceLevel, .medium)
        
        let lowConfidence = ProposedMapping(
            srcPath: "/test.jpg",
            proposedDstPath: "/out/test.jpg",
            confidence: 0.3,
            explanation: "Test"
        )
        XCTAssertEqual(lowConfidence.confidenceLevel, .low)
    }
}
