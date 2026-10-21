import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum OrganizingStreamSuggestions {
    private static let maxParseCharacters = 30_000
    private static let maxVisibleFolders = 5
    private static let maxFilesPerFolder = 12
    // JSON string body: any escaped character or any character that is not a
    // quote or backslash. This correctly handles \\, \", \n, and \uXXXX.
    private static let folderNameRegex = try? NSRegularExpression(
        pattern: #""name"\s*:\s*"((?:\\.|[^"\\])*)""#,
        options: []
    )
    private static let filenameRegex = try? NSRegularExpression(
        pattern: #""filename"\s*:\s*"((?:\\.|[^"\\])*)""#,
        options: []
    )
    private static let suggestedNameRegex = try? NSRegularExpression(
        pattern: #""suggested_name"\s*:\s*"((?:\\.|[^"\\])*)""#,
        options: []
    )
    /// Preferred compact format: `"file_ids":[1,2,3]`. The closing bracket is
    /// optional so partially streamed arrays still parse.
    private static let fileIDsRegex = try? NSRegularExpression(
        pattern: #""file_ids"\s*:\s*\[([^\]]*)(\])?"#,
        options: []
    )
    /// Rename entries in the preferred compact format:
    /// `{"file_id":1,"suggested_name":"Clear Name.ext",...}`.
    private static let renamePairRegex = try? NSRegularExpression(
        pattern: #""file_id"\s*:\s*(\d+)[^{}]*?"suggested_name"\s*:\s*"((?:\\.|[^"\\])*)""#,
        options: []
    )
    /// Legacy organize-only format: `"files":["name.pdf","other.png"]`.
    /// The body excludes braces/brackets so object arrays never match here.
    private static let plainFilesArrayRegex = try? NSRegularExpression(
        pattern: #""files"\s*:\s*\[([^\[\]{}]*)"#,
        options: []
    )
    private static let quotedStringRegex = try? NSRegularExpression(
        pattern: #""((?:\\.|[^"\\])*)""#,
        options: []
    )

    static func parse(
        from streamText: String,
        files: [FileItem],
        fileIDTable: [Int: FileItem] = [:]
    ) -> [FolderSuggestion] {
        parse(from: streamText, filesByName: fileLookup(from: files), fileIDTable: fileIDTable)
    }

    static func parse(
        from streamText: String,
        filesByName: [String: FileItem],
        fileIDTable: [Int: FileItem] = [:]
    ) -> [FolderSuggestion] {
        guard let jsonStart = streamText.firstIndex(of: "{") else { return [] }

        let jsonText = boundedParseText(String(streamText[jsonStart...]))
        let nsText = jsonText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let folderMatches = folderNameRegex?.matches(in: jsonText, range: fullRange) ?? []
        guard !folderMatches.isEmpty else { return [] }

        var suggestionsByFolder: [String: FolderSuggestion] = [:]
        var orderedFolderNames: [String] = []
        var assignedFileIDs: Set<UUID> = []
        // The folder currently being generated: its name is complete but no
        // file assignments have streamed in yet. Shown as a pending bucket so
        // the stage reflects what the model is doing right now.
        var pendingFolderName: String?

        for index in folderMatches.indices {
            let folderMatch = folderMatches[index]
            guard folderMatch.numberOfRanges > 1 else { continue }

            let folderNameRange = folderMatch.range(at: 1)
            guard folderNameRange.location != NSNotFound else { continue }

            let folderName = displayFolderName(
                decodeJSONString(nsText.substring(with: folderNameRange))
            )
            guard !folderName.isEmpty, folderName != "." else { continue }

            let segmentStart = folderMatch.range.location + folderMatch.range.length
            let segmentEnd = index + 1 < folderMatches.count
                ? folderMatches[index + 1].range.location
                : nsText.length
            guard segmentEnd > segmentStart else { continue }

            let segmentRange = NSRange(location: segmentStart, length: segmentEnd - segmentStart)
            let segment = nsText.substring(with: segmentRange)
            let isLastFolder = index == folderMatches.count - 1
            let mentionsFiles = segment.range(of: #""files""#, options: .caseInsensitive) != nil
                || segment.range(of: #""file_ids""#, options: .caseInsensitive) != nil
            guard mentionsFiles || isLastFolder else { continue }

            let parsedEntries = mentionsFiles
                ? parseFiles(from: segment, filesByName: filesByName, fileIDTable: fileIDTable)
                : []
            guard !parsedEntries.isEmpty else {
                if isLastFolder {
                    pendingFolderName = folderName
                }
                continue
            }

            if suggestionsByFolder[folderName] == nil {
                orderedFolderNames.append(folderName)
                suggestionsByFolder[folderName] = FolderSuggestion(folderName: folderName)
            }

            var suggestion = suggestionsByFolder[folderName] ?? FolderSuggestion(folderName: folderName)
            let existingIDs = Set(suggestion.files.map(\.id))
            let newEntries = parsedEntries.filter {
                !existingIDs.contains($0.file.id) && assignedFileIDs.insert($0.file.id).inserted
            }
            let remainingSlots = max(0, maxFilesPerFolder - suggestion.files.count)
            for entry in newEntries.prefix(remainingSlots) {
                suggestion.files.append(entry.file)
                if let suggestedName = entry.suggestedName, suggestedName != entry.file.displayName {
                    suggestion.fileRenameMappings.append(
                        FileRenameMapping(
                            originalFile: entry.file,
                            suggestedName: suggestedName
                        )
                    )
                }
            }
            suggestionsByFolder[folderName] = suggestion
        }

        var results = orderedFolderNames
            .compactMap { suggestionsByFolder[$0] }
            .filter { !$0.files.isEmpty }
        if let pendingFolderName,
           !results.contains(where: { $0.folderName == pendingFolderName }) {
            results.append(FolderSuggestion(folderName: pendingFolderName))
        }
        return Array(results.suffix(maxVisibleFolders))
    }

    private static func parseFiles(
        from segment: String,
        filesByName: [String: FileItem],
        fileIDTable: [Int: FileItem]
    ) -> [(file: FileItem, suggestedName: String?)] {
        var parsedFiles: [(file: FileItem, suggestedName: String?)] = []
        var seenIDs: Set<UUID> = []

        // Preferred compact format: resolve "file_ids":[1,2] through the
        // request's published ID table.
        if !fileIDTable.isEmpty {
            let renamesByID = renameSuggestionsByFileID(in: segment)
            for id in fileIDValues(in: segment) {
                guard let file = fileIDTable[id], seenIDs.insert(file.id).inserted else { continue }
                parsedFiles.append((file: file, suggestedName: renamesByID[id]))
            }
        }

        // Rename-capable legacy format: objects with "filename" fields.
        let segmentText = segment as NSString
        for object in fileObjectMatches(in: segment, segmentText: segmentText) {
            let filename = firstCapture(regex: filenameRegex, text: object)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filename.isEmpty else { continue }

            let key = normalizedFileName(filename)
            guard let file = filesByName[key], seenIDs.insert(file.id).inserted else { continue }
            let suggestedName = firstCapture(regex: suggestedNameRegex, text: object)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            parsedFiles.append((file: file, suggestedName: suggestedName.isEmpty ? nil : suggestedName))
        }

        // Organize-only legacy format: "files":["name.pdf","other.png"].
        for filename in plainFileArrayNames(in: segment) {
            let key = normalizedFileName(filename)
            guard let file = filesByName[key], seenIDs.insert(file.id).inserted else { continue }
            parsedFiles.append((file: file, suggestedName: nil))
        }

        return parsedFiles
    }

    /// Extracts integer IDs from `"file_ids":[...]` arrays in the segment.
    /// While the array is still streaming (no closing bracket yet), a trailing
    /// number is dropped because more digits may follow.
    private static func fileIDValues(in segment: String) -> [Int] {
        guard let regex = fileIDsRegex else { return [] }
        let nsSegment = segment as NSString
        let matches = regex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length))

        var ids: [Int] = []
        for match in matches where match.numberOfRanges > 2 {
            let bodyRange = match.range(at: 1)
            guard bodyRange.location != NSNotFound else { continue }
            let body = nsSegment.substring(with: bodyRange)
            let isClosed = match.range(at: 2).location != NSNotFound && match.range(at: 2).length > 0

            var tokens = body
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !isClosed, let last = body.unicodeScalars.last, CharacterSet.decimalDigits.contains(last) {
                tokens.removeLast()
            }
            ids.append(contentsOf: tokens.compactMap { Int($0) })
        }
        return ids
    }

    private static func renameSuggestionsByFileID(in segment: String) -> [Int: String] {
        guard let regex = renamePairRegex else { return [:] }
        let nsSegment = segment as NSString
        let matches = regex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length))

        var renames: [Int: String] = [:]
        for match in matches where match.numberOfRanges > 2 {
            let idRange = match.range(at: 1)
            let nameRange = match.range(at: 2)
            guard idRange.location != NSNotFound, nameRange.location != NSNotFound,
                  let id = Int(nsSegment.substring(with: idRange)) else { continue }
            let name = decodeJSONString(nsSegment.substring(with: nameRange))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                renames[id] = name
            }
        }
        return renames
    }

    /// Filenames from legacy plain-string arrays: `"files":["a.pdf","b.png"]`.
    /// Only complete quoted strings match, so partially streamed names are
    /// skipped until their closing quote arrives.
    private static func plainFileArrayNames(in segment: String) -> [String] {
        guard let arrayRegex = plainFilesArrayRegex, let stringRegex = quotedStringRegex else { return [] }
        let nsSegment = segment as NSString
        let arrayMatches = arrayRegex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length))

        var names: [String] = []
        for match in arrayMatches where match.numberOfRanges > 1 {
            let bodyRange = match.range(at: 1)
            guard bodyRange.location != NSNotFound else { continue }
            let body = nsSegment.substring(with: bodyRange)
            let nsBody = body as NSString
            let stringMatches = stringRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            for stringMatch in stringMatches where stringMatch.numberOfRanges > 1 {
                let nameRange = stringMatch.range(at: 1)
                guard nameRange.location != NSNotFound else { continue }
                let name = decodeJSONString(nsBody.substring(with: nameRange))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    names.append(name)
                }
            }
        }
        return names
    }

    private static func fileObjectMatches(in segment: String, segmentText: NSString) -> [String] {
        let objectPattern = #"\{[^{}]*"filename"\s*:\s*"((?:\\.|[^"\\])*)"[^{}]*\}"#
        if let objectRegex = try? NSRegularExpression(pattern: objectPattern, options: []) {
            let objectMatches = objectRegex.matches(
                in: segment,
                range: NSRange(location: 0, length: segmentText.length)
            )
            if !objectMatches.isEmpty {
                return objectMatches.map { segmentText.substring(with: $0.range) }
            }
        }

        let filenameMatches = filenameRegex?.matches(
            in: segment,
            range: NSRange(location: 0, length: segmentText.length)
        ) ?? []
        return filenameMatches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let filenameRange = match.range(at: 1)
            guard filenameRange.location != NSNotFound else { return nil }
            let filename = segmentText.substring(with: filenameRange)
            return #""filename":"\#(filename)""#
        }
    }

    private static func firstCapture(regex: NSRegularExpression?, text: String) -> String {
        guard let regex else { return "" }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return ""
        }
        let captureRange = match.range(at: 1)
        guard captureRange.location != NSNotFound else { return "" }
        return decodeJSONString(nsText.substring(with: captureRange))
    }

    private static func boundedParseText(_ text: String) -> String {
        guard text.count > maxParseCharacters else { return text }
        let start = text.index(text.endIndex, offsetBy: -maxParseCharacters)
        return String(text[start...])
    }

    static func fileLookup(from files: [FileItem]) -> [String: FileItem] {
        var lookup: [String: FileItem] = [:]
        var ambiguousKeys: Set<String> = []
        lookup.reserveCapacity(files.count)
        for file in files {
            let keys = Set([
                normalizedFileName(file.displayName),
                normalizedFileName(file.path),
                normalizedFileName(file.name)
            ])
            for key in keys where !key.isEmpty {
                if let existing = lookup[key], existing.id != file.id {
                    // Two distinct files share a basename; drop the key rather
                    // than animating an arbitrary one of them.
                    ambiguousKeys.insert(key)
                } else {
                    lookup[key] = file
                }
            }
        }
        for key in ambiguousKeys {
            lookup.removeValue(forKey: key)
        }
        return lookup
    }

    private static func normalizedFileName(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func displayFolderName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/") || trimmed.contains("\\") else { return trimmed }

        return trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? trimmed
    }

    private static func decodeJSONString(_ value: String) -> String {
        guard let data = "\"\(value)\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data)
        else {
            return value
                .replacingOccurrences(of: #"\""#, with: #"""#)
                .replacingOccurrences(of: #"\\/"#, with: "/")
        }
        return decoded
    }
}

