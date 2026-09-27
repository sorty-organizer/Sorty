//
//  FilenameNormalizer.swift
//  Sorty
//
//  Applies user-facing rename formatting preferences after AI generation.
//

import Foundation

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
}
