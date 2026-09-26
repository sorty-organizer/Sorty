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
    
    /// Creates an array of mock FileItems
    public static func makeFileItems(count: Int = 5) -> [FileItem] {
        let extensions = ["pdf", "jpg", "png", "txt", "md", "swift", "json"]
        let names = ["document", "image", "report", "data", "backup", "config", "notes"]
        
        return (0..<count).map { index in
            let ext = extensions[index % extensions.count]
            let name = "\(names[index % names.count])_\(index + 1)"
            let size = Int64.random(in: 1024...(10 * 1024 * 1024))
            
            return FileItem(
                id: UUID(),
                path: "/test/\(name).\(ext)",
                name: name,
                extension: ext,
                size: size,
                isDirectory: false,
                creationDate: Date().addingTimeInterval(-Double.random(in: 0...(7 * 24 * 3600))),
                modificationDate: Date()
            )
        }
    }
    
    /// Creates a mock AIConfig
    public static func makeAIConfig(
        provider: AIProvider = .openAI,
        model: String = "gpt-4o"
    ) -> AIConfig {
        var config = AIConfig.default
        config.provider = provider
        config.model = model
        return config
    }
    
    /// Creates a mock AI response
    public static func makeAIResponse() -> String {
        """
        {
          "folders": [
            {
              "name": "Documents",
              "reasoning": "General document files",
              "files": ["doc1.pdf", "report.docx"],
              "subfolders": []
            }
          ],
          "unorganized": [],
          "notes": "Files organized by type and purpose"
        }
        """
    }
    
    /// Creates mock folder suggestions
    public static func makeFolderSuggestions(count: Int = 3) -> [FolderSuggestion] {
        let folderNames = ["Documents", "Images", "Code", "Archives", "Media"]
        let reasonings = [
            "General document files organized by type",
            "Photos and graphics files",
            "Development files and projects",
            "Compressed and archived files",
            "Audio and video content"
        ]
        
        return (0..<count).map { index in
            FolderSuggestion(
                id: UUID(),
                folderName: folderNames[index % folderNames.count],
                description: reasonings[index % reasonings.count],
                files: makeFileItems(count: 3),
                subfolders: index < 2 ? makeFolderSuggestions(count: 1) : [],
                reasoning: "AI generated organization"
            )
        }
    }
    
    /// Creates mock storage locations
    public static func makeStorageLocations() -> [StorageLocation] {
        [
            StorageLocation(
                id: UUID(),
                path: "/Users/user/Documents",
                isEnabled: true
            ),
            StorageLocation(
                id: UUID(),
                path: "/Volumes/External/Archives",
                isEnabled: false
            ),
            StorageLocation(
                id: UUID(),
                path: "/Users/user/Projects",
                isEnabled: true
            )
        ]
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
    
    /// Creates mock watched folders
    public static func makeWatchedFolders() -> [WatchedFolder] {
        [
            WatchedFolder(
                id: UUID(),
                path: "/Users/user/Downloads",
                isEnabled: true,
                autoOrganize: true
            ),
            WatchedFolder(
                id: UUID(),
                path: "/Users/user/Desktop",
                isEnabled: false,
                autoOrganize: false
            )
        ]
    }
    
    /// Creates mock organization history entries
    public static func makeOrganizationHistory() -> [OrganizationHistoryEntry] {
        [
            OrganizationHistoryEntry(
                id: UUID(),
                timestamp: Date().addingTimeInterval(-24 * 3600),
                directoryPath: "/Users/user/Downloads",
                filesOrganized: 45,
                foldersCreated: 8,
                plan: nil,
                status: .completed
            ),
            OrganizationHistoryEntry(
                id: UUID(),
                timestamp: Date().addingTimeInterval(-7 * 24 * 3600),
                directoryPath: "/Users/user/Documents",
                filesOrganized: 128,
                foldersCreated: 15,
                plan: nil,
                status: .completed
            )
        ]
    }
}

// MARK: - Preview Helpers
public extension PreviewMocks {
    
    /// Wraps a view with necessary environment objects for previews
    @MainActor
    static func previewContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .environmentObject(AppState.preview)
            .environmentObject(SettingsViewModel.preview)
            .environmentObject(FolderOrganizer.preview)
            .environmentObject(ExclusionRulesManager.preview)
            .environmentObject(ExtensionListener.preview)
            .environmentObject(PersonaManager.preview)
            .environmentObject(LearningsManager.preview)
            .environmentObject(CustomPersonaStore.preview)
            .environmentObject(StorageLocationsManager.preview)
    }
}

// MARK: - Environment Object Extensions for Previews

extension AppState {
    @MainActor
    static var preview: AppState {
        let state = AppState()
        state.hasCompletedOnboarding = true
        state.selectedDirectory = URL(fileURLWithPath: "/Users/user/Downloads")
        return state
    }
}

extension SettingsViewModel {
    @MainActor
    static var preview: SettingsViewModel {
        let vm = SettingsViewModel()
        return vm
    }
}

extension FolderOrganizer {
    @MainActor
    static var preview: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.currentPlan = PreviewMocks.makeOrganizationPlan()
        return organizer
    }
}

extension ExclusionRulesManager {
    @MainActor
    static var preview: ExclusionRulesManager {
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
    static var preview: ExtensionListener {
        ExtensionListener()
    }
}

extension PersonaManager {
    @MainActor
    static var preview: PersonaManager {
        PersonaManager()
    }
}

extension LearningsManager {
    @MainActor
    static var preview: LearningsManager {
        LearningsManager()
    }
}

extension CustomPersonaStore {
    @MainActor
    static var preview: CustomPersonaStore {
        CustomPersonaStore()
    }
}

extension StorageLocationsManager {
    @MainActor
    static var preview: StorageLocationsManager {
        StorageLocationsManager()
    }
}

#endif
