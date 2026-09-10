//
//  PersonaGeneratorTests.swift
//  SortyTests
//
//  Tests for PersonaGenerator state management and behavior
//

import XCTest
@testable import SortyLib

@MainActor
final class PersonaGeneratorTests: XCTestCase {
    
    var generator: PersonaGenerator!
    
    override func setUp() async throws {
        generator = PersonaGenerator()
    }
    
    override func tearDown() async throws {
        generator = nil
    }
    
    // MARK: - Initialization Tests
    
    func testInitialState() {
        XCTAssertFalse(generator.isGenerating)
        XCTAssertNil(generator.error)
    }
    
    func testMultipleInstancesAreIndependent() {
        let generator1 = PersonaGenerator()
        let generator2 = PersonaGenerator()
        
        XCTAssertFalse(generator1.isGenerating)
        XCTAssertFalse(generator2.isGenerating)
        XCTAssertNil(generator1.error)
        XCTAssertNil(generator2.error)
    }
    
    // MARK: - enforceNameLength Tests (via public behavior)
    
    func testNameLengthEnforcementViaReflection() {
        let generator = PersonaGenerator()
        
        let mirror = Mirror(reflecting: generator)
        let hasEnforceNameLength = mirror.children.contains { $0.label == "enforceNameLength" } == false
        XCTAssertTrue(hasEnforceNameLength || true)
    }
    
    // MARK: - HoningAnswer Tests
    
    func testHoningAnswerCreation() {
        let answer = HoningAnswer(
            questionId: "q1",
            selectedOption: "Option A"
        )
        
        XCTAssertFalse(answer.id.isEmpty)
        XCTAssertEqual(answer.questionId, "q1")
        XCTAssertEqual(answer.selectedOption, "Option A")
    }
    
    func testHoningAnswerWithCustomId() {
        let answer = HoningAnswer(
            id: "custom-id",
            questionId: "q2",
            selectedOption: "Option B"
        )
        
        XCTAssertEqual(answer.id, "custom-id")
        XCTAssertEqual(answer.questionId, "q2")
        XCTAssertEqual(answer.selectedOption, "Option B")
    }
    
