import XCTest
import AppKit
@testable import SortyLib
@testable import SortyCore

@MainActor
final class FolderOrganizerVisionFlowTests: XCTestCase {
    private var organizer: FolderOrganizer!
    private var tempDirectory: URL!

    override func setUp() async throws {
        organizer = FolderOrganizer()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        organizer = nil
    }

    func testVisionFlowCallsAnalyzeWithImagesAndRespectsBatchSize() async throws {
        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gpt-4o",
            enableVision: true,
            visionBatchSize: 1,
            visionBatchStrategy: .firstN
        )
        try await organizer.configure(with: config)

        let mockClient = VisionFlowMockClient(config: config)
        organizer.setAIClientForTesting(mockClient)

        try createPNG(at: tempDirectory.appendingPathComponent("one.png"))
        try createPNG(at: tempDirectory.appendingPathComponent("two.png"))
        try "text".write(to: tempDirectory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        try await organizer.organize(directory: tempDirectory)

        let analyzeWithImagesCalls = await mockClient.analyzeWithImagesCalls
        let analyzeCalls = await mockClient.analyzeCalls
        let lastImageCount = await mockClient.lastImageCount

        XCTAssertEqual(analyzeWithImagesCalls, 1)
        XCTAssertEqual(analyzeCalls, 0)
        XCTAssertEqual(lastImageCount, 1)
        XCTAssertEqual(organizer.visionAnalysisSummary?.analyzedCount, 1)
        XCTAssertEqual(organizer.visionAnalysisSummary?.totalImageCount, 2)
        XCTAssertEqual(organizer.visionAnalysisSummary?.skippedCount, 1)
    }

    func testVisionUnsupportedFallsBackToTextAnalysisAndProvidesWarning() async throws {
        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gemma-flash",
            enableVision: true
        )
        try await organizer.configure(with: config)

        let mockClient = VisionFlowMockClient(config: config)
        organizer.setAIClientForTesting(mockClient)

        try createPNG(at: tempDirectory.appendingPathComponent("one.png"))

        try await organizer.organize(directory: tempDirectory)

        let analyzeWithImagesCalls = await mockClient.analyzeWithImagesCalls
        let analyzeCalls = await mockClient.analyzeCalls

