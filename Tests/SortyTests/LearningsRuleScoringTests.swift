//
//  LearningsRuleScoringTests.swift
//  SortyTests
//
//  Tests for rule eligibility, confidence scoring, avoid-rule parsing,
//  and merge-strengthening on re-inference.
//

import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyLearnings

final class LearningsRuleScoringTests: XCTestCase {

    // MARK: - Eligibility

    func testEligibilityRespectsEnabledStatusAndCooldown() {
        let now = Date()

        let active = InferredRule(pattern: ".*", template: "A/{filename}", explanation: "active")
        XCTAssertTrue(active.isEligible(at: now))

        var disabled = active
        disabled.isEnabled = false
        XCTAssertFalse(disabled.isEligible(at: now))

        var rejected = active
        rejected.status = .rejected
        XCTAssertFalse(rejected.isEligible(at: now))

        var coolingDown = active
        coolingDown.cooldownUntil = now.addingTimeInterval(3600)
        XCTAssertFalse(coolingDown.isEligible(at: now))

        var cooldownExpired = active
        cooldownExpired.cooldownUntil = now.addingTimeInterval(-3600)
        XCTAssertTrue(cooldownExpired.isEligible(at: now))
    }

    // MARK: - Effective confidence

    func testEffectiveConfidenceRanksProvenRulesAboveFailingRules() {
        let proven = InferredRule(
            pattern: ".*\\.pdf$",
            template: "Documents/{filename}",
            priority: 60,
            explanation: "proven",
            successCount: 10,
            failureCount: 0,
            supportCount: 5
        )
        let failing = InferredRule(
            pattern: ".*\\.pdf$",
            template: "Archive/{filename}",
            priority: 60,
            explanation: "failing",
            successCount: 0,
            failureCount: 10,
            supportCount: 5
        )
        let unused = InferredRule(
            pattern: ".*\\.pdf$",
            template: "Misc/{filename}",
            priority: 60,
            explanation: "unused",
            supportCount: 5
        )

        let now = Date()
        XCTAssertGreaterThan(proven.effectiveConfidence(at: now), unused.effectiveConfidence(at: now))
        XCTAssertGreaterThan(unused.effectiveConfidence(at: now), failing.effectiveConfidence(at: now))
    }

    func testEffectiveConfidenceStaysWithinBounds() {
        let extreme = InferredRule(
            pattern: ".*",
            template: "A/{filename}",
            priority: 500,
            explanation: "clamped",
            successCount: 1_000,
            failureCount: 0,
            supportCount: 100_000
        )
        let confidence = extreme.effectiveConfidence()
        XCTAssertLessThanOrEqual(confidence, 1.0)
        XCTAssertGreaterThanOrEqual(confidence, 0.0)

        let stale = InferredRule(
            pattern: ".*",
            template: "B/{filename}",
            priority: 60,
            explanation: "stale",
            lastAppliedAt: Date().addingTimeInterval(-120 * 86_400)
        )
        let fresh = InferredRule(
            pattern: ".*",
            template: "B/{filename}",
            priority: 60,
            explanation: "fresh",
            lastAppliedAt: Date()
        )
        XCTAssertLessThan(stale.effectiveConfidence(), fresh.effectiveConfidence())
    }

    // MARK: - Avoid rules

    func testAvoidedFolderNameParsing() {
        let avoid = InferredRule(
            pattern: ".*\\.png$",
            template: "AVOID:Documents/{filename}",
            priority: -35,
            explanation: "avoid"
        )
        XCTAssertTrue(avoid.isAvoidRule)
        XCTAssertEqual(avoid.avoidedFolderName, "Documents")

        let normal = InferredRule(pattern: ".*", template: "Documents/{filename}", explanation: "normal")
        XCTAssertFalse(normal.isAvoidRule)
        XCTAssertNil(normal.avoidedFolderName)
    }

    // MARK: - Re-inference merge

