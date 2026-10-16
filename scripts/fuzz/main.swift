import Foundation
import SortyFileSystem

// SplitMix64 keeps a reported seed reproducible across Swift versions.
struct Generator {
    var state: UInt64

    mutating func next(_ upperBound: Int) -> Int {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Int((value ^ (value >> 31)) % UInt64(upperBound))
    }
}

struct FilenameCase: Codable {
    var name: String
    var ext: String
    var enforce: Bool
}

let arguments = Array(CommandLine.arguments.dropFirst())
func usage() -> Never {
    print("Usage: bash scripts/fuzz.sh [--seed UINT64] [--iterations 0...10000000]")
    exit(2)
}
var seed: UInt64 = 0x534f525459
var iterations = 10_000
var index = 0
while index < arguments.count {
    guard index + 1 < arguments.count else { usage() }
    switch arguments[index] {
    case "--seed":
        guard let value = UInt64(arguments[index + 1]) else { usage() }
        seed = value
    case "--iterations":
        guard let value = Int(arguments[index + 1]), (0...10_000_000).contains(value) else { usage() }
        iterations = value
    default: usage()
    }
    index += 2
}

let atoms = ["a", "Z", "0", ".", " ", "\t", "\n", "/", "\\", ":", "\0", "é", "e\u{301}", "😀", "👨‍👩‍👧‍👦", "\u{301}", "\u{200d}"]
let extensions = ["", "txt", "PDF", "tar.gz", "a/b", "a:b", "a\\b", "a\0b", " .txt. ", String(repeating: "e", count: 260)]
let names = ["", ".", "..", ".pdf", "report.txt", "report .txt", "a..txt", " . .txt", "a.b\nc", String(repeating: "a", count: 260), String(repeating: "😀", count: 70), "a" + String(repeating: "\u{301}", count: 260)]
var generator = Generator(state: seed)
var failures: Set<String> = []
var failedCases = 0
var checkedCases = 0
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

@MainActor func check(_ condition: Bool, _ property: String, input: FilenameCase, output: String?) {
    guard !condition else { return }
    failedCases += 1
    if failures.insert(property).inserted {
        let json = String(data: try! encoder.encode(input), encoding: .utf8)!
        print("FAIL \(property) case=\(checkedCases) input=\(json) output=\(String(reflecting: output))")
    }
}

@MainActor func checkFilename(_ input: FilenameCase) {
    checkedCases += 1
    let result = FilenameSanitizer.sanitize(input.name, preservingExtension: input.ext, enforceExtension: input.enforce)
    if ["", ".", "..", ".pdf"].contains(input.name) {
        check(result.sanitizedName == nil, "reject empty and reserved names", input: input, output: result.sanitizedName)
    }
    guard let name = result.sanitizedName else { return }
    check(result.isValid && !name.isEmpty && name != "." && name != "..", "valid component", input: input, output: name)
    check(!name.unicodeScalars.contains { CharacterSet(charactersIn: ":/\\\0").contains($0) }, "no path separators or NUL", input: input, output: name)
    check(name.utf8.count <= 255, "255-byte limit", input: input, output: name)
    let repeated = FilenameSanitizer.sanitize(name, preservingExtension: input.ext, enforceExtension: input.enforce)
    check(repeated.sanitizedName == name, "sanitization is stable", input: input, output: name)
    // Safe ordinary extensions must survive even when the basename is truncated.
    if input.enforce && ["txt", "PDF", "tar.gz"].contains(input.ext) {
        check(name.lowercased().hasSuffix(".\(input.ext.lowercased())"), "preserve extension", input: input, output: name)
        check(!(name as NSString).deletingPathExtension.isEmpty && !name.hasPrefix("."), "retain basename", input: input, output: name)
    }
}

// The cross-product runs even with --iterations 0, preserving discovered edge cases.
for name in names {
    for ext in extensions {
        for enforce in [false, true] {
            checkFilename(FilenameCase(name: name, ext: ext, enforce: enforce))
        }
    }
}
for _ in 0..<iterations {
    var name = names[generator.next(names.count)]
    for _ in 0..<generator.next(12) {
        let atom = atoms[generator.next(atoms.count)]
        switch generator.next(4) {
        case 0: name = atom + name
        case 1: name += atom
        case 2: name += String(repeating: atom, count: generator.next(300))
        default: if !name.isEmpty { name.removeLast() }
        }
    }
    checkFilename(FilenameCase(name: name, ext: extensions[generator.next(extensions.count)], enforce: generator.next(2) == 0))

    // An implementation that rejects every input must not pass the safety checks.
    let safeName = ["report", "Résumé", "レポート", "👨‍👩‍👧‍👦"][generator.next(4)] + "_\(generator.next(10000)).txt"
    let safeResult = FilenameSanitizer.sanitize(safeName, preservingExtension: "txt")
    check(safeResult.sanitizedName == safeName, "accept safe Unicode names unchanged", input: FilenameCase(name: safeName, ext: "txt", enforce: true), output: safeResult.sanitizedName)

    // Compare containment against URL path components, independently of prefix matching.
    let parent = "/sorty-fuzz/" + ["a", "ab", "é", "😀"][generator.next(4)]
    let child = parent + ["/file", "bc/file", "/../outside", "/./nested", "", "/nested/../../outside"][generator.next(6)]
    let parentParts = URL(fileURLWithPath: parent).standardizedFileURL.pathComponents
    let childParts = URL(fileURLWithPath: child).standardizedFileURL.pathComponents
    let expected = childParts.starts(with: parentParts)
    check(StorageLocationPathResolver.isPath(child, within: parent) == expected, "path containment", input: FilenameCase(name: child, ext: parent, enforce: false), output: nil)

    // Literal replacements must match the standard-library contract, including Unicode.
    let pattern = atoms[generator.next(atoms.count)]
    let replacement = atoms[generator.next(atoms.count)]
    let actual = RenameRuleEngine.applyRules(to: name, rules: [RenameRule(pattern: pattern, replacement: replacement, isRegex: false)])
    check(actual == name.replacingOccurrences(of: pattern, with: replacement), "literal rename rule", input: FilenameCase(name: name, ext: pattern, enforce: false), output: actual)
    let invalidRegex = RenameRuleEngine.applyRules(to: name, rules: [RenameRule(pattern: "[", replacement: replacement)])
    check(invalidRegex == name, "invalid regex leaves name intact", input: FilenameCase(name: name, ext: "[", enforce: false), output: invalidRegex)
    let chained = RenameRuleEngine.applyRules(to: safeName, rules: [
        RenameRule(pattern: "^(.+)\\.txt$", replacement: "$1.pdf"),
        RenameRule(pattern: ".pdf", replacement: ".md", isRegex: false)
    ])
    check(chained == String(safeName.dropLast(4)) + ".md", "rename rules run in order with captures", input: FilenameCase(name: safeName, ext: "txt", enforce: false), output: chained)
}

print("seed=\(seed) iterations=\(iterations) filenameCases=\(checkedCases) failedChecks=\(failedCases) propertiesFailed=\(failures.count)")
let parserFailures = fuzzParser(seed: seed, iterations: iterations)
let extractorFailures = fuzzJSONExtractor(seed: seed, iterations: iterations)
if !failures.isEmpty || parserFailures > 0 || extractorFailures > 0 {
    print("Replay: bash scripts/fuzz.sh --seed \(seed) --iterations \(iterations)")
    exit(1)
}
