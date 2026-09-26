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

struct RenameStreamEvent: Identifiable, Equatable {
    let id: String
    let originalName: String
    let suggestedName: String?
    let reason: String?
    let filePath: String?
    let isDirectory: Bool

    var isRevealed: Bool {
        suggestedName?.isEmpty == false
    }
}

struct LiveStreamPreviewState {
    var scannedFileIDs: [UUID] = []
    var organizeFileLookup: [String: FileItem] = [:]
    var renameFileLookup: [String: FileItem] = [:]
    var lastStreamText = ""
    var isRenameOnly = false
}

struct RenameGenerationSequenceView: View {
    @SortyHotReload private var hotReload
    let events: [RenameStreamEvent]
    @State private var shouldFollowLatest = true

    private static let maxVisibleRows = 5
    private static let maxParseCharacters = 12_000
    private static let estimatedRowHeight: CGFloat = 44
    private static let rowSpacing: CGFloat = 8
    private static let headerHeight: CGFloat = 20
    private static let sectionSpacing: CGFloat = 14
    private static let verticalPadding: CGFloat = 32
    private static let progressRegex = try? NSRegularExpression(
        pattern: #">>\s*file:\s*(?:renam(?:e|ing)\s+)?([^"\n]+?)(?:\s*(?:->|→)\s*([^"\n]+))?$"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )
    private static let objectRegex = try? NSRegularExpression(
        pattern: #"\{[^{}]*"filename"\s*:\s*"([^"]+)"[^{}]*\}"#,
        options: []
    )
    private static let filenameRegex = try? NSRegularExpression(
        pattern: #""filename"\s*:\s*"([^"]+)""#,
        options: []
    )
    private static let suggestedNameRegex = try? NSRegularExpression(
        pattern: #""suggested_name"\s*:\s*"([^"]+)""#,
        options: []
    )
    private static let renameReasonRegex = try? NSRegularExpression(
        pattern: #""rename_reason"\s*:\s*"([^"]+)""#,
        options: []
    )

    private var visibleRowCount: Int {
        events.count
    }

    private var rowStackHeight: CGFloat {
        guard visibleRowCount > 0 else { return 0 }
        return CGFloat(visibleRowCount) * Self.estimatedRowHeight
            + CGFloat(max(visibleRowCount - 1, 0)) * Self.rowSpacing
    }

    private var panelHeight: CGFloat {
        Self.headerHeight + Self.sectionSpacing + rowStackHeight + Self.verticalPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                renameIcon
                Text("Renaming files")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            RenameGenerationEventList(events: events, shouldFollowLatest: $shouldFollowLatest)
            .frame(height: rowStackHeight)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: activeEventID)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 720)
        .frame(height: panelHeight, alignment: .top)
        .systemLiquidGlassBackground(cornerRadius: 14, interactive: false)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: visibleRowCount)
    }

    @ViewBuilder
    private var renameIcon: some View {
        if #available(macOS 26.0, *) {
            Image(systemName: "pencil.and.scribble")
                .foregroundStyle(.purple)
                .symbolEffect(.drawOn, options: .repeating)
        } else {
            Image(systemName: "pencil.and.scribble")
                .foregroundStyle(.purple)
        }
    }

    private var activeEventID: String? {
        events.last?.id
    }

    static func makeEvents(from streamText: String, files: [FileItem]) -> [RenameStreamEvent] {
        makeEvents(from: streamText, filesByName: fileLookup(from: files))
    }

    static func makeEvents(from streamText: String, filesByName: [String: FileItem]) -> [RenameStreamEvent] {
        let parsed = Self.parseRenameEvents(from: streamText)
        let visibleEvents = Array(parsed.suffix(Self.maxVisibleRows))

        return visibleEvents.map { event in
            guard let file = filesByName[Self.normalizedFileName(event.originalName)] else {
                return event
            }
            return RenameStreamEvent(
                id: event.id,
                originalName: event.originalName,
                suggestedName: event.suggestedName,
                reason: event.reason,
                filePath: file.path,
                isDirectory: file.isDirectory
            )
        }
    }

    private static func parseRenameEvents(from streamText: String) -> [RenameStreamEvent] {
        var eventsByOriginal: [String: RenameStreamEvent] = [:]
        var orderedKeys: [String] = []
        let parseText: String

        if streamText.count > maxParseCharacters {
            let start = streamText.index(streamText.endIndex, offsetBy: -maxParseCharacters)
            parseText = String(streamText[start...])
        } else {
            parseText = streamText
        }

        func upsert(originalName: String, suggestedName: String?, reason: String? = nil) {
            let key = originalName.lowercased()
            if !orderedKeys.contains(key) {
                orderedKeys.append(key)
            }
            let existing = eventsByOriginal[key]
            eventsByOriginal[key] = RenameStreamEvent(
                id: key,
                originalName: originalName,
                suggestedName: suggestedName ?? existing?.suggestedName,
                reason: reason ?? existing?.reason,
                filePath: existing?.filePath,
                isDirectory: existing?.isDirectory ?? false
            )
        }

        for match in Self.matches(regex: progressRegex, text: parseText) {
            let original = (match.indices.contains(1) ? match[1] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suggested = (match.indices.contains(2) ? match[2] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, !original.localizedCaseInsensitiveContains("ready to output") else { continue }
            upsert(originalName: original, suggestedName: suggested.isEmpty ? nil : suggested)
        }

        for match in Self.matches(regex: objectRegex, text: parseText) {
            let object = match.first ?? ""
            let original = Self.firstCapture(regex: filenameRegex, text: object)
            let suggested = Self.firstCapture(regex: suggestedNameRegex, text: object)
            let reason = Self.firstCapture(regex: renameReasonRegex, text: object)
            guard !original.isEmpty else { continue }
            upsert(originalName: original, suggestedName: suggested.isEmpty ? original : suggested, reason: reason)
        }

        return orderedKeys.compactMap { eventsByOriginal[$0] }
    }

    static func fileLookup(from files: [FileItem]) -> [String: FileItem] {
        var lookup: [String: FileItem] = [:]
        lookup.reserveCapacity(files.count * 3)
        for file in files {
            for key in [
                normalizedFileName(file.displayName),
                normalizedFileName(file.path),
                normalizedFileName(file.name)
            ] where !key.isEmpty {
                lookup[key] = file
            }
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

    private static func matches(regex: NSRegularExpression?, text: String) -> [[String]] {
        guard let regex else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).map { result in
            (0..<result.numberOfRanges).map { index in
                let range = result.range(at: index)
                guard range.location != NSNotFound else { return "" }
                return nsText.substring(with: range)
            }
        }
    }

    private static func firstCapture(regex: NSRegularExpression?, text: String) -> String {
        matches(regex: regex, text: text).first.flatMap {
            $0.indices.contains(1) ? $0[1] : nil
        } ?? ""
    }
}

private struct RenameGenerationEventList: View {
    let events: [RenameStreamEvent]
    @Binding var shouldFollowLatest: Bool

    private var indexedEvents: [(offset: Int, element: RenameStreamEvent)] {
        Array(events.enumerated())
    }

    private var activeEventID: String? { events.last?.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(indexedEvents, id: \.element.id) { index, event in
                        RenameGenerationRow(
                            originalName: event.originalName,
                            suggestedName: event.suggestedName,
                            filePath: event.filePath,
                            isDirectory: event.isDirectory,
                            isActive: activeEventID == event.id,
                            isRevealed: event.isRevealed,
                            isMostRecent: index == events.indices.last
                        )
                        .id(event.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.vertical, 1)
            }
            .onHover { hovering in
                shouldFollowLatest = !hovering
            }
            .onChange(of: activeEventID) { _, id in
                guard shouldFollowLatest, let id else { return }
                withAnimation(.smooth(duration: 0.24)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}

private struct RenameGenerationRow: View {
    @SortyHotReload private var hotReload
    let originalName: String
    let suggestedName: String?
    let filePath: String?
    let isDirectory: Bool
    let isActive: Bool
    let isRevealed: Bool
    let isMostRecent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var suggestedNameReveal = false

    var body: some View {
        let finalName = suggestedName ?? originalName
        let isUnchanged = isRevealed && finalName == originalName

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                RenameFileIcon(filePath: filePath, isDirectory: isDirectory, isUnchanged: isUnchanged)

                RenameNamePill(
                    text: originalName,
                    isPrimary: false,
                    isStruck: isRevealed && !isUnchanged,
                    isShimmering: isActive && !isRevealed
                )

                RenameShiftIndicator(isActive: isActive, isUnchanged: isUnchanged, isMostRecent: isMostRecent)

                RenameNamePill(
                    text: isRevealed ? finalName : "Waiting for suggested name...",
                    isPrimary: isRevealed,
                    isStruck: false,
                    showRevealSweep: suggestedNameReveal && isRevealed
                )
                .opacity(isRevealed ? (suggestedNameReveal ? 1 : 0) : 0.62)
                .offset(x: reduceMotion ? 0 : (suggestedNameReveal ? 0 : -8))
                .scaleEffect(isRevealed ? 1 : 0.985)
                .animation(.easeInOut(duration: 0.18), value: isRevealed)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: suggestedNameReveal)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.purple.opacity(0.08) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isMostRecent && isRevealed ? Color.purple.opacity(0.24) : .clear, lineWidth: 1)
        )
        .compositingGroup()
        .onAppear {
            revealSuggestedNameIfNeeded()
        }
        .onChange(of: suggestedName) { _, _ in
            revealSuggestedNameIfNeeded()
        }
        .onChange(of: isRevealed) { _, _ in
            revealSuggestedNameIfNeeded()
        }
    }

    private func revealSuggestedNameIfNeeded() {
        guard isRevealed else {
            suggestedNameReveal = false
            return
        }
        guard !reduceMotion else {
            suggestedNameReveal = true
            return
        }

        suggestedNameReveal = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                suggestedNameReveal = true
            }
        }
    }
}