    @MainActor
    func testLocalRuleInferenceStrengthensExistingRuleInsteadOfSkipping() async {
        let suiteName = "LearningsRuleScoringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = LearningsManager(userDefaults: defaults)
        var profile = LearningsProfile()
        profile.consentGranted = true
        profile.postOrganizationChanges = [
            DirectoryChange(originalPath: "/tmp/src/alpha.pdf", newPath: "/tmp/dest/Documents/alpha.pdf", wasAIOrganized: true),
            DirectoryChange(originalPath: "/tmp/src/beta.pdf", newPath: "/tmp/dest/Documents/beta.pdf", wasAIOrganized: true)
        ]
        manager.currentProfile = profile

        await manager.runLocalRuleInference()

        guard let firstRule = manager.currentProfile?.inferredRules.first(where: { $0.pattern == ".*\\.pdf$" }) else {
            XCTFail("Expected an inferred .pdf rule after first inference run")
            return
        }
        let key = "\(firstRule.pattern)|\(firstRule.template)"

        // User disables the rule, then more evidence arrives and inference reruns.
        await manager.setRuleEnabled(ruleId: firstRule.id, enabled: false)
        manager.currentProfile?.postOrganizationChanges.append(
            DirectoryChange(originalPath: "/tmp/src/gamma.pdf", newPath: "/tmp/dest/Documents/gamma.pdf", wasAIOrganized: true)
        )

        await manager.runLocalRuleInference()

        let matching = manager.currentProfile?.inferredRules.filter { "\($0.pattern)|\($0.template)" == key } ?? []
        XCTAssertEqual(matching.count, 1, "Re-inference must merge into the existing rule, not duplicate it")

        let merged = matching[0]
        XCTAssertEqual(merged.id, firstRule.id, "Merged rule must keep its identity")
        XCTAssertGreaterThan(merged.supportCount, firstRule.supportCount, "New evidence must strengthen the existing rule")
        XCTAssertFalse(merged.isEnabled, "User-disabled state must survive re-inference")
    }

    @MainActor
    func testLocalInferenceRemovesLegacyBroadRejectionRules() async {
        let suiteName = "LearningsRuleScoringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = LearningsManager(userDefaults: defaults)
        var profile = LearningsProfile()
        profile.consentGranted = true
        profile.inferredRules = [
            InferredRule(
                id: "local-avoid-mov-Media-old",
                pattern: ".*\\.mov$",
                template: "AVOID:Media/{filename}",
                explanation: "Legacy broad rejection rule"
            )
        ]
        manager.currentProfile = profile

        await manager.runLocalRuleInference()

        XCTAssertFalse(manager.currentProfile?.inferredRules.contains { $0.id.hasPrefix("local-avoid-") } ?? true)
    }
}

extension LearningsRuleScoringTests {

    func testRuleRelevanceBoostRewardsExtensionAndKeywordOverlap() {
        let invoiceRule = InferredRule(
            pattern: "Invoice.*\\.pdf$",
            template: "Finance/{year}/Invoices/{filename}",
            priority: 10,
            explanation: "Organize invoices by year"
        )
        let photoRule = InferredRule(
            pattern: ".*\\.jpg$",
            template: "Photos/{filename}",
            priority: 10,
            explanation: "Photos to Photos folder"
        )

        XCTAssertGreaterThan(
            LearningsManager.ruleRelevanceBoost(invoiceRule, fileNames: ["Invoice_2024_01.pdf"]),
            LearningsManager.ruleRelevanceBoost(photoRule, fileNames: ["Invoice_2024_01.pdf"])
        )
        XCTAssertEqual(
            LearningsManager.ruleRelevanceBoost(photoRule, fileNames: ["IMG_001.jpg"]),
            0.05,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LearningsManager.ruleRelevanceBoost(invoiceRule, fileNames: ["IMG_001.jpg"]),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(LearningsManager.ruleRelevanceBoost(invoiceRule, fileNames: []), 0)
    }

    func testRuleRelevanceBoostIgnoresSubstringFalsePositives() {
        // "mov" must not match via the word "moved" in the explanation.
        let unrelated = InferredRule(
            pattern: ".*",
            template: "{category}/{filename}",
            priority: 10,
            explanation: "User moved file after organization"
        )
        XCTAssertEqual(LearningsManager.ruleRelevanceBoost(unrelated, fileNames: ["clip.mov"]), 0)
    }

    @MainActor
    func testGetActiveRulesOrderingIsStableForIdenticalScores() {
        let suiteName = "LearningsRuleScoringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = LearningsManager(userDefaults: defaults)
        var profile = LearningsProfile()
        profile.consentGranted = true
        profile.inferredRules = ["c-rule", "a-rule", "b-rule"].map { id in
            InferredRule(
                id: id,
                pattern: ".*\\.txt$",
                template: "Text/{filename}",
                priority: 50,
                explanation: "Text rule \(id)",
                status: .active
            )
        }
        manager.currentProfile = profile

        let first = manager.getActiveRules().map(\.id)
        let second = manager.getActiveRules().map(\.id)
        XCTAssertEqual(first, ["a-rule", "b-rule", "c-rule"])
        XCTAssertEqual(first, second)
    }
}
