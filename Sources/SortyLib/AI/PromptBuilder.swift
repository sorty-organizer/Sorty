//
//  PromptBuilder.swift
//  Sorty
//
//  Constructs optimized prompts for AI organization
//

import Foundation

struct PromptBuilder {
    static func buildSystemPrompt(enableReasoning: Bool = false, personaInfo: String, mode: OrganizationMode = .organize, enableTagging: Bool = true) -> String {
        var prompt = SystemPrompt.buildPrompt(mode: mode, enableTagging: enableTagging)
        
        if !personaInfo.isEmpty {
            prompt += """
            
            
            # ═══════════════════════════════════════════════════════
            # ACTIVE PERSONA — PERSISTENT ORGANIZATION INSTRUCTIONS
            # ═══════════════════════════════════════════════════════
            #
            # The following persona rules OVERRIDE default heuristics,
            # learnings, examples, and existing-structure preferences.
            # Direct instructions for the current task remain higher
            # priority when they are more specific or conflict.
            # ═══════════════════════════════════════════════════════
            
            \(personaInfo)
            
            # ═══════════════════════════════════════════════════════
            # END PERSONA — Resume base rules for anything not
            # explicitly covered by the persona above.
            # ═══════════════════════════════════════════════════════
            """
        }
        
        if enableReasoning {
            prompt += """
            
            ## IMPORTANT: Detailed Reasoning Mode Enabled
            
            For EACH folder in your response, you MUST include a comprehensive "reasoning" field that provides:
            
            1. **Pattern Recognition**: What naming patterns, file types, or metadata led you to group these files together? Be specific about the patterns you observed.
            
            2. **Semantic Grouping**: Explain the logical relationship between the files in this folder. What do they have in common beyond just file type?
            
            3. **Alternative Consideration**: Briefly mention 1-2 alternative folder structures you considered and why you rejected them in favor of this organization.
            
            4. **User Benefit**: How does this organization improve the user's workflow or findability?
            
            The reasoning should be 3-5 sentences minimum per folder. Shallow, one-sentence explanations are NOT acceptable.
            
            Keep this explanation inside each folder's JSON "reasoning" value. Do not emit reasoning before or after the JSON object.
            """
        }
        
        return prompt
    }
    
