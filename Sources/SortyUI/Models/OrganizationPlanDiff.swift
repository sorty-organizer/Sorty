import Foundation

package struct OrganizationPlanDiff: Equatable, Identifiable {
    package struct Source {
        let oldPlan: OrganizationPlan
        let newPlan: OrganizationPlan
        let fromLabel: String
        let toLabel: String

        package init(
            oldPlan: OrganizationPlan,
            newPlan: OrganizationPlan,
            fromLabel: String,
            toLabel: String
        ) {
            self.oldPlan = oldPlan
            self.newPlan = newPlan
            self.fromLabel = fromLabel
            self.toLabel = toLabel
        }

        package func makeDiff() -> OrganizationPlanDiff {
            OrganizationPlanDiff(
                from: oldPlan,
                to: newPlan,
                fromLabel: fromLabel,
                toLabel: toLabel
            )
        }
    }

    package enum ChangeKind: String, CaseIterable {
        case moved = "Moved"
        case renamed = "Renamed"
        case tags = "Tags"
        case organized = "Organized"
        case unorganized = "Unorganized"

        package var systemImage: String {
            switch self {
            case .moved: "arrow.right"
            case .renamed: "pencil"
            case .tags: "tag"
            case .organized: "folder.badge.plus"
            case .unorganized: "tray"
            }
        }
    }

    package struct Change: Identifiable, Equatable {
        package let id: String
        package let kind: ChangeKind
        package let filename: String
        package let before: String?
        package let after: String?
    }

    package let fromLabel: String
    package let toLabel: String
    package let changes: [Change]

    package var id: String { "\(fromLabel)-\(toLabel)" }

    package init(from oldPlan: OrganizationPlan, to newPlan: OrganizationPlan, fromLabel: String, toLabel: String) {
        self.fromLabel = fromLabel
        self.toLabel = toLabel

        let oldFiles = Self.snapshot(oldPlan)
        let newFiles = Self.snapshot(newPlan)
        let keys = Set(oldFiles.keys).union(newFiles.keys)
        var result: [Change] = []

        for key in keys {
            let old = oldFiles[key]
            let new = newFiles[key]
            let filename = new?.originalName ?? old?.originalName ?? key

            switch (old, new) {
            case let (.some(old), .some(new)):
                if old.folder != new.folder {
                    let kind: ChangeKind
                    if old.folder == nil {
                        kind = .organized
                    } else if new.folder == nil {
                        kind = .unorganized
                    } else {
                        kind = .moved
                    }
                    result.append(Change(
                        id: "\(key)-folder",
                        kind: kind,
                        filename: filename,
                        before: old.folder ?? "Unorganized",
                        after: new.folder ?? "Unorganized"
                    ))
                }
                if old.finalName != new.finalName {
                    result.append(Change(
                        id: "\(key)-name",
                        kind: .renamed,
                        filename: filename,
                        before: old.finalName,
                        after: new.finalName
                    ))
                }
                if old.tags != new.tags {
                    result.append(Change(
                        id: "\(key)-tags",
                        kind: .tags,
                        filename: filename,
                        before: Self.tagDescription(old.tags),
                        after: Self.tagDescription(new.tags)
                    ))
                }
            case let (.none, .some(new)):
                result.append(Change(
                    id: "\(key)-added",
                    kind: new.folder == nil ? .unorganized : .organized,
                    filename: filename,
                    before: nil,
                    after: new.folder ?? "Unorganized"
                ))
            case let (.some(old), .none):
                result.append(Change(
                    id: "\(key)-removed",
                    kind: .unorganized,
                    filename: filename,
                    before: old.folder ?? "Unorganized",
                    after: nil
                ))
            case (.none, .none):
                break
            }
        }

        changes = result.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
        }
    }

    package func changes(for kind: ChangeKind) -> [Change] {
        changes.filter { $0.kind == kind }
    }

    private struct FileSnapshot {
        let originalName: String
        let finalName: String
        let folder: String?
        let tags: Set<String>
    }

    private static func snapshot(_ plan: OrganizationPlan) -> [String: FileSnapshot] {
        var result: [String: FileSnapshot] = [:]

        func visit(_ folder: FolderSuggestion, parentPath: String) {
            let folderPath = parentPath.isEmpty ? folder.folderName : "\(parentPath)/\(folder.folderName)"
            let renames = Dictionary(
                folder.fileRenameMappings.map { ($0.originalFile.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let tags = Dictionary(
                folder.fileTagMappings.map { ($0.originalFile.id, Set($0.tags)) },
                uniquingKeysWith: { _, latest in latest }
            )

            for file in folder.files {
                result[file.path] = FileSnapshot(
                    originalName: file.displayName,
                    finalName: renames[file.id]?.finalFilename ?? file.displayName,
                    folder: folderPath,
                    tags: tags[file.id] ?? []
                )
            }
            for subfolder in folder.subfolders {
                visit(subfolder, parentPath: folderPath)
            }
        }

        for folder in plan.suggestions {
            visit(folder, parentPath: "")
        }
        for file in plan.unorganizedFiles {
            result[file.path] = FileSnapshot(
                originalName: file.displayName,
                finalName: file.displayName,
                folder: nil,
                tags: []
            )
        }
        return result
    }

    private static func tagDescription(_ tags: Set<String>) -> String {
        tags.isEmpty ? "No tags" : tags.sorted().joined(separator: ", ")
    }
}
