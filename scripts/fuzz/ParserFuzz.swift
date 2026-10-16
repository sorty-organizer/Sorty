import Foundation
import SortyModels

/// Exercises the production parser without network providers or filesystem mutations.
@MainActor func fuzzParser(seed: UInt64, iterations: Int) -> Int {
    var generator = Generator(state: seed)
    var failedChecks = 0
    var failures: Set<String> = []
    var cases = 0

    func check(_ condition: Bool, _ property: String, response: String) {
        guard !condition else { return }
        failedChecks += 1
        if failures.insert(property).inserted {
            print("FAIL parser \(property) case=\(cases) response=\(String(reflecting: response))")
        }
    }

    func allFiles(_ suggestions: [FolderSuggestion]) -> [FileItem] {
        suggestions.flatMap { $0.files + allFiles($0.subfolders) }
    }

    func verify(_ plan: OrganizationPlan, files: [FileItem], response: String) {
        let assigned = allFiles(plan.suggestions)
        let placements = assigned + plan.unorganizedFiles
        check(placements.count == files.count && Set(placements.map(\.id)) == Set(files.map(\.id)), "every input appears exactly once", response: response)
        check(plan.suggestions.allSatisfy { $0.fileRenameMappings.isEmpty }, "organize mode drops renames", response: response)
    }

    // Fixed cases run with --iterations 0; mutations vary inventory order and schema.
    for iteration in 0..<max(iterations, 1) {
        let stems = ["report", "Résumé", "レポート", "photo😀", "quoted\"name", "back\\slash", "line\nbreak"]
        let stem = stems[generator.next(stems.count)]
        let first = FileItem(path: "/fuzz/alpha/\(stem).pdf", relativePath: "alpha/\(stem).pdf", name: stem, extension: "pdf")
        let second = FileItem(path: "/fuzz/beta/\(stem).pdf", relativePath: "beta/\(stem).pdf", name: stem, extension: "pdf")
        let anchor = FileItem(path: "/fuzz/notes.txt", name: "notes", extension: "txt")
        let files = generator.next(2) == 0 ? [first, second, anchor] : [second, first, anchor]

        func payload(_ folder: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: ["folders": [folder]], options: [.sortedKeys]), encoding: .utf8)!
        }

        for target in [first, second] {
            for reference in [target.relativePath!, target.path, "./" + target.relativePath!, target.relativePath!.uppercased()] {
                let response = payload(["name": "Chosen", "files": [reference, "notes.txt"]])
                cases += 1
                if let plan = try? ResponseParser.parseResponse(response, originalFiles: files) {
                    verify(plan, files: files, response: response)
                    check(Set(allFiles(plan.suggestions).map(\.id)) == Set([target.id, anchor.id]), "qualified reference selects its own file", response: response)
                } else {
                    check(false, "valid qualified response is accepted", response: response)
                }
            }
        }

        let quotedReference = String(data: try! JSONEncoder().encode(second.relativePath!), encoding: .utf8)!
        let streamedName = "{\"folders\":[{\"name\":\"Chosen\",\"files\":[\(quotedReference),"
        cases += 1
        let recoveredName = ResponseParser.extractPartialResults(streamedName, originalFiles: files)
        check(recoveredName.map { allFiles($0.suggestions).map(\.id) == [second.id] } == true, "streaming filenames decode JSON escapes", response: streamedName)

        let ambiguous = payload(["name": "Chosen", "files": ["\(stem).pdf", "notes.txt"]])
        cases += 1
        if let plan = try? ResponseParser.parseResponse(ambiguous, originalFiles: files) {
            verify(plan, files: files, response: ambiguous)
            check(allFiles(plan.suggestions).map(\.id) == [anchor.id] && plan.isPartial && !plan.parseWarnings.isEmpty, "ambiguous basename stays unresolved", response: ambiguous)
        } else {
            check(false, "usable anchor survives ambiguity", response: ambiguous)
        }

        let extensionless = FileItem(path: "/fuzz/\(stem)", name: stem)
        let stemCollisionFiles = [first, extensionless, anchor]
        let stemCollision = payload(["name": "Chosen", "files": [stem, "notes.txt"]])
        cases += 1
        if let plan = try? ResponseParser.parseResponse(stemCollision, originalFiles: stemCollisionFiles) {
            verify(plan, files: stemCollisionFiles, response: stemCollision)
            check(Set(allFiles(plan.suggestions).map(\.id)) == Set([extensionless.id, anchor.id]), "exact filename wins over another file's stem", response: stemCollision)
        } else {
            check(false, "exact extensionless filename is accepted", response: stemCollision)
        }

        // Check compact numeric IDs, duplicate claims, wrappers, and truncated streams.
        let selected = generator.next(files.count) + 1
        let folder: [String: Any] = ["name": "Selected", "file_ids": [selected, selected], "rename_suggestions": [["file_id": selected, "suggested_name": "new.pdf"]]]
        let json = payload(folder)
        let wrapped = [json, "```json\n" + json + "\n```", ">> general: Working\n" + json][generator.next(3)]
        cases += 1
        if let plan = try? ResponseParser.parseResponse(wrapped, originalFiles: files) {
            verify(plan, files: files, response: wrapped)
            check(allFiles(plan.suggestions).map(\.id) == [files[selected - 1].id], "numeric IDs select the indexed input", response: wrapped)
        } else {
            check(false, "valid ID response is accepted", response: wrapped)
        }

        let cut = generator.next(json.count + 1)
        let partial = String(json.prefix(cut))
        cases += 1
        if let plan = ResponseParser.extractPartialResults(partial, originalFiles: files) {
            verify(plan, files: files, response: partial)
            check(plan.isPartial && plan.needsReview, "partial extraction requests review", response: partial)
        }

        // An unfinished ID list must not consume numbers from a later metadata field.
        let malformed = "{\"folders\":[{\"name\":\"Chosen\",\"file_ids\":[0,\"comment\":\"reference 1 version 2\""
        cases += 1
        check(ResponseParser.extractPartialResults(malformed, originalFiles: files) == nil, "metadata numbers are not file IDs", response: malformed)

        if iteration == 0 {
            // Completed JSON with invalid numeric ID types must never coerce to valid IDs.
            for invalidID in ["true", "1.5", "-1"] {
                let invalid = "{\"folders\":[{\"name\":\"Chosen\",\"file_ids\":[\(invalidID)]}]}"
                cases += 1
                check(ResponseParser.extractPartialResults(invalid, originalFiles: files) == nil, "invalid numeric IDs stay unresolved", response: invalid)
                let invalidRename = "{\"folders\":[{\"name\":\"Chosen\",\"rename_suggestions\":[{\"file_id\":\(invalidID),\"suggested_name\":\"new.pdf\""
                cases += 1
                check(ResponseParser.extractPartialResults(invalidRename, originalFiles: files, mode: .organizeAndRename) == nil, "partial rename IDs do not coerce invalid numbers", response: invalidRename)
            }
        }
    }
    print("parser seed=\(seed) cases=\(cases) failedChecks=\(failedChecks) propertiesFailed=\(failures.count)")
    return failedChecks
}
