import Foundation

/// Asks the AI for a fresh name for one file. Used by the regenerate button on
/// both organized and unorganized preview rows.
enum RenameRegenerator {
    /// Returns a normalized name that differs from `currentSuggestion`.
    static func regenerate(
        file: FileItem,
        currentSuggestion: String?,
        config: AIConfig,
        client injectedClient: (any AIClientProtocol)? = nil
    ) async throws -> String {
        let client = try injectedClient ?? AIClientFactory.createClient(config: config)
        let plan = try await client.analyze(
            files: [file],
            customInstructions: prompt(for: file, currentSuggestion: currentSuggestion),
            personaPrompt: nil,
            temperature: 0.8
        )
        let suggestedName = plan.suggestions
            .lazy
            .flatMap(\.allFileRenameMappings)
            .first { $0.originalFile.id == file.id || $0.originalFile.displayName == file.displayName }?
            .suggestedName
        guard let suggestedName, !suggestedName.isEmpty else {
            throw AIClientError.invalidResponseFormat
        }
        let normalized = FilenameNormalizer.normalize(
            suggestedName,
            originalFilename: file.displayName,
            options: config.renameNamingOptions
        ) ?? suggestedName
        return distinctName(normalized, previousSuggestion: currentSuggestion ?? "")
    }

    /// Fallback when the AI call fails: a visibly different variant of the current name.
    static func distinctName(_ candidate: String, previousSuggestion: String) -> String {
        guard candidate.caseInsensitiveCompare(previousSuggestion) == .orderedSame else {
            return candidate
        }

        let nsName = candidate as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let revised = "\(base) Revised"
        return ext.isEmpty ? revised : "\(revised).\(ext)"
    }

    private static func prompt(for file: FileItem, currentSuggestion: String?) -> String {
        let metadata = file.contentMetadata
        let title = metadata?.documentTitle ?? ""
        let keywords = metadata?.detectedKeywords?.prefix(8).joined(separator: ", ") ?? ""
        let contentPreview = String(
            metadata?.allTextContent?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(900) ?? ""
        )

        return """
        Rename only this one file. Keep it in the current folder.

        Original filename: \(file.displayName)
        Current suggested filename: \(currentSuggestion ?? "None")
        File extension to preserve: \(file.extension)
        Document title: \(title)
        Keywords: \(keywords)
        Content preview:
        \(contentPreview)

        Requirements:
        - Return Sorty's normal JSON organization response.
        - Use a single folder named ".".
        - Preserve the original file extension.
        - Make the name specific, useful, and concise.
        - Spaces are valid if they improve readability.
        - Do not return the current suggested filename. Generate a meaningfully different name.
        - Include suggested_name, rename_reason, and rename_confidence for this file.
        """
    }
}