private struct RenameNamePill: View {
    @SortyHotReload private var hotReload
    let text: String
    let isPrimary: Bool
    let isStruck: Bool
    var isShimmering = false
    var showRevealSweep = false

    var body: some View {
        Text(text)
            .font(.caption.weight(isPrimary ? .semibold : .regular))
            .foregroundStyle(isPrimary ? Color.purple : Color.secondary)
            .lineLimit(1)
            .strikethrough(isStruck, color: .secondary)
            .numericTextTransition(
                animationValue: text,
                animation: .easeInOut(duration: 0.28)
            )
            .textShimmer(isLoading: isShimmering, phaseOffset: 0.12, intensity: 1.18)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isPrimary ? Color.purple.opacity(0.08) : Color.secondary.opacity(0.06))
            )
            .overlay(alignment: .leading) {
                if showRevealSweep {
                    RenameGenerationRevealSweep()
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Waveform icon whose repeating breathe is gated on Reduce Motion and
/// window activation instead of running unconditionally.
struct BreatheWaveformIcon: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Image(systemName: "waveform")
            .font(.callout)
            .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
            .symbolEffect(
                .breathe,
                options: reduceMotion || controlActiveState == .inactive ? .nonRepeating : .repeating
            )
    }
}

private struct RenameGenerationRevealSweep: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var progress: CGFloat = -0.35

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            LinearGradient(
                colors: [
                    .clear,
                    .white.opacity(0.22),
                    Color.purple.opacity(0.17),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(width * 0.26, 22), height: geometry.size.height * 1.8)
            .blur(radius: reduceTransparency ? 0 : 2.2)
            .offset(x: width * progress)
            .blendMode(.plusLighter)
            .onAppear {
                progress = -0.35
                withAnimation(.easeOut(duration: 0.58)) {
                    progress = 1.12
                }
            }
        }
        .clipped()
    }
}

