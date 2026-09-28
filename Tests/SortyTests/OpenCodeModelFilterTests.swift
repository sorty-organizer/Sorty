import XCTest
@testable import SortyCore

/// OpenCode serves mixed API protocols from one `/models` endpoint. The
/// catalog keeps all supported protocols and excludes SystemOne.
final class OpenCodeModelFilterTests: XCTestCase {
    private func filtered(_ ids: [String], for provider: AIProvider) -> [String] {
        ModelCatalog.openCodeChatModels(
            ids.map { ModelInfo(id: $0, displayName: $0, provider: provider) },
            for: provider
        ).map(\.id)
    }

    func testZenKeepsNativeProtocolsAndUnknownModels() {
        let result = filtered(
            [
                "glm-5.3", "qwen3.8-max", "minimax-m3",
                "gpt-5.4", "grok-4.7", "claude-sonnet-4-6", "gemini-3-flash",
                "muse-spark-1.3", "jev-1.13", "qwen3.8-flash",
                "future-chat-9",
            ],
            for: .openCodeZen
        )
        XCTAssertEqual(result.count, 10)
        XCTAssertFalse(result.contains("jev-1.13"))
    }

    func testGoKeepsMessagesModels() {
        let result = filtered(
            [
                "glm-5.3", "qwen3.8-max", "minimax-m3",
                "longcat-2.0", "hy3", "omen-alpha",
            ],
            for: .openCodeGo
        )
        // Qwen and MiniMax now use the Messages client on Go.
        XCTAssertEqual(result.sorted(), ["glm-5.3", "hy3", "longcat-2.0", "minimax-m3", "omen-alpha", "qwen3.8-max"])
    }
}
