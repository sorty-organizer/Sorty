import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