    static func buildOrganizationPrompt(
        files: [FileItem],
        mode: OrganizationMode = .organize,
        namingStyle: NamingStyle = .descriptive,
        renameNamingOptions: RenameNamingOptions = .default,
        customNamingInstructions: String? = nil,
        renameRules: [RenameRule] = [],
        renameRuleMode: RenameRuleApplicationMode = .beforeAI,
        enableReasoning: Bool = false,
        enableSmartRename: Bool = false,
        includeContentMetadata: Bool = false,
        customInstructions: String? = nil,
        storageLocationsContext: String? = nil,
        existingFoldersContext: String? = nil,
        analyzedImageFilenames: [String] = []
    ) -> String {
        var prompt: String
        
        if mode == .renameOnly {
            prompt = "Suggest intelligent and descriptive filenames for the following files. DO NOT suggest any folder structure; ALL files must be returned in a single root folder named '.'. Focus purely on making filenames more informative based on their content and metadata. This mode is strictly for renaming files in their current location.\n\n"
        } else if mode == .organizeAndRename {
            prompt = "Organize the following files into a logical folder structure. You should suggest both descriptive folders and improved filenames within those folders:\n\n"
        } else {
            prompt = "Organize the following files into a logical folder structure. Suggest descriptive folders but KEEP the original filenames unchanged:\n\n"
        }

        if mode != .renameOnly {
            prompt += """
            ## LIVE ORGANIZATION PREVIEW
            Sorty shows file moves as your JSON streams in. To keep that preview accurate and immediate:
            - Emit folder objects with "name", then "files" immediately, so file moves start as soon as the destination is decided.
            - Put descriptions, reasoning, tags, comments, and "subfolders" after "files" so metadata cannot delay direct moves.
            - Do not add artificial delays or non-JSON file-move narration; the app animates the real streamed JSON tokens.

            """

            prompt += """
            ## ORGANIZATION COMPLETENESS
            Actively assign files to practical destination folders whenever a move would materially improve findability. Do not default to a no-op merely because the current layout is passable, filenames are ambiguous, or several structures could work.
            Organizing into folders is the default. Before using `unorganized`, try a suitable existing folder, a meaningful shared folder based on the file evidence, a broad reusable category, then a justified standalone project or category folder.
            Use `unorganized` only when all four options fail. Uncertainty alone is not a reason to leave a file unorganized, and a single file may have its own folder when it clearly represents a standalone project or reusable category.
            Never create a folder named "Unorganized", "Unorganized Files", or an equivalent fallback name. Genuinely unplaceable files belong only in the `unorganized` field and must remain in place.
            Return a no-op plan only when the files are already sensibly organized, no move would materially improve the structure, or moving them would violate user instructions, exclusions, or filesystem safety. Never use a no-op to avoid making a reasonable organization decision.

            """
        }
        
        if let instructions = customInstructions, !instructions.isEmpty {
            if instructions.contains("<user_instructions>") {
                prompt += """

                # TASK INSTRUCTIONS AND SUPPORTING CONTEXT

                The block below combines direct instructions with labeled context assembled by Sorty.
                - Content inside `<user_instructions>` comes directly from the user and has highest priority for organization choices.
                - Persona instructions apply next.
                - Learnings, reference/example folders, existing structure, manifests, and other labeled context support the decision but MUST NOT override direct user or persona instructions.
                - Filesystem safety, exclusions, approved storage destinations, and the JSON contract remain mandatory.

                \(instructions)


                """
            } else {
                prompt += """
                ╔══════════════════════════════════════════════════════════╗
                ║  MANDATORY USER REQUIREMENTS — MUST FOLLOW EXACTLY      ║
                ╠══════════════════════════════════════════════════════════╣
                ║  The following instructions come directly from the user. ║
                ║  They override ALL default rules. If the user says       ║
                ║  "do X", you MUST do X. If the user says "don't do Y",  ║
                ║  you MUST NOT do Y. No exceptions, no creative           ║
                ║  reinterpretation. Follow them LITERALLY.                ║
                ╚══════════════════════════════════════════════════════════╝

                USER INSTRUCTIONS: \(instructions)

                ════════════════════════════════════════════════════════════


                """
            }
        }

        prompt += finderTagSelectionGuidance(mode: mode)

        if mode == .organize {
            prompt += """
            ## ORGANIZE-ONLY WORKFLOW BOUNDARY
            This run is organize-only. Keep every original filename unchanged even if user instructions,
            persona guidance, learned preferences, naming rules, or provider defaults mention renaming.
            Do not include `suggested_name`, `rename_reason`, or `rename_confidence` fields.

            """
        }
        
        // Add organization-only routing context if provided.
        if mode != .renameOnly, let storageContext = storageLocationsContext, !storageContext.isEmpty {
            prompt += "\(storageContext)\n\n"
        }
        
        // Add existing folders context - encourage reuse of existing structure in organization modes.
        if mode != .renameOnly, let existingContext = existingFoldersContext, !existingContext.isEmpty {
            prompt += "\(existingContext)\n\n"
        }
        
        // Rename instructions: ONLY include if in a renaming mode. 
        // If mode is .organize, we explicitly IGNORE enableSmartRename to ensure filenames remain unchanged.
        if mode == .renameOnly || mode == .organizeAndRename {
            prompt += """
            ## INTELLIGENT RENAMING
            Suggest meaningful, descriptive filenames that help users understand file contents at a glance.
            - \(namingStyle.promptInstructions)
            - \(renameNamingOptions.promptInstructions)
            - Spaces are valid macOS filename characters. Use spaces when the separator preference asks for them; do not force underscores or hyphens unless configured.
            - When renaming multiple files in the same folder, keep one consistent naming pattern.
            - Return a `rename_confidence` score between 0.0 and 1.0 for each rename.
            - Prefer renaming files in this workflow. Keep the original name only when it is already clear and specific, protected/stable, or user instructions exclude a file/pattern from renaming.
            - When keeping a file unchanged, omit `suggested_name` and include a short `rename_reason` explaining why it stayed the same.
            - Include `suggested_name` whenever evidence supports a clearer name; for generic camera, screenshot, scan, download, or default app names, assume a rename is needed unless evidence is missing.
            - `rename_reason` must be concrete and evidence-based (cite content cues, date, project, or ambiguity being resolved). Avoid vague reasons like "more descriptive".
            - Do not invent dates, clients, invoice numbers, people, or projects. If evidence is weak, keep the original name and use low confidence.
            """

            if let customNaming = customNamingInstructions, !customNaming.isEmpty {
                let expanded = expandedCustomNamingInstructions(
                    customNaming,
                    files: files,
                    maxExamples: 5
                )
                prompt += "\n- CUSTOM NAMING PREFERENCE: \(expanded)"
            }

            if !renameRules.isEmpty {
                prompt += "\n- CUSTOM RENAME RULES (\(renameRuleMode.displayName)):"
                for rule in renameRules.prefix(10) {
                    let modeLabel = rule.isRegex ? "regex" : "text"
                    prompt += "\n  • [\(modeLabel)] \(rule.pattern) -> \(rule.replacement)"
                }
                if renameRuleMode == .rulesOnly {
                    prompt += "\n  • RULE MODE: Use only these custom rules for renaming and avoid AI creativity."
                } else {
                    prompt += "\n  • RULE MODE: Apply these rules first, then refine with AI when useful."
                }
            }
            
            prompt += """
            
            - Remove redundant prefixes like "IMG_", "DSC_", "Screenshot ", "Document (1)".
            - Keep filenames concise (max 60 chars) but highly informative.
            - Ensure names are valid for macOS filesystem and keep extensions unchanged.
            - Do NOT rename dotfiles/config files (e.g., .gitignore, .env, Makefile).
            - Do NOT rename files that already follow clear semantic version patterns (e.g., v1.2.3).
            
            """
        }

        if !analyzedImageFilenames.isEmpty {
            let orderedNames = analyzedImageFilenames
                .enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")

            prompt += """
            ## AI VISION ATTACHMENTS
            I've attached \(analyzedImageFilenames.count) images from this folder.
            For each attached image, briefly describe what you see and use that visual context to improve folder categorization.
            The following images are attached in order:
            \(orderedNames)

            """
        }
        
        prompt += "Files to process (\(files.count) total):\n\n"
        
        // Group files by extension for better context
        let groupedByExtension = Dictionary(grouping: files) { $0.extension.lowercased() }
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        
        for (ext, fileList) in groupedByExtension.sorted(by: { $0.key < $1.key }) {
            let extLabel = ext.isEmpty ? "no extension" : ".\(ext)"
            prompt += "\(extLabel.uppercased()) files (\(fileList.count)):\n"
            
            // Prioritize files with content metadata (deep-scanned) before applying the cap
            let sortedFiles: [FileItem]
            if includeContentMetadata {
                sortedFiles = fileList.sorted { a, b in
                    let aHasMetadata = a.contentMetadata != nil && !a.contentMetadata!.isEmpty
                    let bHasMetadata = b.contentMetadata != nil && !b.contentMetadata!.isEmpty
                    if aHasMetadata != bHasMetadata { return aHasMetadata }
                    return false
                }
            } else {
                sortedFiles = fileList
            }
            
            for file in sortedFiles {
                let promptPath = file.relativePath ?? file.displayName
                var fileDesc = "  - \(promptPath)"
                
                fileDesc += " [\(file.isDirectory ? "directory" : "file"), \(file.size) bytes / \(file.formattedSize)]"

                if let created = file.creationDate {
                    fileDesc += ", created: \(dateFormatter.string(from: created))"
                }
                if let modified = file.modificationDate {
                    fileDesc += ", modified: \(dateFormatter.string(from: modified))"
                }
                if let accessed = file.lastAccessDate {
                    fileDesc += ", accessed: \(dateFormatter.string(from: accessed))"
                }
                if let resolution = file.resolutionString {
                    fileDesc += ", dimensions: \(resolution)"
                }
                if let cloudStatus = file.cloudStatus {
                    fileDesc += ", cloud status: \(cloudStatus.rawValue)"
                }
                if let hash = file.sha256Hash, !hash.isEmpty {
                    fileDesc += ", SHA-256: \(hash)"
                }

                if let tags = file.finderTags, !tags.isEmpty {
                    fileDesc += "\n    [finder_tags] \(tags.joined(separator: ", "))"
                }

                if let color = file.finderTagColorName {
                    fileDesc += "\n    [finder_color] \(color)"
                }

                if let comment = file.finderComment, !comment.isEmpty {
                    fileDesc += "\n    [Finder Comment] \(truncateForPrompt(comment, maxLength: 200))"
                }
                
                // Include content metadata if available and requested
                if includeContentMetadata, let metadata = file.contentMetadata, !metadata.isEmpty {
                    let summary = contentMetadataDescription(metadata)
                    if !summary.isEmpty {
                        let label = mode == .renameOnly || mode == .organizeAndRename
                            ? "Rename Context"
                            : "Content Analysis"
                        fileDesc += "\n    [\(label)] \(summary)"
                    }
                }
                
                prompt += "\(fileDesc)\n"
            }
        }

        if includeContentMetadata {
            prompt += "\n## IMAGE & CONTENT ANALYSIS\n"
            prompt += "For files with content metadata, use the extracted text, descriptions, and visual content to make better organization decisions:\n"
            prompt += "- Image content: Use visible subjects, scenes, and text to determine appropriate folders and tags\n"
            prompt += "- Document text: Group related documents by their actual content, not just filenames\n"
            prompt += "- OCR results: Use text found in images/screenshots for more accurate categorization\n\n"
        }
        
        prompt += "## FILE METADATA\n"
        prompt += "Files include metadata when available — use it for smarter organization:\n"
        prompt += "- Treat filenames as helpful but imperfect labels; do not overfit to names like IMG_, Screenshot, scan, final, or untitled\n"
        prompt += "- Parent/ancestor folders: Use relative paths as context for project, client, event, course, or workflow, without blindly preserving the old layout\n"
        prompt += "- Content metadata: Prefer extracted titles, text, OCR, EXIF/media info, Finder comments, and tags over ambiguous filenames when making decisions\n"
        prompt += "- Dates (created/modified/accessed): Group by time period or project phase when relevant\n"
        prompt += "- Finder Tags: Match named tags against [finder_tags] and visible color instructions against [finder_color]\n"
        prompt += "- Finder Comments: User annotations that provide context about the file's purpose or content\n\n"

        if mode == .renameOnly {
            prompt += "\nReturn the suggestions in JSON format. Use a single folder named '.' to represent the current location for all files."
        } else if enableReasoning {
            prompt += "\nProvide detailed reasoning for each folder. Include the organization structure in JSON format."
        } else {
            prompt += "\nProvide the organization structure in JSON format."
        }
        
        return prompt
    }
    
    
    /// Estimate token count (rough: 1 token ≈ 4 chars for English)
    static func estimateTokens(_ text: String) -> Int {
        return text.count / 4
    }

