import XCTest
@testable import SortyLib

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
    
    // MARK: - Models Tests

    func testAnalysisResultToJSON() throws {
        let result = LearningsAnalysisResult(
            inferredRules: [
                InferredRule(
                    id: "rule-1",
                    pattern: "^IMG_.*",
                    template: "{year}/{filename}",
                    metadataCues: ["exif:DateTimeOriginal"],
                    priority: 50,
                    exampleIds: ["ex-1"],
                    explanation: "Photo organization rule"
                )
            ],
            proposedMappings: [
                ProposedMapping(
                    srcPath: "/Downloads/test.jpg",
                    proposedDstPath: "/Photos/2024/test.jpg",
                    ruleId: "rule-1",
                    confidence: 0.8,
                    explanation: "Matched photo rule"
                )
            ],
            confidenceSummary: ConfidenceSummary(high: 1, medium: 0, low: 0),
            humanSummary: ["Learned 1 rule from examples"]
        )
        
        let jsonData = try result.toJSON()
        XCTAssertNotNil(jsonData)
        
        // Verify it can be decoded back
        let decoded = try JSONDecoder().decode(LearningsAnalysisResult.self, from: jsonData)
        XCTAssertEqual(decoded.inferredRules.count, 1)
        XCTAssertEqual(decoded.proposedMappings.count, 1)
    }
}
