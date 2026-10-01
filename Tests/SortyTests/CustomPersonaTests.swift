//
//  CustomPersonaTests.swift
//  SortyTests
//
//  Tests for custom persona creation and management
//

import XCTest
@testable import SortyLib
@testable import SortyCore

final class CustomPersonaTests: XCTestCase {
    
    // MARK: - CustomPersona Tests
    
    func testCustomPersonaCreation() {
        let persona = CustomPersona(
            name: "Test Persona",
            icon: "star.fill",
            description: "A test persona",
            promptModifier: "Organize files by test criteria"
        )
        
        XCTAssertFalse(persona.id.isEmpty)
        XCTAssertEqual(persona.name, "Test Persona")
        XCTAssertEqual(persona.icon, "star.fill")
        XCTAssertEqual(persona.description, "A test persona")
        XCTAssertEqual(persona.promptModifier, "Organize files by test criteria")
    }
    
    func testCustomPersonaUpdate() {
        var persona = CustomPersona(
            name: "Original",
            icon: "folder",
            description: "Original description",
            promptModifier: "Original prompt"
        )
        
        let originalModified = persona.modifiedAt
        
        persona.update(
            name: "Updated",
            icon: "star",
            description: "Updated description",
            prompt: "Updated prompt"
        )
        
        XCTAssertEqual(persona.name, "Updated")
        XCTAssertEqual(persona.icon, "star")
        XCTAssertEqual(persona.description, "Updated description")
        XCTAssertEqual(persona.promptModifier, "Updated prompt")
        XCTAssertGreaterThanOrEqual(persona.modifiedAt, originalModified)
    }
    
    func testCustomPersonaCodable() throws {
        let suggestions = PersonaInstructionSuggestions(
            organize: ["Group research by paper, then by source type."],
            organizeAndRename: ["Group by paper, then put confirmed publication years first."],
            renameOnly: ["Use author, year, and a shortened paper title."]
        )
        let original = CustomPersona(
            name: "Codable Test",
            icon: "doc.fill",
            description: "Testing codable",
            promptModifier: "Some prompt",
            instructionSuggestions: suggestions
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CustomPersona.self, from: data)
        
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.icon, original.icon)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.promptModifier, original.promptModifier)
        XCTAssertEqual(decoded.instructionSuggestions, suggestions)
    }

    func testLegacyPersonaWithoutInstructionSuggestionsStillDecodes() throws {
        let original = CustomPersona(
            name: "Legacy Persona",
            icon: "folder.fill",
            description: "Saved before suggestions",
            promptModifier: "Keep projects together"
        )
        let encoded = try JSONEncoder().encode(original)
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "instructionSuggestions")

        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoded = try JSONDecoder().decode(CustomPersona.self, from: legacyData)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.instructionSuggestions, PersonaInstructionSuggestions())
    }

    func testInstructionSuggestionsExcludeFillInPlaceholders() {
        let suggestions = PersonaInstructionSuggestions(
            organize: [
                "Group files by project and keep related documents together.",
                "Move files into [Project] folders."
            ],
            organizeAndRename: [
                "Group files by project and rename them using confirmed metadata.",
                "Rename files with [ProjectCode]_[Version].",
                "Rename files with {Client} and a confirmed date.",
                "Rename files with <Department> and document type."
            ]
        )

        XCTAssertEqual(
            suggestions.suggestions(for: .organize),
            ["Group files by project and keep related documents together."]
        )
        XCTAssertEqual(
            suggestions.suggestions(for: .organizeAndRename),
            ["Group files by project and rename them using confirmed metadata."]
        )
    }
}
