//
//  ImproveInstructionsToolTests.swift
//  SortyTests
//

import XCTest
@testable import SortyLib
@testable import SortyCore

final class ImproveInstructionsToolTests: XCTestCase {
    func testParsesReplacementAction() {
        let outcome = ImproveInstructionsTool.parse(
            #"{"action":"replace","replacement":"Group invoices by client and year."}"#
        )

        XCTAssertEqual(outcome, .replacement("Group invoices by client and year."))
    }

    func testParsesRequestUserInputAction() {
        let outcome = ImproveInstructionsTool.parse(
            #"{"action":"request_user_input","message":"Add the instruction you want improved."}"#
        )

        XCTAssertEqual(outcome, .needsUserInput("Add the instruction you want improved."))
    }

    func testParsesJSONInsideMarkdownFence() {
        let outcome = ImproveInstructionsTool.parse(
            """
            ```json
            {"action":"replace","replacement":"Keep project files together."}
            ```
            """
        )

        XCTAssertEqual(outcome, .replacement("Keep project files together."))
    }

    func testInterceptsLegacyClarificationProse() {
        let response = "Please provide specific instructions you would like me to improve. Your original input does not contain any text to refine."

        XCTAssertEqual(ImproveInstructionsTool.parse(response), .needsUserInput(response))
    }

    func testInterceptsPlainTextRefusal() {
        let response = "I can't assist with improving those instructions."

        XCTAssertEqual(ImproveInstructionsTool.parse(response), .needsUserInput(response))
    }

    func testPreservesPlainTextFallbackAsReplacement() {
        let response = "Group screenshots by project, then sort each project by capture month."

        XCTAssertEqual(ImproveInstructionsTool.parse(response), .replacement(response))
    }

    func testNaturalLanguageResolverCreatesOrdinaryRules() throws {
        let rules = try NaturalLanguageExclusionResolver.decodeRules(
            from: """
            [
              {"kind":"folder_name","pattern":"Archive","description":"Archive folders"},
              {"kind":"file_size","value":2,"unit":"GB","comparison":"larger","description":"Large files"}
            ]
            """
        )

        XCTAssertEqual(rules.map(\.type), [.folderName, .fileSize])
        XCTAssertEqual(rules[0].pattern, "Archive")
        XCTAssertEqual(rules[1].numericValue, 2_048)
        XCTAssertEqual(rules[1].sizeUnit, .gigabytes)
        XCTAssertTrue(rules.allSatisfy { $0.isAIGenerated == true })
    }

    func testNaturalLanguageResolverPreservesSubdayAge() throws {
        let rule = try XCTUnwrap(
            NaturalLanguageExclusionResolver.decodeRules(
                from: #"[{"kind":"modification_age","value":30,"unit":"minutes","comparison":"newer"}]"#
            ).first
        )

        XCTAssertEqual(rule.type, .modificationDate)
        XCTAssertEqual(rule.ageUnit, .minutes)
        XCTAssertEqual(rule.ageIntervalSeconds, 1_800)
        XCTAssertFalse(try XCTUnwrap(rule.comparisonGreater))
    }

    func testNaturalLanguageResolverDecodesToolSelectionAndSupplement() throws {
        let resolution = try NaturalLanguageExclusionResolver.decodeResolution(
            from: """
            {
              "tools": [
                {
                  "kind": "finder_tag",
                  "finderTag": "purple",
                  "description": "Protected work files"
                },
                {
                  "kind": "file_name_contains",
                  "pattern": "Draft",
                  "caseSensitive": true,
                  "negated": false,
                  "description": "Exact-case drafts"
                }
              ],
              "supplementalDescription": "Keep sibling project files together."
            }
            """
        )

        XCTAssertEqual(resolution.rules.map(\.type), [.finderTag, .fileName])
        XCTAssertEqual(resolution.rules[0].pattern, String(FinderTagColor.purple.rawValue))
        XCTAssertTrue(resolution.rules[1].caseSensitive)
        XCTAssertFalse(resolution.rules[1].negated)
        XCTAssertEqual(
            resolution.supplementalDescription,
            "Keep sibling project files together."
        )
    }

    func testNaturalLanguageResolverLinksThreeConditions() throws {
        let resolution = try NaturalLanguageExclusionResolver.decodeResolution(
            from: """
            {
              "rules": [
                {"kind":"file_category","category":"Videos","group":"old-large-videos"},
                {"kind":"file_size","value":1,"unit":"GB","comparison":"larger","group":"old-large-videos"},
                {"kind":"modification_age","value":30,"unit":"days","comparison":"older","group":"old-large-videos"}
              ]
            }
            """
        )

        XCTAssertEqual(resolution.rules.count, 3)
        let groupIDs = Set(resolution.rules.compactMap(\.conditionGroupID))
        XCTAssertEqual(groupIDs.count, 1)
        XCTAssertTrue(resolution.rules.allSatisfy { $0.conditionGroupID != nil })
    }

    func testNaturalLanguageResolverAcceptsCommonProviderVariations() throws {
        let resolution = try NaturalLanguageExclusionResolver.decodeResolution(
            from: """
            {
              "rules": [
                {"type":"file_type","category":"Video","conditionGroup":"large-videos"},
                {"tool":"file-size","value":"1","unit":"gigabytes","comparison":"greater_than","conditionGroup":"large-videos"}
              ]
            }
            """
        )

        XCTAssertEqual(resolution.rules.map(\.type), [.fileType, .fileSize])
        XCTAssertEqual(resolution.rules[1].numericValue, 1_024)
        XCTAssertEqual(Set(resolution.rules.compactMap(\.conditionGroupID)).count, 1)
    }
}
