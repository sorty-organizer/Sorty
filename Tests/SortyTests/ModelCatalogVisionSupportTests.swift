import XCTest
@testable import SortyLib

@MainActor
final class ModelCatalogVisionSupportTests: XCTestCase {
    func testCodexRefreshClearsErrorsAndFallbackAfterRecovery() async {
        var shouldFail = true
        let models = [ModelInfo(id: "subscription-model", displayName: "Subscription model", provider: .openAI)]
        let catalog = ModelCatalog(codexModelLoader: {
            if shouldFail { throw URLError(.notConnectedToInternet) }
            return models
        })

        await catalog.refreshCodexSubscriptionModels(force: true)
        XCTAssertNotNil(catalog.lastCodexError)
        XCTAssertEqual(catalog.isFetching[.openAI], false)

        shouldFail = false
        await catalog.refreshCodexSubscriptionModels(force: true)
        XCTAssertNil(catalog.lastCodexError)
        XCTAssertEqual(catalog.codexSubscriptionModels, models)
        XCTAssertEqual(catalog.usingFallback[.openAI], false)

        shouldFail = true
        await catalog.refreshCodexSubscriptionModels(force: true)
        XCTAssertEqual(catalog.codexSubscriptionModels, models)
        XCTAssertEqual(catalog.usingFallback[.openAI], true)

        shouldFail = false
        await catalog.refreshCodexSubscriptionModels(force: true)
        XCTAssertNil(catalog.lastCodexError)
        XCTAssertEqual(catalog.usingFallback[.openAI], false)
        XCTAssertEqual(catalog.isFetching[.openAI], false)
    }

    func testOlderCodexRefreshCannotOverwriteNewerResult() async {
        var firstRequest: CheckedContinuation<[ModelInfo], Error>?
        var firstStarted: CheckedContinuation<Void, Never>?
        var callCount = 0
        let latest = [ModelInfo(id: "latest", displayName: "Latest", provider: .openAI)]
        let catalog = ModelCatalog(codexModelLoader: {
            callCount += 1
            if callCount == 1 {
                return try await withCheckedThrowingContinuation { continuation in
                    firstRequest = continuation
                    firstStarted?.resume()
                }
            }
            return latest
        })

        let older = Task { await catalog.refreshCodexSubscriptionModels(force: true) }
        await withCheckedContinuation { continuation in
            if firstRequest != nil {
                continuation.resume()
            } else {
                firstStarted = continuation
            }
        }
        await catalog.refreshCodexSubscriptionModels(force: true)
        firstRequest?.resume(throwing: URLError(.timedOut))
        await older.value

        XCTAssertEqual(catalog.codexSubscriptionModels, latest)
        XCTAssertNil(catalog.lastCodexError)
        XCTAssertEqual(catalog.usingFallback[.openAI], false)
        XCTAssertEqual(catalog.isFetching[.openAI], false)
    }

