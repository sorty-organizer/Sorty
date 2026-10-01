//
//  DuplicateSettingsTests.swift
//  SortyTests
//
//  Tests for duplicate detection settings
//

import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyModels

final class DuplicateSettingsTests: XCTestCase {
    
    // MARK: - DuplicateSettings Tests
    
    func testDefaultSettings() {
        let settings = DuplicateSettings()
        
        XCTAssertEqual(settings.minFileSize, 0)
        XCTAssertEqual(settings.maxScanDepth, -1)
        XCTAssertTrue(settings.includeExtensions.isEmpty)
        XCTAssertFalse(settings.excludeExtensions.isEmpty) // Has defaults
        XCTAssertEqual(settings.defaultKeepStrategy, .newest)
        XCTAssertTrue(settings.autoStartScan)
        XCTAssertTrue(settings.includeSemanticDuplicates)
        XCTAssertEqual(settings.semanticSimilarityThreshold, DuplicateSettings.defaultSemanticSimilarityThreshold)
    }

    func testSemanticSimilarityThresholdClamping() {
        let tooLow = DuplicateSettings(semanticSimilarityThreshold: 0.25)
        XCTAssertEqual(tooLow.semanticSimilarityThreshold, DuplicateSettings.minSemanticSimilarityThreshold)

        let tooHigh = DuplicateSettings(semanticSimilarityThreshold: 1.25)
        XCTAssertEqual(tooHigh.semanticSimilarityThreshold, DuplicateSettings.maxSemanticSimilarityThreshold)

        XCTAssertEqual(DuplicateSettings.clampedSemanticSimilarityThreshold(0.85), 0.85)
    }
    
    func testCustomSettings() {
        let settings = DuplicateSettings(
            minFileSize: 1024 * 1024, // 1 MB
            maxScanDepth: 3,
            includeExtensions: ["jpg", "png"],
            excludeExtensions: [".DS_Store"],
            defaultKeepStrategy: .largest,
            autoStartScan: true,
            includeSemanticDuplicates: true,
            semanticSimilarityThreshold: 0.8
        )
        
        XCTAssertEqual(settings.minFileSize, 1024 * 1024)
        XCTAssertEqual(settings.maxScanDepth, 3)
        XCTAssertEqual(settings.includeExtensions, ["jpg", "png"])
        XCTAssertEqual(settings.excludeExtensions, [".DS_Store"])
        XCTAssertEqual(settings.defaultKeepStrategy, .largest)
        XCTAssertTrue(settings.autoStartScan)
        XCTAssertTrue(settings.includeSemanticDuplicates)
        XCTAssertEqual(settings.semanticSimilarityThreshold, 0.8)
    }
    
    func testSettingsCodable() throws {
        let original = DuplicateSettings(
            minFileSize: 500,
            maxScanDepth: 5,
            includeExtensions: ["pdf"],
            excludeExtensions: [],
            defaultKeepStrategy: .oldest,
            autoStartScan: false,
            includeSemanticDuplicates: false,
            semanticSimilarityThreshold: 0.95
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DuplicateSettings.self, from: data)
        
        XCTAssertEqual(decoded.minFileSize, original.minFileSize)
        XCTAssertEqual(decoded.maxScanDepth, original.maxScanDepth)
        XCTAssertEqual(decoded.includeExtensions, original.includeExtensions)
        XCTAssertEqual(decoded.defaultKeepStrategy, original.defaultKeepStrategy)
        XCTAssertEqual(decoded.semanticSimilarityThreshold, original.semanticSimilarityThreshold)
    }
    
    // MARK: - KeepStrategy Tests
    
    func testKeepStrategyDisplayNames() {
        XCTAssertEqual(KeepStrategy.newest.displayName, "Keep Newest")
        XCTAssertEqual(KeepStrategy.oldest.displayName, "Keep Oldest")
        XCTAssertEqual(KeepStrategy.largest.displayName, "Keep Largest")
        XCTAssertEqual(KeepStrategy.smallest.displayName, "Keep Smallest")
        XCTAssertEqual(KeepStrategy.shortestPath.displayName, "Keep Shortest Path")
    }
    
    func testUsefulCleanupStrategiesExcludeMeaninglessSizeChoices() {
        XCTAssertEqual(KeepStrategy.usefulCleanupCases, [.newest, .oldest, .shortestPath])
        XCTAssertFalse(KeepStrategy.usefulCleanupCases.contains(.largest))
        XCTAssertFalse(KeepStrategy.usefulCleanupCases.contains(.smallest))
    }

    func testSimilarFileMatchRangesUseSupportedThresholds() {
        XCTAssertEqual(SimilarFileMatchRange.closest.threshold, 0.95)
        XCTAssertEqual(
            SimilarFileMatchRange.balanced.threshold,
            DuplicateSettings.defaultSemanticSimilarityThreshold
        )
        XCTAssertEqual(SimilarFileMatchRange.broader.threshold, 0.80)

        for range in SimilarFileMatchRange.allCases {
            XCTAssertEqual(
                DuplicateSettings.clampedSemanticSimilarityThreshold(range.threshold),
                range.threshold
            )
        }
    }

    func testCleanupPreferenceSelectsLargestFile() {
        let lowerResolutionOriginal = FileItem(
            path: "/Photos/Originals/photo.jpg",
            name: "photo",
            extension: "jpg",
            size: 1_000,
            modificationDate: Date(timeIntervalSince1970: 100),
            imageWidth: 1_000,
            imageHeight: 1_000
        )
        let higherResolutionOriginal = FileItem(
            path: "/Photos/Originals/photo-copy.jpg",
            name: "photo-copy",
            extension: "jpg",
            size: 2_000,
            modificationDate: Date(timeIntervalSince1970: 200),
            imageWidth: 2_000,
            imageHeight: 2_000
        )
        let largerEditedCopy = FileItem(
            path: "/Photos/Edits/photo.jpg",
            name: "photo",
            extension: "jpg",
            size: 4_000,
            modificationDate: Date(timeIntervalSince1970: 300),
            imageWidth: 4_000,
            imageHeight: 4_000
        )

        let preferredID = CleanupPreferenceResolver.preferredFileID(
            in: [lowerResolutionOriginal, largerEditedCopy, higherResolutionOriginal],
            strategy: .largest
        )

        XCTAssertEqual(preferredID, largerEditedCopy.id)
    }

    func testCleanupPreferenceSelectsNewestFile() {
        let olderOriginal = FileItem(
            path: "/Photos/Originals/photo.jpg",
            name: "photo",
            extension: "jpg",
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        let newerOriginal = FileItem(
            path: "/Photos/Originals/photo-copy.jpg",
            name: "photo-copy",
            extension: "jpg",
            modificationDate: Date(timeIntervalSince1970: 200)
        )

        let preferredID = CleanupPreferenceResolver.preferredFileID(
            in: [olderOriginal, newerOriginal],
            strategy: .newest
        )

        XCTAssertEqual(preferredID, newerOriginal.id)
    }

    func testCleanupPreferenceStrategyFallbackSelectsKeeper() {
        let shorterPath = FileItem(
            path: "/Photos/photo.jpg",
            name: "photo",
            extension: "jpg"
        )
        let longerPath = FileItem(
            path: "/Photos/Exports/Edited/photo.jpg",
            name: "photo",
            extension: "jpg"
        )

        let preferredID = CleanupPreferenceResolver.preferredFileID(
            in: [longerPath, shorterPath],
            strategy: .shortestPath
        )

        XCTAssertEqual(preferredID, shorterPath.id)
    }
}
