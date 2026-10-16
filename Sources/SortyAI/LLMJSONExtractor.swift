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

    /// Rule-induction responses: a ```json fenced block if present (trimmed),
    /// else the first "[" through last "]", else the first "{" through last "}"
    /// wrapped as a one-element array, else the text unchanged.
    package static func fencedOrBracketedJSON(from text: String) -> String {
        // 1. Try to find JSON markdown blocks: ```json ... ``` or ``` ... ```
        if let startRange = text.range(of: "```json"),
           let endRange = text.range(of: "```", options: .backwards, range: startRange.upperBound..<text.endIndex) {
            let content = text[startRange.upperBound..<endRange.lowerBound]
            return String(content).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let startRange = text.range(of: "```"),
                  let endRange = text.range(of: "```", options: .backwards, range: startRange.upperBound..<text.endIndex) {
            let content = text[startRange.upperBound..<endRange.lowerBound]
            return String(content).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Fallback: Find the first '[' and last ']' for array response
        if let startRange = text.range(of: "["),
           let endRange = text.range(of: "]", options: .backwards, range: startRange.upperBound..<text.endIndex) {
            let range = startRange.lowerBound..<endRange.upperBound
            return String(text[range])
        }

        // 3. Fallback: Find the first '{' and last '}' for single object response
        if let startRange = text.range(of: "{"),
           let endRange = text.range(of: "}", options: .backwards, range: startRange.upperBound..<text.endIndex) {
            let range = startRange.lowerBound..<endRange.upperBound
            let objectJson = String(text[range])
            // If we found an object but expected an array, wrap it in brackets for the decoder
            return "[\(objectJson)]"
        }

        return text
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
