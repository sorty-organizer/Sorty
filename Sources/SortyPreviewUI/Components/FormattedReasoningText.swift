//
//  FormattedReasoningText.swift
//  Sorty
//
//  Rich formatting for AI reasoning text with support for markdown-style content.
//

import SwiftUI

package struct FormattedReasoningText: View {
    @SortyHotReload private var hotReload
    let text: String
    var font: Font = .callout
    var secondaryFont: Font = .caption
    var foregroundStyle: Color = .primary
    var showSectionIcons: Bool = true

    package init(
        text: String,
        font: Font = .callout,
        secondaryFont: Font = .caption,
        foregroundStyle: Color = .primary,
        showSectionIcons: Bool = true
    ) {
        self.text = text
        self.font = font
        self.secondaryFont = secondaryFont
        self.foregroundStyle = foregroundStyle
        self.showSectionIcons = showSectionIcons
    }

    private var displayText: String {
        FeatureFlags.privacyModeEnabled ? PrivacyPathMasker.redactedText(text) : text
    }

    private var segments: [ReasoningSegment] {
        parseReasoning(displayText)
    }

    package var body: some View {
        let renderedSegments = segments

        if renderedSegments.count <= 1 {
            attributedText(displayText, font: font)
                .foregroundStyle(foregroundStyle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(renderedSegments.indices, id: \.self) { index in
                    segmentView(renderedSegments[index])
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ReasoningSegment) -> some View {
        switch segment.kind {
        case .header(let level):
            HStack(spacing: 5) {
                if showSectionIcons, let icon = segment.icon {
                    Image(systemName: icon)
                        .font(.system(size: level == 1 ? 11 : 10, weight: .semibold))
                        .foregroundStyle(segment.iconColor ?? .purple)
                }
                attributedText(segment.text, font: level == 1 ? font.weight(.bold) : secondaryFont.weight(.semibold))
                    .foregroundStyle(foregroundStyle)
            }
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(Color.purple.opacity(0.5))
                    .frame(width: 4, height: 4)
                    .padding(.top, 4)
                attributedText(segment.text, font: secondaryFont)
                    .foregroundStyle(foregroundStyle.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        case .numbered(let n):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.purple.opacity(0.7))
                    .frame(width: 16, alignment: .trailing)
                attributedText(segment.text, font: secondaryFont)
                    .foregroundStyle(foregroundStyle.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        case .paragraph:
            attributedText(segment.text, font: secondaryFont)
                .foregroundStyle(foregroundStyle.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func attributedText(_ raw: String, font: Font) -> some View {
        if let attributed = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(font)
        } else {
            Text(raw)
                .font(font)
        }
    }
}

// MARK: - Parsing

private struct ReasoningSegment {
    let kind: Kind
    let text: String
    let icon: String?
    let iconColor: Color?

    enum Kind: Equatable {
        case header(level: Int)
        case bullet
        case numbered(Int)
        case paragraph
    }

    init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
        self.icon = Self.inferIcon(text)
        self.iconColor = Self.inferColor(text)
    }

    private static func inferIcon(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("pattern") { return "circle.grid.3x3" }
        if lower.contains("semantic") || lower.contains("grouping") || lower.contains("relationship") { return "link" }
        if lower.contains("alternative") || lower.contains("considered") || lower.contains("rejected") { return "arrow.triangle.branch" }
        if lower.contains("benefit") || lower.contains("workflow") || lower.contains("findability") { return "sparkles" }
        if lower.contains("decision") || lower.contains("chose") || lower.contains("reason") { return "brain" }
        return nil
    }

    private static func inferColor(_ text: String) -> Color? {
        let lower = text.lowercased()
        if lower.contains("pattern") { return .blue }
        if lower.contains("semantic") || lower.contains("grouping") { return .teal }
        if lower.contains("alternative") { return .orange }
        if lower.contains("benefit") || lower.contains("workflow") { return .green }
        return .purple
    }
}

private func parseReasoning(_ text: String) -> [ReasoningSegment] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let lines = trimmed.components(separatedBy: .newlines)
    var segments: [ReasoningSegment] = []
    var paragraphBuffer = ""

    func flushParagraph() {
        let t = paragraphBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            segments.append(ReasoningSegment(kind: .paragraph, text: t))
        }
        paragraphBuffer = ""
    }

    for line in lines {
        let stripped = line.trimmingCharacters(in: .whitespaces)

        if stripped.isEmpty {
            flushParagraph()
            continue
        }

        if stripped.hasPrefix("### ") {
            flushParagraph()
            segments.append(ReasoningSegment(kind: .header(level: 2), text: String(stripped.dropFirst(4))))
        } else if stripped.hasPrefix("## ") {
            flushParagraph()
            segments.append(ReasoningSegment(kind: .header(level: 1), text: String(stripped.dropFirst(3))))
        } else if stripped.hasPrefix("# ") {
            flushParagraph()
            segments.append(ReasoningSegment(kind: .header(level: 1), text: String(stripped.dropFirst(2))))
        } else if stripped.hasPrefix("- ") || stripped.hasPrefix("• ") || stripped.hasPrefix("* ") {
            flushParagraph()
            segments.append(ReasoningSegment(kind: .bullet, text: String(stripped.dropFirst(2))))
        } else if let match = stripped.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) {
            flushParagraph()
            let numberStr = stripped[stripped.startIndex..<stripped.index(before: match.upperBound)]
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            let number = Int(numberStr) ?? 1
            let content = String(stripped[match.upperBound...])
            segments.append(ReasoningSegment(kind: .numbered(number), text: content))
        } else if let colonIdx = stripped.firstIndex(of: ":"),
                  stripped.distance(from: stripped.startIndex, to: colonIdx) <= 30,
                  stripped[stripped.startIndex..<colonIdx].allSatisfy({ $0.isLetter || $0.isWhitespace || $0 == "*" }) {
            let label = stripped[stripped.startIndex..<colonIdx]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
            let value = stripped[stripped.index(after: colonIdx)...]
                .trimmingCharacters(in: .whitespaces)

            if !label.isEmpty && !value.isEmpty && label.count <= 28 {
                flushParagraph()
                segments.append(ReasoningSegment(kind: .header(level: 2), text: label))
                segments.append(ReasoningSegment(kind: .paragraph, text: value))
            } else {
                if !paragraphBuffer.isEmpty { paragraphBuffer += " " }
                paragraphBuffer += stripped
            }
        } else {
            if !paragraphBuffer.isEmpty { paragraphBuffer += " " }
            paragraphBuffer += stripped
        }
    }

    flushParagraph()

    if segments.count == 1, case .paragraph = segments[0].kind {
        return splitSentences(segments[0].text)
    }

    return segments
}

private func splitSentences(_ text: String) -> [ReasoningSegment] {
    let sentences = text.components(separatedBy: ". ")
    guard sentences.count >= 3 else {
        return [ReasoningSegment(kind: .paragraph, text: text)]
    }

    return sentences.enumerated().map { idx, sentence in
        let cleaned = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let withPeriod = cleaned.hasSuffix(".") ? cleaned : cleaned + "."
        return ReasoningSegment(kind: .numbered(idx + 1), text: withPeriod)
    }
}

// MARK: - Previews

#Preview("Formatted Reasoning - Multi-sentence") {
    FormattedReasoningText(
        text: "These invoice PDFs share a consistent naming pattern with vendor prefixes (AWS_, GCP_, Azure_) and date suffixes. They're grouped under 'Cloud Services/Invoices' rather than just 'Documents' because the user clearly manages multiple cloud accounts. I considered grouping by date but the vendor-based organization provides faster lookup when reconciling specific provider bills."
    )
    .padding()
    .frame(width: 340)
}

#Preview("Formatted Reasoning - Bullet Points") {
    FormattedReasoningText(
        text: """
        ## Organization Strategy
        - Pattern Recognition: Files share .pdf extension and invoice naming
        - Semantic Grouping: All related to cloud infrastructure billing
        - Alternative Consideration: Date-based grouping was considered but rejected
        - User Benefit: Faster vendor-specific bill reconciliation
        """
    )
    .padding()
    .frame(width: 340)
}

#Preview("Formatted Reasoning - Short") {
    FormattedReasoningText(
        text: "Image files grouped together by type."
    )
    .padding()
    .frame(width: 340)
}
