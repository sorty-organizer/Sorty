//
//  FilenameSanitizer.swift
//  Sorty
//
//  Defensive filename sanitization and validation for AI/user rename flows.
//

import Foundation

public struct FilenameSanitizer {
    public static let maxFilenameBytes = 255
    public static let recommendedLength = 60

    private static let invalidCharacterSet = CharacterSet(charactersIn: ":/\u{0000}\\")
    private static let trimCharacterSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))

    public struct Result: Sendable, Equatable {
        public let originalName: String
        public let sanitizedName: String?
        public let hadInvalidCharacters: Bool
        public let hadTrimming: Bool
        public let extensionAdjusted: Bool
        public let exceededMaxBytes: Bool
        public let exceededRecommendedLength: Bool
        public let isReservedName: Bool
        public let isExtensionOnly: Bool
        public let isEmpty: Bool

        public var isValid: Bool {
            sanitizedName != nil && !isReservedName && !isExtensionOnly && !isEmpty
        }

        public var warnings: [String] {
            var values: [String] = []
            if hadInvalidCharacters {
                values.append("Invalid characters were replaced.")
            }
            if hadTrimming {
                values.append("Leading or trailing spaces/dots were trimmed.")
            }
            if extensionAdjusted {
                values.append("File extension was adjusted to match the original.")
            }
            if exceededMaxBytes {
                values.append("Filename was truncated to fit macOS limits.")
            }
            if exceededRecommendedLength {
                values.append("Filename is longer than the recommended \(FilenameSanitizer.recommendedLength) characters.")
            }
            return values
        }

        public var errors: [String] {
            var values: [String] = []
            if isEmpty {
                values.append("Filename is empty.")
            }
            if isReservedName {
                values.append("Filename cannot be '.' or '..'.")
            }
            if isExtensionOnly {
                values.append("Filename cannot be only an extension.")
            }
            return values
        }
    }

    public static func sanitize(
        _ rawName: String,
        preservingExtension originalExtension: String? = nil,
        enforceExtension: Bool = true
    ) -> Result {
        let replaced = replaceInvalidCharacters(in: rawName)
        var workingName = replaced.value
        var extensionAdjusted = false
        var exceededMaxBytes = false

        // Evaluate special invalid cases before Finder-like dot trimming.
        let whitespaceTrimmedOnly = workingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasReservedBeforeTrim = (whitespaceTrimmedOnly == "." || whitespaceTrimmedOnly == "..")
        let wasExtensionOnlyBeforeTrim = isExtensionOnlyToken(whitespaceTrimmedOnly)

        let trimmedName = workingName.trimmingCharacters(in: trimCharacterSet)
        let hadTrimming = trimmedName != workingName
        workingName = trimmedName

        var isEmpty = workingName.isEmpty
        var isReservedName = wasReservedBeforeTrim || (workingName == "." || workingName == "..")
        var isExtensionOnly = wasExtensionOnlyBeforeTrim

        if !isEmpty && !isReservedName && enforceExtension {
            let desiredExtension = normalizedExtension(originalExtension)
            let existingExtension = normalizedExtension((workingName as NSString).pathExtension)
            var baseName = (workingName as NSString).deletingPathExtension

            if desiredExtension.isEmpty {
                if !existingExtension.isEmpty {
                    extensionAdjusted = true
                    workingName = baseName
                }
            } else {
                if baseName.isEmpty {
                    baseName = workingName
                }
                if existingExtension != desiredExtension {
                    extensionAdjusted = true
                    workingName = baseName.isEmpty ? "untitled.\(desiredExtension)" : "\(baseName).\(desiredExtension)"
                } else if existingExtension.isEmpty {
                    extensionAdjusted = true
                    workingName = "\(baseName).\(desiredExtension)"
                }
            }
        }

        if !workingName.isEmpty {
            let baseName = (workingName as NSString).deletingPathExtension
            isExtensionOnly = isExtensionOnly || baseName.isEmpty
        }

        if utf8ByteCount(workingName) > maxFilenameBytes {
            workingName = truncateToMaxBytes(workingName, maxBytes: maxFilenameBytes)
            exceededMaxBytes = true
        }

        isEmpty = workingName.isEmpty
        isReservedName = isReservedName || (workingName == "." || workingName == "..")
        if !workingName.isEmpty {
            let baseName = (workingName as NSString).deletingPathExtension
            isExtensionOnly = isExtensionOnly || baseName.isEmpty
        }

        let sanitized: String? = (isEmpty || isReservedName || isExtensionOnly) ? nil : workingName
        let exceededRecommendedLength = (sanitized?.count ?? 0) > recommendedLength

        return Result(
            originalName: rawName,
            sanitizedName: sanitized,
            hadInvalidCharacters: replaced.didReplace,
            hadTrimming: hadTrimming,
            extensionAdjusted: extensionAdjusted,
            exceededMaxBytes: exceededMaxBytes,
            exceededRecommendedLength: exceededRecommendedLength,
            isReservedName: isReservedName,
            isExtensionOnly: isExtensionOnly,
            isEmpty: isEmpty
        )
    }

    public static func utf8ByteCount(_ value: String) -> Int {
        value.lengthOfBytes(using: .utf8)
    }

    private static func normalizedExtension(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private static func replaceInvalidCharacters(in input: String) -> (value: String, didReplace: Bool) {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(input.unicodeScalars.count)
        var didReplace = false

        for scalar in input.unicodeScalars {
            if invalidCharacterSet.contains(scalar) {
                didReplace = true
                output.append(UnicodeScalar(45)!) // "-"
            } else {
                output.append(scalar)
            }
        }

        return (String(output), didReplace)
    }

    private static func truncateToMaxBytes(_ value: String, maxBytes: Int) -> String {
        guard utf8ByteCount(value) > maxBytes else { return value }

        let currentExt = normalizedExtension((value as NSString).pathExtension)
        let suffix = currentExt.isEmpty ? "" : ".\(currentExt)"
        let suffixBytes = utf8ByteCount(suffix)

        // If suffix alone exceeds limit (unlikely), hard-truncate by scalar.
        if suffixBytes >= maxBytes {
            return truncateWithoutBreakingUnicode(value, maxBytes: maxBytes)
        }

        let baseName = (value as NSString).deletingPathExtension
        let allowedBaseBytes = maxBytes - suffixBytes
        let truncatedBase = truncateWithoutBreakingUnicode(baseName, maxBytes: allowedBaseBytes)
        return truncatedBase + suffix
    }

    private static func truncateWithoutBreakingUnicode(_ value: String, maxBytes: Int) -> String {
        var result = ""
        result.reserveCapacity(value.count)

        for character in value {
            let candidate = result + String(character)
            if utf8ByteCount(candidate) > maxBytes {
                break
            }
            result = candidate
        }

        return result
    }

    private static func isExtensionOnlyToken(_ value: String) -> Bool {
        guard value.hasPrefix("."), value.count > 1 else { return false }
        let body = String(value.dropFirst())
        return !body.isEmpty && !body.contains(".")
    }
}