    static func wrapDirectUserInstructions(_ instructions: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        return """
        <user_instructions>
        \(trimmed)
        </user_instructions>
        """
    }

    private static func finderTagSelectionGuidance(mode: OrganizationMode) -> String {
        let nonmatchingRule = mode == .renameOnly
            ? "Keep every nonmatching filename unchanged, include it under '.', and omit its rename suggestion."
            : "Leave nonmatching files in their current locations by returning them as unorganized rather than moving them."

        return """

        ## FINDER TAG SELECTION
        Finder metadata describes the existing input; it is not a request to apply new tags.
        - Match color phrases such as "red-tagged" against `finder_color`, not the tag name.
        - Match a custom Finder tag name against `finder_tags`.
        - A tagged folder makes its listed descendants match instructions that select that folder by tag.
        - When the user says "only", restrict the requested move or rename to matching items. \(nonmatchingRule)
        - Missing `finder_color` means the item has no visible Finder label color.

        """
    }

    /// Select compaction level based on full prompt budget.
    enum CompactionLevel {
        case standard
        case ultra
        case summary
        case micro
    }

    static func selectCompactionLevel(
        files: [FileItem],
        config: AIConfig,
        customInstructions: String? = nil,
        personaPrompt: String? = nil,
        maxTokens: Int = 1200,
        safetyMargin: Double = 0.65
    ) -> CompactionLevel {
        let effectiveBudget = max(200, Int(Double(maxTokens) * safetyMargin))

        let levels: [CompactionLevel] = [.standard, .ultra, .summary, .micro]
        for level in levels {
            let prompts = promptPair(for: level, config: config, files: files)
            let fullPrompt = mergePromptBudgetStrings(
                system: prompts.system,
                user: prompts.user,
                customInstructions: preservedContext(
                    customInstructions: customInstructions,
                    personaPrompt: personaPrompt
                )
            )
            if estimateTokens(fullPrompt) <= effectiveBudget {
                return level
            }
        }

        return .micro
    }

