//
//  PrivacySensitivePathText.swift
//  Sorty
//

import SwiftUI

/// Displays paths while blurring only username path segments (for example `/Users/<name>/...`).
package struct PrivacySensitivePathText: View {
    @SortyHotReload private var hotReload
    let path: String
    var blurRadius: CGFloat = 10
    var revealOnHover: Bool = true
    var revealOnClick: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringUsername = false
    @State private var isClickRevealed = false

    package init(
        path: String,
        blurRadius: CGFloat = 10,
        revealOnHover: Bool = true,
        revealOnClick: Bool = true
    ) {
        self.path = path
        self.blurRadius = blurRadius
        self.revealOnHover = revealOnHover
        self.revealOnClick = revealOnClick
    }

    private var isPrivacyEnabled: Bool {
        FeatureFlags.privacyModeEnabled
    }

    private var revealAnimation: Animation {
        isRevealed
            ? .timingCurve(0.2, 0.95, 0.2, 1.0, duration: 0.38)
            : .easeInOut(duration: 0.26)
    }

    private var isRevealed: Bool {
        isHoveringUsername || isClickRevealed
    }

    package var body: some View {
        if isPrivacyEnabled, let segments = PrivacyPathMasker.userPathSegments(in: path) {
            HStack(spacing: 0) {
                Text(segments.leading)
                ZStack {
                    Text(segments.username)
                        .opacity(isRevealed ? 0 : 1)
                        .blur(radius: blurRadius)

                    Text(segments.username)
                        .opacity(isRevealed ? 1 : 0)
                }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .clipShape(Capsule())
                    .padding(.vertical, -4)
                    .padding(.horizontal, -6)
                    .onChange(of: revealOnHover) { _, _ in
                        if !revealOnHover {
                            isHoveringUsername = false
                        }
                    }
                    .animation(reduceMotion ? nil : revealAnimation, value: isRevealed)
                    .onHover { hovering in
                        guard revealOnHover else { return }
                        guard hovering != isHoveringUsername else { return }
                        isHoveringUsername = hovering
                        HapticFeedbackManager.shared.light()
                    }
                    .onTapGesture {
                        guard revealOnClick else { return }
                        isClickRevealed.toggle()
                    }
                Text(segments.trailing)
            }
            .accessibilityLabel(PrivacyPathMasker.redactedPath(path))
            .accessibilityValue(isRevealed ? "Username visible" : "Username hidden")
            .accessibilityActions {
                if revealOnClick {
                    Button(isClickRevealed ? "Hide username" : "Reveal username") {
                        isClickRevealed.toggle()
                    }
                }
            }
        } else {
            Text(path)
        }
    }
}

package enum PrivacyPathMasker {
    package struct Segments {
        package let leading: String
        package let username: String
        package let trailing: String
    }

    package static func userPathSegments(in text: String, currentUsername: String = NSUserName()) -> Segments? {
        if let segments = usersDirectorySegments(in: text) {
            return segments
        }

        return currentUserSegments(in: text, currentUsername: currentUsername)
    }

    private static func usersDirectorySegments(in text: String) -> Segments? {
        let marker = "/Users/"
        guard let markerRange = text.range(of: marker, options: [.caseInsensitive]) else { return nil }

        let usernameStart = markerRange.upperBound
        guard usernameStart < text.endIndex else { return nil }

        let remainder = text[usernameStart...]
        let usernameEnd = remainder.firstIndex(of: "/") ?? text.endIndex
        guard usernameStart < usernameEnd else { return nil }

        let username = String(text[usernameStart..<usernameEnd])
        guard !username.isEmpty else { return nil }

        let leading = String(text[..<usernameStart])
        let trailing = String(text[usernameEnd...])
        return Segments(leading: leading, username: username, trailing: trailing)
    }

    private static func currentUserSegments(in text: String, currentUsername: String) -> Segments? {
        let username = currentUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return nil }
        guard let usernameRange = text.range(of: username, options: [.caseInsensitive]) else { return nil }

        if !isPathSegmentBoundary(in: text, for: usernameRange) {
            return nil
        }

        let leading = String(text[..<usernameRange.lowerBound])
        let trailing = String(text[usernameRange.upperBound...])
        return Segments(leading: leading, username: String(text[usernameRange]), trailing: trailing)
    }

    private static func isPathSegmentBoundary(in text: String, for range: Range<String.Index>) -> Bool {
        let validBoundaryCharacters = CharacterSet(charactersIn: "/\\")

        let startsAtBoundary: Bool = {
            guard range.lowerBound > text.startIndex else { return true }
            let before = text[text.index(before: range.lowerBound)]
            return String(before).rangeOfCharacter(from: validBoundaryCharacters) != nil
        }()

        let endsAtBoundary: Bool = {
            guard range.upperBound < text.endIndex else { return true }
            let after = text[range.upperBound]
            return String(after).rangeOfCharacter(from: validBoundaryCharacters) != nil
        }()

        return startsAtBoundary && endsAtBoundary
    }

    package static func redactedPath(_ text: String) -> String {
        redactedText(text)
    }

    package static func redactedText(_ text: String, currentUsername: String = NSUserName()) -> String {
        guard !text.isEmpty else { return text }

        var redacted = redactUsersDirectoryUsernames(in: text)
        redacted = redactCurrentUsernameSegments(in: redacted, currentUsername: currentUsername)
        return redacted
    }

    private static func redactUsersDirectoryUsernames(in text: String) -> String {
        let pattern = #"(?i)(/Users/)([^/\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1[REDACTED_USER]")
    }

    private static func redactCurrentUsernameSegments(in text: String, currentUsername: String) -> String {
        var redacted = text
        for _ in 0..<24 {
            guard let segments = currentUserSegments(in: redacted, currentUsername: currentUsername) else {
                break
            }
            redacted = segments.leading + "[REDACTED_USER]" + segments.trailing
        }
        return redacted
    }
}
