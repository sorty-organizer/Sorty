//
//  LearningsRuleScoringTests.swift
//  SortyTests
//
//  Focused tests for rule eligibility, unified confidence scoring, avoid-rule
//  handling in mapping proposals, and merge-strengthening on re-inference.
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

    // MARK: - proposeMapping

    @MainActor
    func testProposeMappingSkipsIneligibleRules() async {
        let analyzer = LearningsAnalyzer()
        let disabledStrong = InferredRule(
            pattern: ".*\\.pdf$",
            template: "Disabled/{filename}",
            priority: 95,
            explanation: "disabled strong rule",
            isEnabled: false
        )
        let enabledWeak = InferredRule(
            pattern: ".*\\.pdf$",
            template: "Enabled/{filename}",
            priority: 40,
            explanation: "enabled weak rule"
        )

        let mapping = await analyzer.proposeMapping(
            for: URL(fileURLWithPath: "/tmp/root/report.pdf"),
            using: [disabledStrong, enabledWeak],
            rootPath: "/tmp/root"
        )

        XCTAssertEqual(mapping.ruleId, enabledWeak.id)
        XCTAssertTrue(mapping.proposedDstPath.contains("Enabled/"))
        XCTAssertFalse(mapping.proposedDstPath.contains("Disabled/"))
    }

    @MainActor
    func testProposeMappingNeverUsesAvoidTemplateAndVetoesAvoidedFolder() async {
        let analyzer = LearningsAnalyzer()
        let avoidDocuments = InferredRule(
            pattern: ".*\\.pdf$",
            template: "AVOID:Documents/{filename}",
            priority: -40,
            explanation: "avoid Documents for PDFs"
        )
        let documentsRule = InferredRule(
            pattern: ".*\\.pdf$",
            template: "Documents/{filename}",
            priority: 90,
            explanation: "PDFs to Documents"
        )
        let reportsRule = InferredRule(
            pattern: ".*\\.pdf$",
            template: "Reports/{filename}",
            priority: 50,
            explanation: "PDFs to Reports"
        )

        let mapping = await analyzer.proposeMapping(
            for: URL(fileURLWithPath: "/tmp/root/invoice.pdf"),
            using: [avoidDocuments, documentsRule, reportsRule],
            rootPath: "/tmp/root"
        )

        XCTAssertFalse(mapping.proposedDstPath.contains("AVOID:"))
        XCTAssertFalse(mapping.proposedDstPath.contains("Documents/"))
        XCTAssertEqual(mapping.ruleId, reportsRule.id)
        XCTAssertTrue(mapping.proposedDstPath.contains("Reports/"))
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
