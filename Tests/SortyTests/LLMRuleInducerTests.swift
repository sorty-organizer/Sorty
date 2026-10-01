//
//  LLMRuleInducerTests.swift
//  SortyTests
//
//  Tests for LLMRuleInducer using MockAIClient
//

import XCTest
@testable import SortyLib
@testable import SortyCore

@MainActor
final class LLMRuleInducerTests: XCTestCase {
    
    // Mock Client (generateText-focused).
    // NOTE: Intentionally divergent from the actor MockAIClient in
    // SortyLibTests.swift (analyze-focused). See the note there for why the
    // two are kept separate.
    final class MockAIClient: AIClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) var config: AIConfig = AIConfig()
        nonisolated(unsafe) var generateTextResponse: String = ""
        nonisolated(unsafe) var streamingDelegate: StreamingDelegate?
        
        nonisolated func analyze(files: [FileItem], customInstructions: String?, personaPrompt: String?, temperature: Double?) async throws -> OrganizationPlan {
            fatalError("Not implemented for this test")
        }
        
        nonisolated func generateText(prompt: String, systemPrompt: String?) async throws -> String {
            return generateTextResponse
        }
        
        nonisolated func checkHealth() async throws {
            // Success by default
        }

        nonisolated func analyzeWithImages(files: [FileItem], imageData: [String: Data], customInstructions: String?, personaPrompt: String?, temperature: Double?) async throws -> OrganizationPlan {
            fatalError("Not implemented for this test")
        }
    }
    
    var inducer: LLMRuleInducer!
    var mockClient: MockAIClient!
    
    override func setUp() async throws {
        
        mockClient = MockAIClient()
        inducer = LLMRuleInducer(aiClient: mockClient)
    }
    
    override func tearDown() async throws {
        inducer = nil
        mockClient = nil
        
    }
    
    func testInduceRulesFromExamples() async {
        // Setup mock response
        let jsonResponse = """
        [
            {
                "pattern": "Invoice.*",
                "template": "Finance/{year}/Invoices/{filename}",
                "priority": 80,
                "explanation": "Organize invoices by year"
            }
        ]
        """
        mockClient.generateTextResponse = jsonResponse
        
        let examples = [
            LabeledExample(srcPath: "Invoice.pdf", dstPath: "Finance/2024/Invoices/Invoice.pdf")
        ]
        
        let rules = await inducer.induceRules(from: examples, exampleFolders: [])
        
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.pattern, "Invoice.*")
        XCTAssertEqual(rules.first?.template, "Finance/{year}/Invoices/{filename}")
        XCTAssertEqual(rules.first?.explanation, "Organize invoices by year")

        mockClient.generateTextResponse = """
        Here are the rules:
        ```json
        [
            {
                "pattern": ".*\\\\.jpg$",
                "template": "Photos/{date}/{filename}",
                "priority": 50,
                "explanation": "Photos by date"
            }
        ]
        ```
        """

        let fencedExamples = [
            LabeledExample(srcPath: "photo.jpg", dstPath: "Photos/2024/photo.jpg")
        ]

        let fencedRules = await inducer.induceRules(from: fencedExamples, exampleFolders: [])

        XCTAssertEqual(fencedRules.count, 1)
        XCTAssertEqual(fencedRules.first?.pattern, ".*\\.jpg$")
    }
    
    func testInduceRulesWithInvalidJSON() async {
        mockClient.generateTextResponse = "This is not JSON"
        
        let examples = [LabeledExample(srcPath: "a", dstPath: "b")]
        let rules = await inducer.induceRules(from: examples, exampleFolders: [])
        
        XCTAssertTrue(rules.isEmpty)
    }
}
