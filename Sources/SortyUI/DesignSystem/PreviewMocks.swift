#if DEBUG
//
//  PreviewMocks.swift
//  Sorty
//
//  Mock data helpers for SwiftUI previews
//

import Foundation
import SwiftUI

// MARK: - Mock Organization Plan
public enum PreviewMocks {
    
    /// Creates a mock OrganizationPlan for previews
    public static func makeOrganizationPlan() -> OrganizationPlan {
        var plan = OrganizationPlan(
            id: UUID(),
            suggestions: [
                FolderSuggestion(
                    id: UUID(),
                    folderName: "Documents",
                    description: "General document files organized by type",
                    files: [
                        FileItem(
                            id: UUID(),
                            path: "/test/document1.pdf",
                            name: "document1",
                            extension: "pdf",
                            size: 1024 * 1024,
                            isDirectory: false
                        ),
                        FileItem(
                            id: UUID(),
                            path: "/test/report.docx",
                            name: "report",
                            extension: "docx",
                            size: 512 * 1024,
                            isDirectory: false
                        )
                    ],
                    subfolders: [
                        FolderSuggestion(
                            id: UUID(),
                            folderName: "Invoices",
                            description: "Financial documents requiring organization",
                            files: [
                                FileItem(
                                    id: UUID(),
                                    path: "/test/invoice_jan.pdf",
                                    name: "invoice_jan",
                                    extension: "pdf",
                                    size: 256 * 1024,
                                    isDirectory: false
                                )
                            ],
                            subfolders: [],
                            reasoning: "Organizing by date"
                        )
                    ],
                    reasoning: "Organizing by file type"
                ),
                FolderSuggestion(
                    id: UUID(),
                    folderName: "Images",
                    description: "Photos and graphics files",
                    files: [
                        FileItem(
                            id: UUID(),
                            path: "/test/photo1.jpg",
                            name: "photo1",
                            extension: "jpg",
                            size: 3 * 1024 * 1024,
                            isDirectory: false
                        ),
                        FileItem(
                            id: UUID(),
                            path: "/test/screenshot.png",
                            name: "screenshot",
                            extension: "png",
                            size: 1 * 1024 * 1024,
                            isDirectory: false
                        )
                    ],
                    subfolders: [],
                    reasoning: "Image files grouped together"
                )
            ],
            unorganizedFiles: [
                FileItem(
                    id: UUID(),
                    path: "/test/random.tmp",
                    name: "random",
                    extension: "tmp",
                    size: 100,
                    isDirectory: false
                )
            ],
            unorganizedDetails: [
                UnorganizedFile(
                    filename: "random.tmp",
                    reason: "Temporary file - unclear purpose"
                )
            ],
            notes: "Organization generated for preview purposes",
            timestamp: Date(),
            version: 1,
            generationStats: makeGenerationStats()
        )

        let documentFiles = plan.suggestions[0].files
        plan.suggestions[0].fileRenameMappings = [
            FileRenameMapping(
                originalFile: documentFiles[0],
                suggestedName: "2026-05 Product Brief.pdf",
                renameReason: "PDF title says \"Product Brief\" and the metadata date is May 2026.",
                renameConfidence: 0.92
            ),
            FileRenameMapping(
                originalFile: documentFiles[1],
                suggestedName: "Q2 Status Report.docx",
                renameReason: "Document title says \"Status Report\"; the quarter appears only once in body text.",
                renameConfidence: 0.58
            )
        ]

        let imageFile = plan.suggestions[1].files[0]
        plan.suggestions[1].fileRenameMappings = [
            FileRenameMapping(
                originalFile: imageFile,
                suggestedName: "Client Launch Photo.jpg",
                renameReason: "OCR may contain a client label, but the text is incomplete.",
                renameConfidence: 0.22
            )
        ]
        return plan
    }
    
    /// Creates mock generation stats
    public static func makeGenerationStats() -> GenerationStats {
        GenerationStats(
            duration: 2.5,
            tps: 45.2,
            ttft: 0.8,
            totalTokens: 1250,
            model: "gpt-4o",
            filesScanned: 24,
            totalFileSize: 15 * 1024 * 1024,
            duplicatesFound: 2,
            promptTokens: 450,
            retryCount: 0,
            provider: "OpenAI",
            scanDuration: 0.5,
            estimatedCost: Decimal(string: "0.025")
        )
    }
    
    /// Creates mock exclusion rules
    public static func makeExclusionRules() -> [ExclusionRule] {
        [
            ExclusionRule(
                id: UUID(),
                type: .fileExtension,
                pattern: "tmp",
                isEnabled: true,
                description: "Temporary files",
                isBuiltIn: true
            ),
            ExclusionRule(
                id: UUID(),
                type: .folderName,
                pattern: ".git",
                isEnabled: true,
                description: "Git repositories",
                isBuiltIn: true
            ),
            ExclusionRule(
                id: UUID(),
                type: .folderName,
                pattern: "node_modules",
                isEnabled: true,
                description: "Node modules",
                isBuiltIn: true
            )
        ]
    }
    
}

// MARK: - Environment Object Extensions for Previews

extension AppState {
    @MainActor
    package static var preview: AppState {
        let state = AppState()
        state.hasCompletedOnboarding = true
        state.selectedDirectory = URL(fileURLWithPath: "/Users/user/Downloads")
        return state
    }
}

extension SettingsViewModel {
    @MainActor
    package static var preview: SettingsViewModel {
        let vm = SettingsViewModel()
        return vm
    }
}

extension FolderOrganizer {
    @MainActor
    package static var preview: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.currentPlan = PreviewMocks.makeOrganizationPlan()
        return organizer
    }
}

extension ExclusionRulesManager {
    @MainActor
    package static var preview: ExclusionRulesManager {
        let manager = ExclusionRulesManager()
        // Add mock rules via the public API
        for rule in PreviewMocks.makeExclusionRules() {
            manager.addRule(rule)
        }
        return manager
    }
}

extension ExtensionListener {
    @MainActor
    package static var preview: ExtensionListener {
        ExtensionListener()
    }
}

extension PersonaManager {
    @MainActor
    package static var preview: PersonaManager {
        PersonaManager()
    }
}

extension LearningsManager {
    @MainActor
    package static var preview: LearningsManager {
        LearningsManager()
    }
}

extension CustomPersonaStore {
    @MainActor
    package static var preview: CustomPersonaStore {
        CustomPersonaStore()
    }
}

#endif
