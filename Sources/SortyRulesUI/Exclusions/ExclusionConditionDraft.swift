import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add Exclusion Rule View

enum ExclusionIntent: String, CaseIterable, Identifiable {
    case folder
    case finderTag
    case fileKind
    case name
    case properties
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .folder: "A specific folder"
        case .finderTag: "A Finder tag"
        case .fileKind: "A kind of file"
        case .name: "Files or folders by name"
        case .properties: "Files by size or age"
        case .advanced: "Advanced rule"
        }
    }

    var explanation: String {
        switch self {
        case .folder: "Exclude one folder and everything inside it from organizations and renames."
        case .finderTag: "Exclude files and folders with a selected Finder tag."
        case .fileKind: "Exclude a familiar category, or one specific file extension."
        case .name: "Match text in a file name or an exact folder name."
        case .properties: "Exclude files above or below a size, or based on their age."
        case .advanced: "Hidden files, macOS files, path fragments, and regular expressions."
        }
    }

    var icon: String {
        switch self {
        case .folder: "folder.badge.minus"
        case .finderTag: "tag"
        case .fileKind: "doc.on.doc"
        case .name: "text.magnifyingglass"
        case .properties: "slider.horizontal.3"
        case .advanced: "gearshape.2"
        }
    }
}

extension FinderTagColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}

enum FileKindChoice: String, CaseIterable, Identifiable {
    case category = "File category"
    case fileExtension = "File extension"

    var id: Self { self }
}

enum NameMatchChoice: String, CaseIterable, Identifiable {
    case fileName = "File name contains"
    case folderName = "Folder name is"

    var id: Self { self }
}

enum PropertyChoice: String, CaseIterable, Identifiable {
    case fileSize = "File size"
    case modificationDate = "Last modified"
    case creationDate = "Date created"

    var id: Self { self }
}

enum AdvancedRuleChoice: String, CaseIterable, Identifiable {
    case hiddenFiles = "Hidden files"
    case systemFiles = "macOS system files"
    case pathContains = "Any path containing text"
    case regex = "Regular expression"

    var id: Self { self }
}

/// Snapshot of every linked-condition editor field, used to detect unsaved edits
/// before switching to another condition in the same group.
struct ExclusionConditionDraft: Equatable {
    var intent: ExclusionIntent?
    var fileKindChoice: FileKindChoice
    var nameMatchChoice: NameMatchChoice
    var propertyChoice: PropertyChoice
    var advancedChoice: AdvancedRuleChoice
    var selectedFinderTag: FinderTagColor
    var pattern: String
    var description: String
    var numericValue: Double
    var comparisonGreater: Bool
    var sizeUnit: ExclusionSizeUnit
    var dateAgeUnit: ExclusionAgeUnit
    var selectedFileTypeCategory: FileTypeCategory
    var selectedFolderURL: URL?
    var caseSensitive: Bool
    var negated: Bool
}