private struct RenameFileIcon: View {
    @SortyHotReload private var hotReload
    let filePath: String?
    let isDirectory: Bool
    let isUnchanged: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let filePath {
                let url = URL(fileURLWithPath: filePath)
                if isDirectory {
                    FolderThumbnailView(url: url, size: CGSize(width: 22, height: 22))
                } else {
                    FileThumbnailView(url: url, size: CGSize(width: 22, height: 22))
                }
            } else {
                AppKitImageView(
                    image: AnalysisIconProvider.icon(for: .data),
                    size: CGSize(width: 22, height: 22),
                    opacity: 0.72
                )
                .frame(width: 22, height: 22)
            }

            Image(systemName: isUnchanged ? "equal.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isUnchanged ? Color.secondary : Color.green)
                .symbolReplaceTransition(animationValue: isUnchanged)
                .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                .offset(x: 3, y: 3)
        }
        .frame(width: 28, height: 24)
    }
}

private struct RenameShiftIndicator: View {
    @SortyHotReload private var hotReload
    let isActive: Bool
    let isUnchanged: Bool
    /// Only the most-recent row pulses; older rows render static so a long
    /// stream does not accumulate one repeatForever each.
    var isMostRecent = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var shouldPulse: Bool {
        isActive && isMostRecent && !reduceMotion
    }

    var body: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 16, height: 2)

            Image(systemName: isUnchanged ? "equal" : "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isUnchanged ? Color.secondary : Color.purple)
                .symbolReplaceTransition(animationValue: isUnchanged)
                .scaleEffect(isActive && pulse ? 1.12 : 1)

            Capsule()
                .fill((isUnchanged ? Color.secondary : Color.purple).opacity(0.18))
                .frame(width: 16, height: 2)
        }
        .frame(width: 56)
        .onAppear {
            guard shouldPulse else { return }
            withAnimation(.smooth(duration: 0.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: isActive) { _, active in
            if active, shouldPulse {
                withAnimation(.smooth(duration: 0.5).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.smooth(duration: 0.2)) {
                    pulse = false
                }
            }
        }
        .onChange(of: isMostRecent) { _, _ in
            if shouldPulse {
                withAnimation(.smooth(duration: 0.5).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.smooth(duration: 0.2)) {
                    pulse = false
                }
            }
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            guard shouldReduceMotion else { return }
            withAnimation(nil) {
                pulse = false
            }
        }
    }
}

/// Mid-organization progress card using Beam's reference playground samples.