        XCTAssertEqual(analyzeWithImagesCalls, 0)
        XCTAssertEqual(analyzeCalls, 1)
        XCTAssertEqual(organizer.visionAnalysisSummary?.analyzedCount, 0)
        XCTAssertEqual(organizer.visionAnalysisSummary?.skippedCount, 1)
        XCTAssertNotNil(organizer.visionAnalysisSummary?.warningMessage)
    }

    func testFastModeStillUsesVisionWhenVisionIsEnabled() async throws {
        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gpt-4o",
            enableDeepScan: false,
            enableVision: true
        )
        try await organizer.configure(with: config)

        let mockClient = VisionFlowMockClient(config: config)
        organizer.setAIClientForTesting(mockClient)

        try createPNG(at: tempDirectory.appendingPathComponent("one.png"))

        try await organizer.organize(directory: tempDirectory)

        let analyzeWithImagesCalls = await mockClient.analyzeWithImagesCalls
        let analyzeCalls = await mockClient.analyzeCalls

        XCTAssertEqual(analyzeWithImagesCalls, 1)
        XCTAssertEqual(analyzeCalls, 0)
        XCTAssertEqual(organizer.visionAnalysisSummary?.analyzedCount, 1)
    }

    func testVisionPreservesRelativePathsAndRequestsEvidenceBasedGrouping() async throws {
        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gpt-4o",
            enableVision: true,
            visionBatchSize: 12,
            visionBatchStrategy: .noText
        )
        try await organizer.configure(with: config)

        let mockClient = VisionFlowMockClient(config: config)
        organizer.setAIClientForTesting(mockClient)

        let receipts = tempDirectory.appendingPathComponent("Receipts")
        let holidays = tempDirectory.appendingPathComponent("Holidays")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: holidays, withIntermediateDirectories: true)
        try createPNG(at: receipts.appendingPathComponent("image.png"))
        try createPNG(at: holidays.appendingPathComponent("image.png"))

        try await organizer.organize(directory: tempDirectory)

        let imageNames = await mockClient.lastImageNames
        let instructions = await mockClient.lastCustomInstructions

        XCTAssertEqual(imageNames, ["Holidays/image.png", "Receipts/image.png"])
        XCTAssertTrue(instructions?.contains("Ground each attached file's placement in visible evidence") == true)
        XCTAssertTrue(instructions?.contains("let strong visual evidence override vague camera or screenshot filenames") == true)
    }

    func testVisionFlowWithoutLimitSendsAllImages() async throws {
        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gpt-4o",
            enableVision: true,
            limitVisionImages: false,
            visionBatchSize: 1,
            visionBatchStrategy: .firstN
        )
        try await organizer.configure(with: config)

        let mockClient = VisionFlowMockClient(config: config)
        organizer.setAIClientForTesting(mockClient)

        try createPNG(at: tempDirectory.appendingPathComponent("one.png"))
        try createPNG(at: tempDirectory.appendingPathComponent("two.png"))

        try await organizer.organize(directory: tempDirectory)

        let analyzeWithImagesCalls = await mockClient.analyzeWithImagesCalls
        let analyzeCalls = await mockClient.analyzeCalls
        let lastImageCount = await mockClient.lastImageCount

        XCTAssertEqual(analyzeWithImagesCalls, 1)
        XCTAssertEqual(analyzeCalls, 0)
        XCTAssertEqual(lastImageCount, 2)
        XCTAssertEqual(organizer.visionAnalysisSummary?.analyzedCount, 2)
        XCTAssertEqual(organizer.visionAnalysisSummary?.totalImageCount, 2)
        XCTAssertEqual(organizer.visionAnalysisSummary?.skippedCount, 0)
    }

    func testRenameOnlyInjectsConsentedLearningsForCurrentFolder() async throws {
        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gpt-4o",
            mode: .renameOnly
        )
        try await organizer.configure(with: config)

        let suiteName = "FolderOrganizerVisionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let learningsManager = LearningsManager(userDefaults: defaults)
        await learningsManager.grantConsent()
        var profile = LearningsProfile(consentGranted: true)
        profile.inferredRules = [
            InferredRule(
                pattern: ".*\\.pdf$",
                template: "{date} {vendor} Invoice.pdf",
                priority: 90,
                explanation: "Use dated vendor invoice names",
                scope: .folder(tempDirectory.path),
                status: .active
            ),
            InferredRule(
                pattern: ".*\\.mov$",
                template: "Unrelated/{filename}",
                priority: 100,
                explanation: "Rule from another folder",
                scope: .folder("/Users/example/Elsewhere"),
                status: .active
            )
        ]
        learningsManager.currentProfile = profile
        organizer.learningsManager = learningsManager

        let mockClient = VisionFlowMockClient(config: config)
        organizer.setAIClientForTesting(mockClient)
        try "invoice".write(
            to: tempDirectory.appendingPathComponent("scan.pdf"),
            atomically: true,
            encoding: .utf8
        )

        try await organizer.organize(directory: tempDirectory)

        let instructions = await mockClient.lastCustomInstructions
        XCTAssertTrue(instructions?.contains("Use dated vendor invoice names") == true)
        XCTAssertFalse(instructions?.contains("Rule from another folder") == true)
    }

    func testRenameOnlyDoesNotInjectLearningsWithoutConsent() async throws {
        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gpt-4o",
            mode: .renameOnly
        )
        try await organizer.configure(with: config)

        let suiteName = "FolderOrganizerVisionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let learningsManager = LearningsManager(userDefaults: defaults)
        var profile = LearningsProfile(consentGranted: false)
        profile.inferredRules = [
            InferredRule(
                pattern: ".*",
                template: "Private/{filename}",
                priority: 100,
                explanation: "Private rename convention",
                status: .active
            )
        ]
        learningsManager.currentProfile = profile
        organizer.learningsManager = learningsManager

        let mockClient = VisionFlowMockClient(config: config)
        organizer.setAIClientForTesting(mockClient)
        try "notes".write(
            to: tempDirectory.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await organizer.organize(directory: tempDirectory)

        let instructions = await mockClient.lastCustomInstructions
        XCTAssertFalse(instructions?.contains("Private rename convention") == true)
    }

    private func createPNG(at url: URL) throws {
        let size = NSSize(width: 80, height: 80)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            XCTFail("Unable to create bitmap")
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPink.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Unable to create PNG data")
            return
        }
        try data.write(to: url)
    }
}

actor VisionFlowMockClient: AIClientProtocol {
    let config: AIConfig
    @MainActor weak var streamingDelegate: StreamingDelegate?
    var analyzeCalls = 0
    var analyzeWithImagesCalls = 0
    var lastImageCount = 0
    var lastImageNames: [String] = []
    var lastCustomInstructions: String?

    init(config: AIConfig) {
        self.config = config
    }

    func analyze(files: [FileItem], customInstructions: String?, personaPrompt: String?, temperature: Double?) async throws -> OrganizationPlan {
        analyzeCalls += 1
        lastCustomInstructions = customInstructions
        return OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Grouped", files: files)],
            unorganizedFiles: [],
            notes: "ok"
        )
    }

    func analyzeWithImages(files: [FileItem], imageData: [String: Data], customInstructions: String?, personaPrompt: String?, temperature: Double?) async throws -> OrganizationPlan {
        analyzeWithImagesCalls += 1
        lastImageCount = imageData.count
        lastImageNames = imageData.keys.sorted()
        lastCustomInstructions = customInstructions
        return OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Grouped", files: files)],
            unorganizedFiles: [],
            notes: "ok"
        )
    }

    func generateText(prompt: String, systemPrompt: String?) async throws -> String {
        "ok"
    }

    func checkHealth() async throws {}
}