    func testKnownVisionModelsReturnTrue() {
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "gpt-4o", provider: .openAI))
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "claude-sonnet-4", provider: .anthropic))
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "gemini-2.5-flash", provider: .gemini))
    }

    func testKnownNonVisionModelsReturnFalse() {
        XCTAssertFalse(ModelCatalog.shared.supportsVision(modelId: "gemma-flash", provider: .openAICompatible))
        XCTAssertFalse(ModelCatalog.shared.supportsVision(modelId: "gemma-2-flash", provider: .openRouter))
    }

    func testFlashHeuristicDoesNotCreateFalsePositiveForNonGeminiProviders() {
        XCTAssertFalse(ModelCatalog.shared.supportsVision(modelId: "gemma-flash", provider: .openAI))
        XCTAssertFalse(ModelCatalog.shared.supportsVision(modelId: "my-text-flash-model", provider: .openAICompatible))
    }

    func testProviderSpecificHeuristics() {
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "llava:latest", provider: .ollama))
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "gpt-4o", provider: .githubCopilot))
        XCTAssertFalse(ModelCatalog.shared.supportsVision(modelId: "gpt-3.5-turbo", provider: .githubCopilot))
    }

    func testOpenAICompatibleDetectsLocalAndNamespacedVisionModels() {
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "llava:latest", provider: .openAICompatible))
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "ollama/llava:latest", provider: .openAICompatible))
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "qwen2.5-vl-72b-instruct", provider: .openAICompatible))
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "openai/gpt-4o", provider: .openAICompatible))
    }

    func testModelIdDoesNotLeakVisionAcrossProviders() {
        XCTAssertFalse(ModelCatalog.shared.supportsVision(modelId: "gpt-4o", provider: .ollama))
        XCTAssertFalse(ModelCatalog.shared.supportsVision(modelId: "claude-sonnet-4", provider: .openAICompatible))
    }

    func testGemma3NotForcedToNonVision() {
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "gemma3", provider: .ollama))
        XCTAssertTrue(ModelCatalog.shared.supportsVision(modelId: "gemma3:latest", provider: .openAICompatible))
    }

    func testModelMetadataFalseOverridesNameHeuristics() {
        let catalog = ModelCatalog()
        catalog.modelsByProvider[.openAICompatible] = [
            ModelInfo(
                id: "vision-proxy-model",
                displayName: "vision-proxy-model",
                provider: .openAICompatible,
                capabilities: ["text"]
            )
        ]

        XCTAssertFalse(catalog.supportsVision(modelId: "vision-proxy-model", provider: .openAICompatible))
    }

    func testModelMetadataInputImageMarksVision() {
        let catalog = ModelCatalog()
        catalog.modelsByProvider[.openRouter] = [
            ModelInfo(
                id: "router-multimodal",
                displayName: "router-multimodal",
                provider: .openRouter,
                capabilities: ["input:text", "input:image", "output:text"]
            )
        ]

        XCTAssertTrue(catalog.supportsVision(modelId: "router-multimodal", provider: .openRouter))
    }

    func testModelMetadataOutputImageOnlyDoesNotMarkVisionInput() {
        let catalog = ModelCatalog()
        catalog.modelsByProvider[.openRouter] = [
            ModelInfo(
                id: "router-image-generator",
                displayName: "router-image-generator",
                provider: .openRouter,
                capabilities: ["input:text", "output:image"]
            )
        ]

        XCTAssertFalse(catalog.supportsVision(modelId: "router-image-generator", provider: .openRouter))
    }

    func testAnthropicNoImageInputCapabilityDisablesVision() {
        let catalog = ModelCatalog()
        catalog.modelsByProvider[.anthropic] = [
            ModelInfo(
                id: "claude-sonnet-4",
                displayName: "claude-sonnet-4",
                provider: .anthropic,
                capabilities: ["no_image_input"]
            )
        ]

        XCTAssertFalse(catalog.supportsVision(modelId: "claude-sonnet-4", provider: .anthropic))
    }

    func testCachedModelsFiltersBlankAndDuplicateModelIDs() {
        let catalog = ModelCatalog()
        catalog.modelsByProvider[.githubCopilot] = [
            ModelInfo(id: "", displayName: "", provider: .githubCopilot),
            ModelInfo(id: "   ", displayName: "  ", provider: .githubCopilot),
            ModelInfo(id: "gpt-4.1", displayName: "gpt-4.1", provider: .githubCopilot),
            ModelInfo(id: " gpt-4.1 ", displayName: " gpt-4.1 ", provider: .githubCopilot)
        ]

        let models = catalog.cachedModels(for: .githubCopilot)
        XCTAssertEqual(models.map(\.id), ["gpt-4.1"])
        XCTAssertEqual(models.map(\.displayName), ["gpt-4.1"])
    }

    func testReasoningConfigurationUsesProviderModelMetadata() {
        let catalog = ModelCatalog()
        let providerLevel = ReasoningEffort(rawValue: "extreme")
        catalog.modelsByProvider[.openRouter] = [
            ModelInfo(
                id: "provider/reasoning-model",
                displayName: "Reasoning Model",
                provider: .openRouter,
                supportedReasoningEfforts: [.low, .xhigh, providerLevel],
                defaultReasoningEffort: .xhigh
            )
        ]

        let configuration = catalog.reasoningConfiguration(
            for: "provider/reasoning-model",
            provider: .openRouter
        )

        XCTAssertEqual(configuration?.efforts, [.low, .xhigh, providerLevel])
        XCTAssertEqual(configuration?.defaultEffort, .xhigh)
        XCTAssertNil(catalog.reasoningConfiguration(for: "unknown", provider: .openRouter))
    }
}