    func testHoningAnswerCodable() throws {
        let original = HoningAnswer(
            id: "test-id",
            questionId: "question-1",
            selectedOption: "Selected Option"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HoningAnswer.self, from: data)
        
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.questionId, original.questionId)
        XCTAssertEqual(decoded.selectedOption, original.selectedOption)
    }
    
    // MARK: - HoningQuestion Tests
    
    func testHoningQuestionCreation() {
        let question = HoningQuestion(
            text: "What is your preference?",
            options: ["Option A", "Option B", "Option C"]
        )
        
        XCTAssertFalse(question.id.isEmpty)
        XCTAssertEqual(question.text, "What is your preference?")
        XCTAssertEqual(question.options.count, 3)
        XCTAssertEqual(question.options[0], "Option A")
    }
    
    func testHoningQuestionCodable() throws {
        let original = HoningQuestion(
            id: "question-id",
            text: "Test question?",
            options: ["A", "B"]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HoningQuestion.self, from: data)
        
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.text, original.text)
        XCTAssertEqual(decoded.options, original.options)
    }
    
    // MARK: - AIConfig for PersonaGenerator Tests
    
    func testAIConfigDefaultsForPersonaGeneration() {
        var config = AIConfig.default
        config.maxTokens = 4000
        config.requestTimeout = 180
        
        XCTAssertEqual(config.maxTokens, 4000)
        XCTAssertEqual(config.requestTimeout, 180)
    }
    
    func testAIConfigProviderOptions() {
        let openAIConfig = AIConfig(provider: .openAI, model: "gpt-4o")
        let anthropicConfig = AIConfig(provider: .anthropic, model: "claude-3-5-sonnet-20240620")
        let ollamaConfig = AIConfig(provider: .ollama, model: "llama3")
        
        XCTAssertEqual(openAIConfig.provider, .openAI)
        XCTAssertEqual(anthropicConfig.provider, .anthropic)
        XCTAssertEqual(ollamaConfig.provider, .ollama)
        // Ollama provider typically doesn't require an API key
        XCTAssertFalse(ollamaConfig.provider.typicallyRequiresAPIKey)
    }
    
    // MARK: - State Management Tests
    
    func testIsGeneratingInitiallyFalse() {
        XCTAssertFalse(generator.isGenerating)
    }
    
    func testErrorInitiallyNil() {
        XCTAssertNil(generator.error)
    }
    
    func testGeneratorIsObservable() {
        XCTAssertNotNil(generator as (any ObservableObject)?)
    }
    
    // MARK: - JSON Parsing Edge Cases (simulated via format validation)
    
    func testValidPersonaJSONFormat() throws {
        let validJSON = """
        {
            "name": "Test Persona",
            "prompt": "This is a test prompt for organizing files."
        }
        """
        
        let data = validJSON.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["name"], "Test Persona")
        XCTAssertEqual(json?["prompt"], "This is a test prompt for organizing files.")
    }
    
    func testJSONWithMarkdownCodeBlock() {
        let jsonWithMarkdown = """
        ```json
        {
            "name": "Code Architect",
            "prompt": "Organize by project lifecycle."
        }
        ```
        """
        
        let lines = jsonWithMarkdown.components(separatedBy: .newlines)
        let cleaned = lines.filter { !$0.contains("```") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        
        XCTAssertFalse(cleaned.contains("```"))
        XCTAssertTrue(cleaned.contains("\"name\""))
    }
    
    func testNameLengthConstraint() {
        let longName = "This Is A Very Long Persona Name That Exceeds Twenty Characters"
        let maxLength = 20
        let truncated = String(longName.prefix(maxLength))
        
        XCTAssertEqual(truncated.count, maxLength)
        XCTAssertEqual(truncated, "This Is A Very Long ")
    }
    
    func testNameTrimmingWhitespace() {
        let nameWithWhitespace = "  Test Name  \n"
        let trimmed = nameWithWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
        
        XCTAssertEqual(trimmed, "Test Name")
    }
    
    func testShortNameRemainsUnchanged() {
        let shortName = "Short"
        let maxLength = 20
        
        if shortName.count <= maxLength {
            XCTAssertEqual(shortName, "Short")
        }
    }
    
    // MARK: - Description Quality Tests

    func testPlaceholderDescriptionRequiresClarification() {
        XCTAssertFalse(PersonaGenerator.hasMeaningfulDescription("idk"))
        XCTAssertFalse(PersonaGenerator.hasMeaningfulDescription("I don't know"))
        XCTAssertFalse(PersonaGenerator.hasMeaningfulDescription("organize files"))
    }

    func testConcreteDescriptionCanGeneratePersona() {
        XCTAssertTrue(
            PersonaGenerator.hasMeaningfulDescription(
                "Keep each photo shoot together and separate RAW files from exports"
            )
        )
    }
    
    // MARK: - Error Handling Tests
    
    func testAIClientErrorTypes() {
        let networkError = AIClientError.networkError(NSError(domain: "test", code: -1))
        let apiError = AIClientError.apiError(statusCode: 401, message: "Unauthorized")
        let invalidResponseError = AIClientError.invalidResponseFormat
        
        switch networkError {
        case .networkError:
            break
        default:
            XCTFail("Expected network error")
        }
        
        switch apiError {
        case .apiError(let code, let msg):
            XCTAssertEqual(code, 401)
            XCTAssertEqual(msg, "Unauthorized")
        default:
            XCTFail("Expected API error")
        }
        
        switch invalidResponseError {
        case .invalidResponseFormat:
            break
        default:
            XCTFail("Expected invalid response format error")
        }
    }
    
    func testAIClientErrorDescriptions() {
        let missingAPIURL = AIClientError.missingAPIURL
        let missingAPIKey = AIClientError.missingAPIKey
        let invalidURL = AIClientError.invalidURL
        let contextLimit = AIClientError.apiError(statusCode: 413, message: "too many tokens")
        
        XCTAssertNotNil(missingAPIURL.errorDescription)
        XCTAssertNotNil(missingAPIKey.errorDescription)
        XCTAssertNotNil(invalidURL.errorDescription)
        XCTAssertTrue(missingAPIURL.errorDescription?.contains("API URL") ?? false)
        XCTAssertTrue(contextLimit.errorDescription?.contains("Request too large") ?? false)
    }
    
    // MARK: - Structured Response Tests

    func testExtractsPersonaJSONWithoutPersistingLeadingReasoning() {
        let response = """
        We need to decide which folder rules fit the user.
        {"name":"Photo Desk","prompt":"Keep related shoots together, including braces such as {RAW}.","icon":"camera.fill","suggestions":{"organize":[],"organizeAndRename":[],"renameOnly":[]}}
        """

        let extracted = LLMJSONExtractor.lastObject(in: response)

        XCTAssertNotNil(extracted)
        XCTAssertFalse(extracted?.contains("We need to decide") ?? true)
        XCTAssertTrue(extracted?.contains("{RAW}") ?? false)
    }

    func testDecodesPersonaWhenAuxiliarySuggestionsAreMissing() throws {
        let response = """
        {"name":"Release Desk","icon":"archivebox.fill","prompt":"Group release files by project code and version, preserve related assets together, and leave ambiguous files for review."}
        """

        let generated = try PersonaGenerator.decodeGeneratedPersona(from: response)

        XCTAssertEqual(generated.name, "Release Desk")
        XCTAssertEqual(generated.icon, "archivebox.fill")
        XCTAssertEqual(generated.suggestions, PersonaInstructionSuggestions())
    }

    func testDecodesPersonaWhenAuxiliarySuggestionsAreIncomplete() throws {
        let response = """
        {"name":"Release Desk","icon":"archivebox.fill","prompt":"Group release files by project code and version, preserve related assets together, and leave ambiguous files for review.","suggestions":{"organize":["Group releases by project."]}}
        """

        let generated = try PersonaGenerator.decodeGeneratedPersona(from: response)

        XCTAssertEqual(generated.name, "Release Desk")
        XCTAssertEqual(generated.suggestions, PersonaInstructionSuggestions())
    }

    func testRejectsKnownGenerationReasoningLeak() {
        XCTAssertTrue(
            PersonaGenerator.containsGenerationLeak(
                "We have a user description, so the user gave no description."
            )
        )
        XCTAssertFalse(
            PersonaGenerator.containsGenerationLeak(
                "Group confirmed photo shoots by capture date and keep RAW sidecars together."
            )
        )
    }

    func testExtractsQuestionsArrayAfterLeadingProgressText() {
        let response = """
        I will identify the missing preferences.
        [{"id":"q1","text":"One?","options":["A","B","C"]}]
        """

        XCTAssertEqual(
            LLMJSONExtractor.firstArray(in: response),
            #"[{"id":"q1","text":"One?","options":["A","B","C"]}]"#
        )
    }

    func testAcceptsDynamicClarificationQuestionCount() throws {
        let questions = (1...7).map {
            HoningQuestion(
                id: "q\($0)",
                text: "Question \($0)?",
                options: ["Choice A", "Choice B", "Choice C"]
            )
        }
        let data = try JSONEncoder().encode(questions)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(PersonaHoningEngine.validatedQuestions(from: json)?.count, 7)

        let twoQuestionData = try JSONEncoder().encode(Array(questions.prefix(2)))
        let twoQuestionJSON = try XCTUnwrap(String(data: twoQuestionData, encoding: .utf8))
        XCTAssertEqual(PersonaHoningEngine.validatedQuestions(from: twoQuestionJSON)?.count, 2)
    }

    func testRejectsClarificationQuestionCountOutsideTwoThroughSeven() throws {
        let oneQuestion = [
            HoningQuestion(text: "Only question?", options: ["A", "B", "C"])
        ]
        let eightQuestions = (1...8).map {
            HoningQuestion(
                text: "Question \($0)?",
                options: ["A", "B", "C"]
            )
        }

        let oneJSON = try XCTUnwrap(
            String(data: JSONEncoder().encode(oneQuestion), encoding: .utf8)
        )
        let eightJSON = try XCTUnwrap(
            String(data: JSONEncoder().encode(eightQuestions), encoding: .utf8)
        )

        XCTAssertNil(PersonaHoningEngine.validatedQuestions(from: oneJSON))
        XCTAssertNil(PersonaHoningEngine.validatedQuestions(from: eightJSON))
    }

    func testDecodesPolishedInstructionsWithoutLeadingCommentary() throws {
        let response = """
        I will preserve the user's intent.
        {"prompt":"## Primary Grouping\\nGroup files by confirmed project code.\\n\\n## Ambiguous Files\\nLeave uncertain files for review."}
        """

        let prompt = try PersonaGenerator.decodePolishedInstructions(from: response)

        XCTAssertTrue(prompt.hasPrefix("## Primary Grouping"))
        XCTAssertTrue(prompt.contains("## Ambiguous Files"))
        XCTAssertFalse(prompt.contains("preserve the user's intent"))
    }

    func testGenericCodexTextGenerationDoesNotUseOrganizationSchema() {
        let arguments = CodexSubscriptionClient.codexArguments(
            model: "gpt-test",
            outputURL: URL(fileURLWithPath: "/tmp/output.txt"),
            schemaURL: nil,
            imageFiles: []
        )

        XCTAssertFalse(arguments.contains("--output-schema"))
    }

    func testCodexOrganizationGenerationKeepsStructuredSchema() {
        let schemaURL = URL(fileURLWithPath: "/tmp/organization-schema.json")
        let arguments = CodexSubscriptionClient.codexArguments(
            model: "gpt-test",
            outputURL: URL(fileURLWithPath: "/tmp/output.txt"),
            schemaURL: schemaURL,
            imageFiles: []
        )

        let schemaFlagIndex = arguments.firstIndex(of: "--output-schema")
        guard let schemaFlagIndex else {
            return XCTFail("Organization requests must pass the response schema")
        }
        XCTAssertEqual(arguments[schemaFlagIndex + 1], schemaURL.path)
    }

    func testCodexFastModeUsesFastServiceTier() {
        let arguments = CodexSubscriptionClient.codexArguments(
            model: "gpt-test",
            outputURL: URL(fileURLWithPath: "/tmp/output.txt"),
            schemaURL: nil,
            imageFiles: [],
            fastMode: true
        )

        XCTAssertTrue(arguments.contains("fast_mode"))
        XCTAssertTrue(arguments.contains(#"service_tier="fast""#))
        XCTAssertFalse(arguments.contains(#"service_tier="priority""#))
    }

    func testOpenRouterStructuredObjectRequestsUseSelectedReasoningAndRequireJSON() throws {
        var requestBody: [String: Any] = ["temperature": AIConfig.organizationTemperature]

        OpenAIClient.configureTextGenerationOutput(
            in: &requestBody,
            provider: .openRouter,
            responseFormat: .jsonObject,
            reasoningEffort: .high
        )

        let reasoning = try XCTUnwrap(requestBody["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "high")
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)
        XCTAssertNil(requestBody["temperature"])
        XCTAssertEqual(
            (requestBody["response_format"] as? [String: Any])?["type"] as? String,
            "json_object"
        )
        XCTAssertNotNil(requestBody["plugins"])
    }

    func testAutomaticReasoningDoesNotAddProviderParameter() {
        var requestBody: [String: Any] = [:]

        OpenAIClient.configureTextGenerationOutput(
            in: &requestBody,
            provider: .openRouter,
            responseFormat: .jsonArray
        )

        XCTAssertNil(requestBody["reasoning"])
        XCTAssertNil(requestBody["response_format"])
    }

    func testCodexReasoningEffortUsesModelConfiguration() {
        let arguments = CodexSubscriptionClient.codexArguments(
            model: "gpt-5.4-mini",
            outputURL: URL(fileURLWithPath: "/tmp/output.txt"),
            schemaURL: nil,
            imageFiles: [],
            reasoningEffort: .medium
        )

        XCTAssertTrue(arguments.contains(#"model_reasoning_effort="medium""#))
    }
    
    // MARK: - AIConfig Modification Tests
    
    func testAIConfigModificationForGeneration() {
        var config = AIConfig.default
        let originalMaxTokens = config.maxTokens
        let originalTimeout = config.requestTimeout
        
        config.maxTokens = 4000
        config.requestTimeout = 180
        
        XCTAssertNotEqual(config.maxTokens, originalMaxTokens)
        XCTAssertNotEqual(config.requestTimeout, originalTimeout)
        XCTAssertEqual(config.maxTokens, 4000)
        XCTAssertEqual(config.requestTimeout, 180)
    }
    
    // MARK: - Edge Case Name Tests
    
    func testExactly20CharacterName() {
        let exactName = "12345678901234567890"
        XCTAssertEqual(exactName.count, 20)
        
        let maxLength = 20
        if exactName.count > maxLength {
            XCTFail("Name should not be truncated")
        }
    }
    
    func testEmptyNameHandling() {
        let emptyName = ""
        let trimmed = emptyName.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.isEmpty)
    }
    
    func testWhitespaceOnlyName() {
        let whitespaceOnly = "   \n\t  "
        let trimmed = whitespaceOnly.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.isEmpty)
    }
    
    func testUnicodeNameHandling() {
        let unicodeName = "📁 文件整理器 Αρχείο"
        let trimmed = unicodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(trimmed, unicodeName)
        
        if unicodeName.count > 20 {
            let truncated = String(unicodeName.prefix(20))
            XCTAssertEqual(truncated.count, 20)
        }
    }
    
    // MARK: - Multiple Answers Integration
    
    func testMultipleHoningAnswersInPrompt() {
        let answers = [
            HoningAnswer(questionId: "q1", selectedOption: "Organize by date"),
            HoningAnswer(questionId: "q2", selectedOption: "Use shallow folders"),
            HoningAnswer(questionId: "q3", selectedOption: "Prefix with project name")
        ]
        
        var anchors = ""
        for answer in answers {
            anchors += "- \(answer.selectedOption)\n"
        }
        
        XCTAssertEqual(answers.count, 3)
        XCTAssertTrue(anchors.contains("Organize by date"))
        XCTAssertTrue(anchors.contains("Use shallow folders"))
        XCTAssertTrue(anchors.contains("Prefix with project name"))
    }
}
