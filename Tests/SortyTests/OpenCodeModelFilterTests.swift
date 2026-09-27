import XCTest
@testable import SortyCore

/// OpenCode serves mixed API protocols from one `/models` endpoint. The
/// catalog keeps everything except documented non-chat models so newly
/// added chat models appear without an allowlist update.
final class OpenCodeModelFilterTests: XCTestCase {
    private func filtered(_ ids: [String], for provider: AIProvider) -> [String] {
        ModelCatalog.openCodeChatModels(
            ids.map { ModelInfo(id: $0, displayName: $0, provider: provider) },
            for: provider
        ).map(\.id)
    }

    func testZenDropsNonChatProtocolsKeepsChatAndUnknown() {
        let result = filtered(
            [
                "glm-5.3", "qwen3.8-max", "minimax-m3",
                "gpt-5.4", "grok-4.7", "claude-sonnet-4-6", "gemini-3-flash",
                "muse-spark-1.3", "jev-1.13", "qwen3.8-flash",
                "future-chat-9",
            ],
            for: .openCodeZen
        )
        XCTAssertEqual(result.sorted(), ["future-chat-9", "glm-5.3", "minimax-m3", "qwen3.8-max"])
    }

    func testGoDropsPlanSpecificNonChatModels() {
        let result = filtered(
            [
                "glm-5.3", "qwen3.8-max", "minimax-m3",
                "longcat-2.0", "hy3", "omen-alpha",
            ],
            for: .openCodeGo
        )
        // Qwen/Minimax are Messages-only on Go; unknown IDs stay included.
        XCTAssertEqual(result.sorted(), ["glm-5.3", "hy3", "longcat-2.0", "omen-alpha"])
    }
}