    static func preservedContext(customInstructions: String?, personaPrompt: String?) -> String {
        var sections: [String] = []
        if let personaPrompt, !personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("<active_persona>\n\(personaPrompt)\n</active_persona>")
        }
        if let customInstructions, !customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(customInstructions)
        }
        return sections.joined(separator: "\n\n")
    }

    private static func mergePromptBudgetStrings(system: String, user: String, customInstructions: String?) -> String {
        var merged = system + "\n" + user
        if let customInstructions, !customInstructions.isEmpty {
            merged += "\nUSER INSTRUCTIONS:\n" + customInstructions
        }
        return merged
    }

    private static func compactFileLine(
        id: Int,
        file: FileItem,
        maxNameLength: Int,
        maxPathLength: Int,
        maxTitleLength: Int,
        maxHintLength: Int
    ) -> String {
        let ext = file.extension.isEmpty ? "-" : file.extension.lowercased()
        let filename = file.displayName.isEmpty ? file.name : file.displayName
        let relativePath = file.relativePath ?? filename
        let clippedName = truncateForPrompt(filename, maxLength: maxNameLength)
        let clippedPath = truncateForPrompt(relativePath, maxLength: maxPathLength)
        var line = "\(id)|name:\(clippedName)|path:\(clippedPath)|ext:\(ext)"
        
        // Append Finder metadata compactly when present
        var extras = ["bytes:\(file.size)"]
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        if let created = file.creationDate {
            extras.append("created:\(dateFormatter.string(from: created))")
        }
        if let modified = file.modificationDate {
            extras.append("modified:\(dateFormatter.string(from: modified))")
        }
        if let accessed = file.lastAccessDate {
            extras.append("accessed:\(dateFormatter.string(from: accessed))")
        }
        if let resolution = file.resolutionString {
            extras.append("dimensions:\(resolution)")
        }
        if let cloudStatus = file.cloudStatus {
            extras.append("cloud:\(cloudStatus.rawValue)")
        }
        if let tags = file.finderTags, !tags.isEmpty {
            extras.append("finder_tags:\(tags.joined(separator: ","))")
        }
        if let color = file.finderTagColorName {
            extras.append("finder_color:\(color)")
        }
        if let comment = file.finderComment, !comment.isEmpty {
            extras.append("comment:\(String(comment.prefix(40)))")
        }
        if let title = file.contentMetadata?.documentTitle, !title.isEmpty {
            extras.append("title:\(truncateForPrompt(title, maxLength: maxTitleLength))")
        }
        if let hint = compactEvidenceHint(for: file), !hint.isEmpty {
            extras.append("hint:\(truncateForPrompt(hint, maxLength: maxHintLength))")
        }
        if !extras.isEmpty {
            line += "|\(extras.joined(separator: "|"))"
        }
        return line
    }

    private static func compactFileIdTable(
        files: [FileItem],
        maxNameLength: Int,
        maxPathLength: Int,
        maxTitleLength: Int,
        maxHintLength: Int
    ) -> String {
        var lines: [String] = []
        lines.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            lines.append(compactFileLine(
                id: index + 1,
                file: file,
                maxNameLength: maxNameLength,
                maxPathLength: maxPathLength,
                maxTitleLength: maxTitleLength,
                maxHintLength: maxHintLength
            ))
        }
        return lines.joined(separator: "\n")
    }

    private static func compactEvidenceHint(for file: FileItem) -> String? {
        let candidates = [
            file.contentMetadata?.textPreview,
            file.contentMetadata?.ocrText,
            file.ocrText
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func compactNamingPolicy(config: AIConfig) -> String {
        guard config.mode == .renameOnly || config.mode == .organizeAndRename else { return "" }
        var lines = [
            "NAMING POLICY (preserve through prompt compaction):",
            "- Style: \(config.namingStyle.promptInstructions)",
            config.renameNamingOptions.promptInstructions
        ]
        if let custom = config.customNamingInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            lines.append("- Custom naming instructions: \(custom)")
        }
        if !config.renameRules.isEmpty {
            lines.append("- Rule mode: \(config.renameRuleMode.displayName)")
            lines.append(contentsOf: config.renameRules.map {
                "- Rename rule (\($0.isRegex ? "regex" : "literal")): \($0.pattern) -> \($0.replacement)"
            })
        }
        return lines.joined(separator: "\n")
    }

    private static func compactFileSummary(files: [FileItem], maxExtensions: Int = 12) -> String {
        let grouped = Dictionary(grouping: files) { $0.extension.lowercased() }
        let summary = grouped
            .sorted { $0.value.count > $1.value.count }
            .prefix(maxExtensions)
            .map { ext, entries in
                "\(ext.isEmpty ? "misc" : ext):\(entries.count)"
            }
            .joined(separator: ", ")
        return "Types: \(summary)"
    }

    private static func compactResponseContract(mode: OrganizationMode, enableReasoning: Bool) -> String {
        let reasoning = ",\"reasoning\":\"Concrete shared cue for this grouping\""
        let filePayload: String
        let preferredPayload: String
        if mode == .renameOnly || mode == .organizeAndRename {
            filePayload = "\"files\":[{\"filename\":\"\",\"suggested_name\":\"\",\"rename_reason\":\"\",\"rename_confidence\":0.0}]"
            preferredPayload = "\"file_ids\":[1,2],\"rename_suggestions\":[{\"file_id\":1,\"suggested_name\":\"Clear Name.ext\",\"rename_reason\":\"Concrete evidence for the clearer name\",\"rename_confidence\":0.9}]"
        } else {
            filePayload = "\"files\":[\"filename\"]"
            preferredPayload = "\"file_ids\":[1,2]"
        }
        return """
        Return exactly one JSON object with no markdown, prose, progress lines, or reasoning outside JSON. Preferred compact format:
        {"session_name":"Specific 2-5 word title","folder_assignments":[{"name":"",\(preferredPayload)\(reasoning),"subfolders":[]}],"notes":"","learning_action":null}
        Legacy format is also accepted:
        {"session_name":"Specific 2-5 word title","folders":[{"name":"",\(filePayload)\(reasoning),"subfolders":[]}],"unorganized":[{"filename":"","reason":""}],"learning_action":null}
        Nest with "subfolders" (same folder shape, e.g. {"name":"","file_ids":[3],"reasoning":"..."}) when a folder holds 2+ distinct subgroups such as projects, years/months, or types; keep depth at 2 or less unless the user asks for more.
        \(mode == .renameOnly || mode == .organizeAndRename ? "In the preferred format, file_ids assign every file and rename_suggestions carries each evidence-backed rename by file_id. Do not omit rename_suggestions merely because you used file_ids." : "")
        \(mode == .renameOnly ? "" : "Actively create folder assignments when moving files would materially improve findability. Return no folder assignments only when the files are already sensibly organized, no move would help, or safety and user rules prohibit moving them; never use a no-op to avoid choosing a reasonable structure.")
        Existing finder_tags are tag names and finder_color is the visible Finder label color. Color instructions match finder_color. If the user says "only", change matching items only and leave nonmatches unchanged; descendants of a selected tagged folder match that folder.
        Before using unorganized, try a suitable existing folder, a meaningful shared folder, a broad reusable category, then a justified standalone project or category folder. Use unorganized only when all four fail; uncertainty alone is not enough. Never create an Unorganized or Unorganized Files folder; genuinely unplaceable files belong only in the unorganized field.
        `learning_action` is a rare tool call. Keep it null unless direct instructions or the active persona clearly ask Sorty not to learn from this specific run. Never call it because files look sensitive, unusual, temporary, uncertain, or different from learned preferences. Ordinary instructions such as "do not rename" do not request it. Ambiguity means null; prefer learning. The only call is {"name":"exclude_current_run_from_learning","reason":"brief explicit request","source":"direct_instructions"}; use source "persona" only for persona text.
        """
    }

    private static func minimalCompactSystemPrompt(
        mode: OrganizationMode = .organize,
        enableReasoning: Bool = false
    ) -> String {
        var base = "You organize files into practical folders."
        if mode == .renameOnly {
            base += " Keep all files in '.' and only suggest better names."
        }
        if mode == .renameOnly || mode == .organizeAndRename {
            base += " Actively suggest clearer filenames when the available evidence supports a material improvement; keep already-good or uncertain names unchanged. Return renames through rename_suggestions even when assigning files with file_ids."
        }
        if mode != .renameOnly {
            base += " Actively create folder assignments when moving files would materially improve findability. Return a no-op only when the files are already sensibly organized, no move would help, or safety and user rules prohibit moving them; never use a no-op to avoid choosing a reasonable structure."
        }
        base += " Choose folder count and depth from direct user instructions, the active persona, learnings, reference/example folders, the existing structure, and file relationships, in that priority order. Explicit user hierarchy preferences are binding; do not apply a preset folder-count limit. Use file_ids from the user list. Include every file exactly once. Before using unorganized, try a suitable existing folder, a meaningful shared folder, a broad reusable category, then a justified standalone project or category folder. Use unorganized only when all four fail; uncertainty alone is not enough. Never create an Unorganized or Unorganized Files folder; genuinely unplaceable files belong only in the unorganized field."
        base += " Existing finder_tags are tag names and finder_color is the visible Finder label color. Color instructions match finder_color. If the user says only, change matching items only and leave nonmatches unchanged; a tagged folder makes its listed descendants match."
        base += " For every folder, add one concise reasoning sentence naming the exact shared subject, project, source, date pattern, or compatible file roles. Never say only that files belong together."
        base += " learning_action is a rare tool call and defaults to null. Use exclude_current_run_from_learning only when direct instructions or the active persona clearly request no learning from this specific run. Never infer it from sensitive, unusual, temporary, uncertain, or conflicting files, or ordinary instructions such as do not rename. Ambiguity means null; prefer learning."
        base += " Return exactly one JSON object. Start with '{' immediately and output no markdown, prose, progress lines, or reasoning outside JSON."
        return base
    }

    static func buildUltraCompactPrompt(
        files: [FileItem],
        mode: OrganizationMode = .organize,
        enableReasoning: Bool = false
    ) -> (system: String, user: String) {
        let system = minimalCompactSystemPrompt(
            mode: mode,
            enableReasoning: enableReasoning
        )
        let table = compactFileIdTable(files: files, maxNameLength: 48, maxPathLength: 64, maxTitleLength: 48, maxHintLength: 96)
        let user = """
        \(compactFileSummary(files: files))
        Files (id|name|relative path|extension|size/date|title|content or OCR hint):
        \(table)

        \(compactResponseContract(mode: mode, enableReasoning: enableReasoning))
        """
        return (system, user)
    }

    static func buildSummaryPrompt(
        files: [FileItem],
        mode: OrganizationMode = .organize,
        enableReasoning: Bool = false
    ) -> (system: String, user: String) {
        let system = minimalCompactSystemPrompt(
            mode: mode,
            enableReasoning: enableReasoning
        )
        let table = compactFileIdTable(files: files, maxNameLength: 40, maxPathLength: 48, maxTitleLength: 40, maxHintLength: 72)
        let user = """
        \(compactFileSummary(files: files, maxExtensions: 8))
        Files (id|name|relative path|extension|size/date|title|content or OCR hint):
        \(table)

        \(compactResponseContract(mode: mode, enableReasoning: enableReasoning))
        """
        return (system, user)
    }

    static func buildMicroPrompt(
        files: [FileItem],
        mode: OrganizationMode = .organize,
        enableReasoning: Bool = false
    ) -> (system: String, user: String) {
        let system = minimalCompactSystemPrompt(
            mode: mode,
            enableReasoning: false
        )
        let table = compactFileIdTable(files: files, maxNameLength: 32, maxPathLength: 40, maxTitleLength: 32, maxHintLength: 56)
        let user = """
        \(compactFileSummary(files: files, maxExtensions: 6))
        Files (id|name|relative path|extension|size/date|title|content or OCR hint):
        \(table)

        \(compactResponseContract(mode: mode, enableReasoning: enableReasoning))
        """
        return (system, user)
    }
    
    /// Compact prompt for Apple Intelligence (reduced context window)
    static func buildCompactPrompt(files: [FileItem], mode: OrganizationMode = .organize, enableReasoning: Bool = false) -> String {
        var prompt: String
        if mode == .renameOnly {
            prompt = "Suggest better names for these files (keep in place):\n\n"
        } else {
            prompt = "Organize these files:\n\n"
        }
        prompt += "\(compactFileSummary(files: files, maxExtensions: 12))\n"
        prompt += "Use file IDs for mapping. Every file is listed once.\n"
        prompt += "Files (id|name|relative path|extension|size/date|title|content or OCR hint):\n"
        prompt += compactFileIdTable(files: files, maxNameLength: 64, maxPathLength: 96, maxTitleLength: 64, maxHintLength: 128)
        prompt += "\n\n"
        prompt += compactResponseContract(mode: mode, enableReasoning: enableReasoning)
        
        return prompt
    }
    
    /// Compact system prompt for Apple Intelligence
    static func buildCompactSystemPrompt(mode: OrganizationMode = .organize, enableReasoning: Bool = false, enableSmartRename: Bool = false, enableTagging: Bool = true) -> String {
        var prompt = "You are a file management assistant. "
        let compactFolderPayload: String
        
        if mode == .renameOnly {
            prompt += "Analyze files and suggest better filenames. Keep files in the '.' folder.\n\n"
        } else {
            prompt += "Analyze files and suggest folders.\n\n"
        }

        if mode == .renameOnly || mode == .organizeAndRename {
            compactFolderPayload = "\"name\":\"\",\"file_ids\":[1,2],\"rename_suggestions\":[{\"file_id\":1,\"suggested_name\":\"Clear Name.ext\",\"rename_reason\":\"Concrete evidence for the clearer name\",\"rename_confidence\":0.9}]"
        } else {
            compactFolderPayload = "\"name\":\"\",\"file_ids\":[1,2]"
        }
        
        prompt += """
        Rules:
        - Choose folder count and depth from direct user instructions, the active persona, learnings, reference/example folders, existing structure, and file relationships, in that priority order.
        - Treat explicit user folder-count and hierarchy preferences as binding. Do not apply a preset folder-count limit.
        - Preserve useful existing conventions and distinctions; do not merge unrelated categories or invent wrapper folders merely to reduce the top-level count.
        - Never name a folder the same as an existing file in the input.
        - Use clear folder names
        \(mode == .renameOnly ? "" : "- Actively create folder assignments when moving files would materially improve findability; do not default to leaving files in place because the current layout is merely passable or categorization is uncertain.")
        \(mode == .renameOnly ? "" : "- Return a no-op only when the files are already sensibly organized, no move would help, or safety and user rules prohibit moving them; never use a no-op to avoid choosing a reasonable structure.")
        - Before using unorganized, try a suitable existing folder, a meaningful shared folder, a broad reusable category, then a justified standalone project or category folder.
        - Never create an Unorganized or Unorganized Files folder. Put genuinely unplaceable files only in the unorganized field.
        - Use unorganized only when all four options fail. Uncertainty alone is not enough.
        - Prefer using file_ids in compact responses when IDs are provided.
        - Nest with "subfolders" (same folder shape) when a folder holds 2+ distinct subgroups such as projects, years/months, or types; keep depth at 2 or less unless the user asks for more.
        - Every folder must include one concise reasoning sentence naming the exact shared subject, project, source, date pattern, or compatible file roles.
        - Never use vague folder reasoning such as "these files belong together".
        - Group by type: Documents, Media, Code, Archives
        - Existing finder_tags are tag names; finder_color is the visible Finder label color. Match color instructions against finder_color. If the user says "only", change matching items only and leave nonmatches unchanged. A tagged folder makes its listed descendants match.
        - If learnings_context is provided with rule_id attributes, include "rule_id" on folders influenced by those rules.
        - `learning_action` is a rare tool call. Default it to null. Set it to {"name":"exclude_current_run_from_learning","reason":"brief explicit request","source":"direct_instructions"} only when the user clearly asks Sorty not to learn from this specific run. A persona may use source "persona". Never call it because files are sensitive-looking, unusual, temporary, uncertain, or conflict with learned preferences. Ambiguity means null.
        \(mode == .renameOnly || mode == .organizeAndRename ? "- Prefer better filenames; keep originals only when they are already clear, stable/protected, or user-excluded." : "")
        \(mode == .renameOnly || mode == .organizeAndRename ? "- Generic camera, screenshot, scan, download, or default app names should usually receive suggested_name when evidence supports it." : "")
        \(mode == .renameOnly || mode == .organizeAndRename ? "- For each rename_reason, cite concrete evidence and avoid generic wording." : "")
        \(mode == .renameOnly || mode == .organizeAndRename ? "- In compact responses, return evidence-backed renames in rename_suggestions using the matching file_id; file_ids alone cannot rename a file." : "")
        \(enableTagging ? "" : "- Do NOT include tags or comments. Omit \"tags\" and \"comment\" fields.")
        
        Set session_name to a specific 2-5 word title for this run's content or purpose. Do not include status, dates, or the word session.
        Return exactly one JSON object. Start with "{" immediately and output no markdown, prose, progress lines, or reasoning outside JSON:
        {"session_name":"Specific 2-5 word title","folder_assignments":[{\(compactFolderPayload),"reasoning":"Concrete shared cue for this grouping","subfolders":[]}],"notes":"","learning_action":null}
        or legacy:
        {"folders":[{"name":"","files":[\(mode == .renameOnly || mode == .organizeAndRename ? "{\"filename\":\"\",\"suggested_name\":\"\",\"rename_reason\":\"\",\"rename_confidence\":0.0}" : "\"\"")],"description":"",\(enableReasoning ? "\"reasoning\":\"\",": "")\(enableTagging ? "\"tags\":[\"\"]," : "")"subfolders":[]}],"unorganized":[{"filename":"","reason":""}]}
        """
        
        return prompt
    }

    static func promptPair(for level: CompactionLevel, config: AIConfig, files: [FileItem]) -> (system: String, user: String) {
        let pair: (system: String, user: String)
        switch level {
        case .standard:
            let system = config.systemPromptOverride
                ?? buildCompactSystemPrompt(
                    mode: config.mode,
                    enableReasoning: config.enableReasoning,
                    enableSmartRename: config.enableSmartRename,
                    enableTagging: config.enableFileTagging
                )
            let user = buildCompactPrompt(files: files, mode: config.mode, enableReasoning: config.enableReasoning)
            pair = (system, user)
        case .ultra:
            pair = buildUltraCompactPrompt(
                files: files,
                mode: config.mode,
                enableReasoning: config.enableReasoning
            )
        case .summary:
            pair = buildSummaryPrompt(
                files: files,
                mode: config.mode,
                enableReasoning: config.enableReasoning
            )
        case .micro:
            pair = buildMicroPrompt(
                files: files,
                mode: config.mode,
                enableReasoning: config.enableReasoning
            )
        }
        let namingPolicy = compactNamingPolicy(config: config)
        guard !namingPolicy.isEmpty else { return pair }
        return (pair.system, namingPolicy + "\n\n" + pair.user)
    }
    
    private static func expandedCustomNamingInstructions(
        _ instructions: String,
        files: [FileItem],
        maxExamples: Int
    ) -> String {
        guard instructions.contains("{") else { return instructions }

        let examples = files.prefix(maxExamples).enumerated().map { index, file in
            let expanded = expandTemplateVariables(instructions, for: file, counter: index + 1)
            return "\(file.displayName) -> \(expanded)"
        }

        guard !examples.isEmpty else { return instructions }
        return "\(instructions) | Examples: \(examples.joined(separator: " ; "))"
    }

    private static func expandTemplateVariables(_ template: String, for file: FileItem, counter: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let relevantDate = file.modificationDate ?? file.creationDate ?? Date()

        let replacements: [String: String] = [
            "{date}": formatter.string(from: relevantDate),
            "{ext}": file.extension.lowercased(),
            "{size}": file.formattedSize,
            "{counter}": String(format: "%02d", counter)
        ]

        var output = template
        for (token, value) in replacements {
            output = output.replacingOccurrences(of: token, with: value)
        }
        return output
    }

    private static func contentMetadataDescription(_ metadata: ContentMetadata) -> String {
        var parts: [String] = []

        if let title = metadata.documentTitle, !title.isEmpty {
            parts.append("Title: \(truncateForPrompt(title, maxLength: 240))")
        }
        if let author = metadata.author, !author.isEmpty {
            parts.append("Author: \(truncateForPrompt(author, maxLength: 160))")
        }
        if let created = metadata.creationDate {
            parts.append("Document created: \(ISO8601DateFormatter().string(from: created))")
        }
        if let pages = metadata.pageCount {
            parts.append("Pages: \(pages)")
        }
        if let duration = metadata.duration {
            parts.append("Duration: \(duration) seconds")
        }
        if let keywords = metadata.keywords, !keywords.isEmpty {
            parts.append("Keywords: \(keywords.joined(separator: ", "))")
        }
        if let detected = metadata.detectedKeywords, !detected.isEmpty {
            parts.append("Detected keywords: \(detected.joined(separator: ", "))")
        }
        if let confidence = metadata.ocrConfidence {
            parts.append("OCR confidence: \(confidence)")
        }
        if let exif = metadata.exifData, !exif.isEmpty {
            let values = exif.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            parts.append("EXIF: \(truncateForPrompt(values.joined(separator: ", "), maxLength: 600))")
        }
        if let media = metadata.mediaInfo, !media.isEmpty {
            let values = media.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            parts.append("Media: \(truncateForPrompt(values.joined(separator: ", "), maxLength: 600))")
        }
        if let preview = metadata.textPreview, !preview.isEmpty {
            parts.append("Text: \(truncateForPrompt(preview, maxLength: 1_600))")
        }
        if let ocr = metadata.ocrText, !ocr.isEmpty {
            parts.append("OCR: \(truncateForPrompt(ocr, maxLength: 1_200))")
        }

        return parts.joined(separator: " | ")
    }

    private static func truncateForPrompt(_ text: String, maxLength: Int) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength)) + "..."
    }
    
    /// Lists exact descendant folder paths so the planner can reuse deeply nested destinations.
    static func buildExistingFoldersContext(at directoryURL: URL, maxFolders: Int = 1_000) -> String? {
        guard maxFolders > 0 else { return nil }

        let fileManager = FileManager.default
        var existingFolders: [String] = []

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true else {
                continue
            }

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            let path = relativePath(for: item, baseDirectoryURL: directoryURL)
            if path != "." {
                existingFolders.append(path)
            }
        }
        
        guard !existingFolders.isEmpty else { return nil }

        existingFolders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        let foldersToShow = existingFolders.prefix(maxFolders)
        let truncated = existingFolders.count > maxFolders

        var context = "## EXISTING DESCENDANT FOLDERS (exact paths; prefer reusing these when semantically appropriate):\n"
        context += foldersToShow.map { "- \($0)" }.joined(separator: "\n")
        if truncated {
            context += "\n- ... and \(existingFolders.count - maxFolders) more"
        }
        context += "\n\nIMPORTANT: A listed path is one complete destination relative to the watched folder. Copy the full path exactly when it fits. Prefer an existing descendant folder over creating a duplicate hierarchy."
        
        return context
    }

    static func buildDirectoryManifestContext(
        baseDirectoryURL: URL,
        files: [FileItem],
        maxEntries: Int = 400
    ) -> String? {
        guard !files.isEmpty else { return nil }

        // Build summaries in one pass. Sorting and Dictionary(grouping:) over the
        // complete scan used to duplicate the entire FileItem array before the AI
        // request, which is especially costly for very large folders.
        var extensionCounts: [String: Int] = [:]
        var parentCounts: [String: Int] = [:]
        var manifestEntries: [(relativePath: String, file: FileItem)] = []
        manifestEntries.reserveCapacity(min(maxEntries, files.count))

        for file in files {
            let relative = relativePath(for: file, baseDirectoryURL: baseDirectoryURL)
            let ext = file.extension.isEmpty ? "(none)" : file.extension.lowercased()
            extensionCounts[ext, default: 0] += 1

            let parent = URL(fileURLWithPath: relative).deletingLastPathComponent().path
            let parentKey = parent == "/" || parent == "." ? "(root)" : parent
            parentCounts[parentKey, default: 0] += 1

            if manifestEntries.count < maxEntries {
                manifestEntries.append((relative, file))
            }
        }

        manifestEntries.sort {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }

        let extensionSummary = extensionCounts
        .sorted { $0.value > $1.value }
        .prefix(12)
        .map { "\($0.key):\($0.value)" }
        .joined(separator: ", ")

        let parentSummary = parentCounts
        .sorted { $0.value > $1.value }
        .prefix(10)
        .map { "\($0.key): \($0.value)" }
        .joined(separator: ", ")

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let manifestLines = manifestEntries.map { entry in
            let file = entry.file
            var line = "- \(entry.relativePath) | \(file.extension.isEmpty ? "no-ext" : file.extension.lowercased()) | \(file.formattedSize)"
            if let modified = file.modificationDate {
                line += " | modified \(dateFormatter.string(from: modified))"
            }
            if let tags = file.finderTags, !tags.isEmpty {
                line += " | finder_tags \(tags.joined(separator: ", "))"
            }
            if let color = file.finderTagColorName {
                line += " | finder_color \(color)"
            }
            return line
        }

        let ancestorNames = directoryContextNames(for: baseDirectoryURL)
        let directoryMetadata = directoryMetadataContext(
            baseDirectoryURL: baseDirectoryURL,
            maxEntries: maxEntries
        )

        var context = """
        ## SOURCE FOLDER CONTEXT
        Source directory: \(baseDirectoryURL.lastPathComponent)
        Ancestor context: \(ancestorNames.isEmpty ? "n/a" : ancestorNames.joined(separator: " / "))
        Files in current organization scope: \(files.count)
        Extension mix: \(extensionSummary.isEmpty ? "n/a" : extensionSummary)
        Folder distribution: \(parentSummary.isEmpty ? "(root only)" : parentSummary)
        \(directoryMetadata)
        Relative paths in scope:
        \(manifestLines.joined(separator: "\n"))
        """

        if files.count > maxEntries {
            context += "\n- ... and \(files.count - maxEntries) more files in scope"
        }

        context += "\nUse this context to understand projects, clients, events, and existing groupings before deciding on folder structure. Do not rely on filenames alone."
        return context
    }

    /// Builds filesystem-backed source context without occupying the caller's actor.
    static func buildDirectoryManifestContextOffMain(
        baseDirectoryURL: URL,
        files: [FileItem],
        maxEntries: Int = 400
    ) async throws -> String? {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let context = buildDirectoryManifestContext(
                baseDirectoryURL: baseDirectoryURL,
                files: files,
                maxEntries: maxEntries
            )
            try Task.checkCancellation()
            return context
        }
        return try await withTaskCancellationHandler {
            let context = try await task.value
            try Task.checkCancellation()
            return context
        } onCancel: {
            task.cancel()
        }
    }

    private static func directoryMetadataContext(
        baseDirectoryURL: URL,
        maxEntries: Int
    ) -> String {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .tagNamesKey,
            .labelNumberKey,
        ]
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        var lines: [String] = []
        var directoryCount = 0

        func appendDirectory(_ url: URL, relativePath: String) {
            directoryCount += 1
            guard lines.count < maxEntries else { return }

            let values = try? url.resourceValues(forKeys: keys)
            var parts = ["- \(relativePath)"]
            if let created = values?.creationDate {
                parts.append("created \(dateFormatter.string(from: created))")
            }
            if let modified = values?.contentModificationDate {
                parts.append("modified \(dateFormatter.string(from: modified))")
            }
            if let accessed = values?.contentAccessDate {
                parts.append("accessed \(dateFormatter.string(from: accessed))")
            }
            if let tags = values?.tagNames, !tags.isEmpty {
                parts.append("finder_tags \(tags.joined(separator: ", "))")
            }
            if let color = values?.labelNumber.flatMap(FinderTagColor.init(rawValue:))?.name {
                parts.append("finder_color \(color)")
            }
            if let comment = url.finderComment, !comment.isEmpty {
                parts.append("comment \(truncateForPrompt(comment, maxLength: 200))")
            }
            lines.append(parts.joined(separator: " | "))
        }

        appendDirectory(baseDirectoryURL, relativePath: ".")
        if let enumerator = FileManager.default.enumerator(
            at: baseDirectoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            while let item = enumerator.nextObject() as? URL {
                guard (try? item.resourceValues(forKeys: keys).isDirectory) == true else {
                    continue
                }
                appendDirectory(
                    item,
                    relativePath: relativePath(for: item, baseDirectoryURL: baseDirectoryURL)
                )
            }
        }

        var context = "Directory metadata in scope (\(directoryCount) total):\n"
        context += lines.joined(separator: "\n")
        if directoryCount > lines.count {
            context += "\n- ... and \(directoryCount - lines.count) more directories in scope"
        }
        return context
    }

    static func buildFinderTaggedFolderContext(
        baseDirectoryURL: URL,
        files: [FileItem]
    ) -> String? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .tagNamesKey, .labelNumberKey]
        var lines: [String] = []
        let baseURL = baseDirectoryURL.standardizedFileURL
        let basePath = baseURL.path
        var candidateDirectories: Set<URL> = [baseURL]

        for file in files {
            var directory = file.isDirectory
                ? URL(fileURLWithPath: file.path).standardizedFileURL
                : URL(fileURLWithPath: file.path).deletingLastPathComponent().standardizedFileURL

            while directory.path == basePath || directory.path.hasPrefix(basePath + "/") {
                candidateDirectories.insert(directory)
                guard directory.path != basePath else { break }
                let parent = directory.deletingLastPathComponent().standardizedFileURL
                guard parent.path != directory.path else { break }
                directory = parent
            }
        }

        func appendTaggedDirectory(_ url: URL, relativePath: String) {
            guard let values = try? url.resourceValues(forKeys: keys) else { return }
            let tags = values.tagNames ?? []
            let color = values.labelNumber.flatMap(FinderTagColor.init(rawValue:))?.name
            guard !tags.isEmpty || color != nil else { return }

            var parts = ["- \(relativePath)"]
            if !tags.isEmpty {
                parts.append("finder_tags \(tags.joined(separator: ", "))")
            }
            if let color {
                parts.append("finder_color \(color)")
            }
            lines.append(parts.joined(separator: " | "))
        }

        for directory in candidateDirectories.sorted(by: {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }) {
            appendTaggedDirectory(
                directory,
                relativePath: directory.path == basePath
                    ? "."
                    : relativePath(for: directory, baseDirectoryURL: baseURL)
            )
        }

        guard !lines.isEmpty else { return nil }
        var context = "## FINDER-TAGGED FOLDERS IN SCOPE\n" + lines.joined(separator: "\n")
        context += "\nA file below a listed folder inherits that folder's match for tag-selection instructions."
        return context
    }

    private static func directoryContextNames(for directoryURL: URL, maxAncestors: Int = 3) -> [String] {
        var names: [String] = []
        var cursor = directoryURL.deletingLastPathComponent()

        while names.count < maxAncestors {
            let name = cursor.lastPathComponent
            guard !name.isEmpty && name != "/" else { break }
            names.append(name)

            let next = cursor.deletingLastPathComponent()
            guard next.path != cursor.path else { break }
            cursor = next
        }

        return names.reversed()
    }

    private static func relativePath(for file: FileItem, baseDirectoryURL: URL) -> String {
        if let relativePath = file.relativePath, !relativePath.isEmpty {
            return relativePath
        }
        let path = file.path
        let basePath = baseDirectoryURL.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            return String(path.dropFirst(basePath.count + 1))
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func relativePath(for itemURL: URL, baseDirectoryURL: URL) -> String {
        let path = itemURL.standardizedFileURL.path
        let basePath = baseDirectoryURL.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else {
            return itemURL.lastPathComponent
        }
        return String(path.dropFirst(basePath.count + 1))
    }
    
    // MARK: - Reference Model Directory Context
    
    /// Build a reference-directory context section from one or more model directories.
    /// Scans folder structure only (no file content analysis) to keep prompts lightweight.
    /// - Parameters:
    ///   - paths: Filesystem paths to reference directories
    ///   - maxDepth: Maximum directory traversal depth (default 3)
    ///   - maxEntriesPerDirectory: Maximum folder entries per directory (default 20)
    /// - Returns: Formatted prompt context string, or empty string if no valid directories
    static func buildReferenceDirectoryContext(
        paths: [String],
        maxDepth: Int = 3,
        maxEntriesPerDirectory: Int = 20
    ) -> String {
        let fm = FileManager.default
        var sections: [String] = []
        
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            
            let dirName = url.lastPathComponent
            var folders: [String] = []
            
            func scan(_ scanURL: URL, depth: Int, prefix: String) {
                guard depth <= maxDepth, folders.count < maxEntriesPerDirectory else { return }
                
                guard let contents = try? fm.contentsOfDirectory(
                    at: scanURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { return }
                
                let subdirs = contents.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                
                for subdir in subdirs {
                    guard folders.count < maxEntriesPerDirectory else { return }
                    let name = prefix.isEmpty ? subdir.lastPathComponent : "\(prefix)/\(subdir.lastPathComponent)"
                    folders.append(name)
                    
                    if depth < maxDepth {
                        scan(subdir, depth: depth + 1, prefix: name)
                    }
                }
            }
            
            scan(url, depth: 1, prefix: "")
            
            guard !folders.isEmpty else { continue }
            
            let truncated = folders.count >= maxEntriesPerDirectory
            let folderList = folders.map { "  - \($0)" }.joined(separator: "\n")
            var section = "Reference: \"\(dirName)\"\n\(folderList)"
            if truncated {
                section += "\n  ... (truncated to \(maxEntriesPerDirectory) entries)"
            }
            sections.append(section)
        }
        
        guard !sections.isEmpty else { return "" }
        
        return """
        ## REFERENCE MODEL DIRECTORIES
        The user has provided the following well-organized directories as examples of their preferred folder structure and naming conventions. Use these as guidance for how to name and organize folders — match the style, hierarchy depth, and naming patterns you see here.
        
        \(sections.joined(separator: "\n\n"))
        
        IMPORTANT: These are reference examples only — do NOT reorganize files into these directories. Instead, replicate the naming style and structure patterns in your organization plan.
        """
    }
}
