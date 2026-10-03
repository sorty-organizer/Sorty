//
//  FilenameNormalizer.swift
//  Sorty
//
//  Applies user-facing rename formatting preferences after AI generation.
//

import Foundation
import SortyFileSystem

/// A single `/`-separated component of a proposed folder path that cannot be
/// created as-is. Returned by the plan quality gate so a retry can fix the
/// name; the organizer must flag, never silently rename.
public struct InvalidFolderNameComponent: Sendable, Equatable {
    public let component: String
    public let reason: String

    public init(component: String, reason: String) {
        self.component = component
        self.reason = reason
    }
}

public enum FilenameNormalizer {
    public static func normalize(
        _ suggestedName: String,
        originalFilename: String,
        options: RenameNamingOptions
    ) -> String? {
        guard !isProtectedFilename(originalFilename) else { return nil }

        let originalExtension = (originalFilename as NSString).pathExtension
        let sanitized = FilenameSanitizer.sanitize(
            suggestedName,
            preservingExtension: originalExtension,
            enforceExtension: true
        )
        guard let sanitizedName = sanitized.sanitizedName, sanitized.isValid else { return nil }

        let ext = (sanitizedName as NSString).pathExtension
        var base = (sanitizedName as NSString).deletingPathExtension
        base = stripRedundantFileTokens(base)
        base = applyCaseStyle(options.caseStyle, to: base)
        base = applySeparator(options.separator, to: base, caseStyle: options.caseStyle)
        base = base.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))

        guard !base.isEmpty else { return nil }

        let limitedBase = limitBase(base, extension: ext, maxLength: options.maxFilenameLength)
        let finalName = ext.isEmpty ? limitedBase : "\(limitedBase).\(ext)"
        guard finalName != originalFilename else { return nil }

        let finalSanitized = FilenameSanitizer.sanitize(
            finalName,
            preservingExtension: originalExtension,
            enforceExtension: true
        )
        return finalSanitized.isValid ? finalSanitized.sanitizedName : nil
    }

    public static func uniqued(_ name: String, against existingNames: inout Set<String>) -> String {
        guard existingNames.contains(name) else {
            existingNames.insert(name)
            return name
        }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var counter = 1

        while true {
            let candidateBase = "\(base)_\(counter)"
            let candidate = ext.isEmpty ? candidateBase : "\(candidateBase).\(ext)"
            if !existingNames.contains(candidate) {
                existingNames.insert(candidate)
                return candidate
            }
            counter += 1
        }
    }

    public static func isProtectedFilename(_ filename: String) -> Bool {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { return true }

        let protectedNames: Set<String> = ["Makefile", "Dockerfile", "Package.swift", "Podfile", "Gemfile"]
        if protectedNames.contains(trimmed) { return true }

        let base = (trimmed as NSString).deletingPathExtension
        let versionPattern = #"^v?\d+(\.\d+){1,3}([._-]?(alpha|beta|rc)\d*)?$"#
        return base.range(of: versionPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func stripRedundantFileTokens(_ text: String) -> String {
        var value = text
        let patterns = [
            #"(?i)\bIMG[_\s-]*"#,
            #"(?i)\bDSC[_\s-]*"#,
            #"(?i)\bScreenshot[_\s-]*"#,
            #"(?i)\bScreen Shot[_\s-]*"#,
            #"(?i)\bDocument\s*\(\d+\)"#,
            #"(?i)\bCopy of\s+"#
        ]

        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        return value
    }

    private static func applyCaseStyle(_ style: RenameCaseStyle, to text: String) -> String {
        let words = words(from: text)
        guard !words.isEmpty else { return text }

        switch style {
        case .natural:
            return words.joined(separator: " ")
        case .title:
            return words.map { capitalize($0) }.joined(separator: " ")
        case .sentence:
            let sentence = words.map { $0.lowercased() }.joined(separator: " ")
            return sentence.prefix(1).uppercased() + String(sentence.dropFirst())
        case .camel:
            return words.enumerated().map { index, word in
                index == 0 ? word.lowercased() : capitalize(word)
            }.joined()
        case .pascal:
            return words.map { capitalize($0) }.joined()
        case .snake:
            return words.map { $0.lowercased() }.joined(separator: "_")
        case .kebab:
            return words.map { $0.lowercased() }.joined(separator: "-")
        }
    }

    private static func applySeparator(
        _ separator: RenameSeparatorPreference,
        to text: String,
        caseStyle: RenameCaseStyle
    ) -> String {
        switch caseStyle {
        case .camel, .pascal, .snake, .kebab:
            return text
        default:
            break
        }

        let replacement: String?
        switch separator {
        case .spaces, .smart:
            replacement = " "
        case .hyphen:
            replacement = "-"
        case .underscore:
            replacement = "_"
        }

        guard let replacement else { return text }
        return words(from: text).joined(separator: replacement)
    }

    private static func words(from text: String) -> [String] {
        let pattern = #"\d{4}-\d{2}-\d{2}|[\p{L}\p{N}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func capitalize(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    private static func limitBase(_ base: String, extension ext: String, maxLength: Int) -> String {
        let extensionAllowance = ext.isEmpty ? 0 : ext.count + 1
        let maxBaseLength = max(1, maxLength - extensionAllowance)
        guard base.count > maxBaseLength else { return base }
        return String(base.prefix(maxBaseLength)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
    }

    /// Validates each `/`-separated component of a proposed folder path without
    /// renaming anything. Returns one entry per violation; an empty result
    /// means the name is safe to create as-is.
    public static func invalidFolderNameComponents(in folderName: String) -> [InvalidFolderNameComponent] {
        if folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [InvalidFolderNameComponent(
                component: folderName,
                reason: "the folder name is empty or whitespace-only"
            )]
        }

        var parts = folderName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // A single leading `/` marks an absolute storage destination and a
        // single trailing `/` is harmless; any other empty component means a
        // collapsed `//` that path splitting would otherwise hide.
        if folderName.hasPrefix("/") { parts.removeFirst() }
        if folderName.hasSuffix("/"), parts.last?.isEmpty == true { parts.removeLast() }

        var issues: [InvalidFolderNameComponent] = []
        for part in parts {
            if part.isEmpty {
                issues.append(InvalidFolderNameComponent(
                    component: part,
                    reason: "the path contains an empty component (\"//\"), which collapses silently"
                ))
                continue
            }
            if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(InvalidFolderNameComponent(
                    component: part,
                    reason: "the path component is blank or whitespace-only"
                ))
                continue
            }
            if part == "." || part == ".." {
                issues.append(InvalidFolderNameComponent(
                    component: part,
                    reason: "\"\(part)\" is a reserved path component"
                ))
                continue
            }
            let edgeTrimmed = part.trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
            )
            if edgeTrimmed != part {
                issues.append(InvalidFolderNameComponent(
                    component: part,
                    reason: "starts or ends with a space or dot, which the Finder strips"
                ))
            }
            if part.contains(":") {
                issues.append(InvalidFolderNameComponent(
                    component: part,
                    reason: "contains \":\", which the Finder shows as \"/\""
                ))
            }
            if part.rangeOfCharacter(from: .controlCharacters) != nil {
                issues.append(InvalidFolderNameComponent(
                    component: part,
                    reason: "contains control characters"
                ))
            }
            if FilenameSanitizer.utf8ByteCount(part) > FilenameSanitizer.maxFilenameBytes {
                issues.append(InvalidFolderNameComponent(
                    component: part,
                    reason: "is longer than \(FilenameSanitizer.maxFilenameBytes) bytes"
                ))
            }
        }
        return issues
    }
}
