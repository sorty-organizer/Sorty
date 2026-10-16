import Foundation

@MainActor func fuzzJSONExtractor(seed: UInt64, iterations: Int) -> Int {
    var generator = Generator(state: seed)
    var failedChecks = 0
    var failures: Set<String> = []
    var cases = 0

    func check(_ condition: Bool, _ property: String, input: String) {
        guard !condition else { return }
        failedChecks += 1
        if failures.insert(property).inserted {
            print("FAIL JSON extractor \(property) case=\(cases) input=\(String(reflecting: input))")
        }
    }

    for input in ["] [", "} {", "prefix ] noise [ suffix", "prefix } noise { suffix"] {
        cases += 1
        check(LLMJSONExtractor.fencedOrBracketedJSON(from: input) == input, "reversed delimiters stay unchanged", input: input)
    }

    let atoms = ["text", "\"", "\\", "{", "}", "[", "]", "\n", "\0", "é", "😀", "```"]
    for _ in 0..<max(iterations, 1) {
        var content = ""
        for _ in 0..<generator.next(40) { content += atoms[generator.next(atoms.count)] }
        let json = String(data: try! JSONSerialization.data(withJSONObject: ["content": content, "number": generator.next(1000)], options: [.sortedKeys]), encoding: .utf8)!
        let wrapped = "preface\n" + json + "\nend"
        cases += 1
        check(LLMJSONExtractor.objectCandidates(in: wrapped) == [json], "quoted delimiters do not split objects", input: wrapped)
        check(LLMJSONExtractor.lastObject(in: wrapped + "\n{}") == "{}", "last object wins", input: wrapped)
        let array = "[\(json)]"
        check(LLMJSONExtractor.firstArray(in: "preface\n\(array)\n[]") == array, "first array retains nested strings", input: array)
        check(LLMJSONExtractor.fencedOrBracketedJSON(from: "```json\n\(json)\n```") == json, "fenced JSON is retained", input: json)
    }
    print("JSON extractor seed=\(seed) cases=\(cases) failedChecks=\(failedChecks) propertiesFailed=\(failures.count)")
    return failedChecks
}
