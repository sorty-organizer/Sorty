import Foundation
import AppKit
import SwiftUI

struct InstructionMentionQuery: Equatable {
    let range: Range<String.Index>
    let nsRange: NSRange
    let query: String

    static func active(in text: String, selectedRange: NSRange) -> InstructionMentionQuery? {
        guard selectedRange.length == 0 else { return nil }
        guard selectedRange.location <= (text as NSString).length else { return nil }
        let cursor = String.Index(utf16Offset: selectedRange.location, in: text)
        let prefix = text[..<cursor]
        guard let atIndex = prefix.lastIndex(of: "@") else { return nil }
        let afterAt = text.index(after: atIndex)
        let query = String(text[afterAt..<cursor])

        guard !query.contains(where: \.isNewline) else { return nil }
        guard query.rangeOfCharacter(from: CharacterSet(charactersIn: ",;()[]{}")) == nil else { return nil }
        guard query.count <= 80 else { return nil }
        if let characterBeforeAt = text[..<atIndex].last,
           !characterBeforeAt.isWhitespace,
           !",;([{".contains(characterBeforeAt) {
            return nil
        }

        let range = atIndex..<cursor
        return InstructionMentionQuery(
            range: range,
            nsRange: NSRange(range, in: text),
            query: query
        )
    }
}

struct InstructionFileReference: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let relativePath: String
    let fileSize: Int?

    init(url: URL, baseDirectory: URL, fileSize: Int?) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.fileSize = fileSize

        let basePath = baseDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            self.relativePath = String(path.dropFirst(basePath.count + 1))
        } else {
            self.relativePath = url.lastPathComponent
        }
    }

    var displayToken: String {
        let token = relativePath
        return token.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;()[]{}"))) == nil ? token : "\"\(token)\""
    }

    var subtitle: String {
        let folder = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
        if folder == "." || folder == "/" || folder.isEmpty {
            return formattedSize
        }
        return "\(folder) • \(formattedSize)"
    }

    private var formattedSize: String {
        guard let fileSize else { return "File" }
        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

struct InstructionFileReferencePicker: View {
    @SortyHotReload private var hotReload
    let matches: [InstructionFileReference]
    let query: String
    let onSelect: (InstructionFileReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                Text("Reference a file")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↩ to insert")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            ForEach(matches) { reference in
                Button {
                    onSelect(reference)
                } label: {
                    HStack(spacing: 10) {
                        FileThumbnailView(url: reference.url, size: CGSize(width: 24, height: 24))
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            highlightedName(reference.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)

                            Text(reference.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if !reference.url.pathExtension.isEmpty {
                            Text(".\(reference.url.pathExtension)")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.teal.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reference \(reference.name)")
                .accessibilityHint("Adds this file reference to the instructions")
            }
        }
        .padding(6)
        .frame(width: 360)
        .systemLiquidGlassPopover(cornerRadius: 12)
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 10)
    }

    private func highlightedName(_ name: String) -> Text {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              let range = name.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(name)
        }

        let prefix = String(name[..<range.lowerBound])
        let match = String(name[range])
        let suffix = String(name[range.upperBound...])
        return Text(prefix) + Text(match).foregroundStyle(.teal) + Text(suffix)
    }
}
