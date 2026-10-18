import Foundation

/// Extracts JSON from free-form LLM output.
package enum LLMJSONExtractor {
    /// Last balanced top-level JSON object in the text.
    package static func lastObject(in text: String) -> String? {
        balancedSpans(in: text, open: "{", close: "}").last
    }

    /// All balanced top-level JSON objects in the text.
    package static func objectCandidates(in text: String) -> [String] {
        balancedSpans(in: text, open: "{", close: "}")
    }

    /// First balanced JSON array in the text.
    package static func firstArray(in text: String) -> String? {
        balancedSpans(in: text, open: "[", close: "]").first
    }

    private static func balancedSpans(in text: String, open: Character, close: Character) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var start: String.Index?
        var isInsideString = false
        var isEscaping = false

        for index in text.indices {
            let character = text[index]

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
            } else if character == open {
                if depth == 0 {
                    start = index
                }
                depth += 1
            } else if character == close, depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    candidates.append(String(text[start...index]))
                }
            }
        }

        return candidates
    }
}
