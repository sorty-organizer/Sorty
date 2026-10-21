import SwiftUI
import UniformTypeIdentifiers

struct AddExclusionRuleView: View {
    @SortyHotReload var hotReload
    @ObservedObject var rulesManager: ExclusionRulesManager
    @Environment(\.dismiss) var dismiss
    let editingRule: ExclusionRule?
    let relatedRules: [ExclusionRule]
    let isEmbedded: Bool
    @State var selectedIntent: ExclusionIntent?
    @State var fileKindChoice: FileKindChoice = .category
    @State var nameMatchChoice: NameMatchChoice = .fileName
    @State var propertyChoice: PropertyChoice = .fileSize
    @State var advancedChoice: AdvancedRuleChoice = .hiddenFiles
    @State var selectedFinderTag: FinderTagColor = .red
    @State var pattern: String = ""
    @State var description: String = ""
    @State var numericValue: Double = 100
    @State var comparisonGreater: Bool = true
    @State var sizeUnit: ExclusionSizeUnit = .megabytes
    @State var dateAgeUnit: ExclusionAgeUnit = .days
    @State var selectedFileTypeCategory: FileTypeCategory = .images
    @State var selectedFolderURL: URL?
    @State var showingFolderPicker = false
    @State var caseSensitive = false
    @State var negated = false
    @State var activeConditionID: UUID?
    /// Editor values as last loaded, used to detect unsaved linked-condition edits.
    @State var loadedConditionDraft: ExclusionConditionDraft?
    @State var pendingCondition: ExclusionRule?
    @State var showingConditionSwitchConfirmation = false

    init(
        rulesManager: ExclusionRulesManager,
        editing rule: ExclusionRule? = nil,
        relatedRules: [ExclusionRule] = [],
        isEmbedded: Bool = false
    ) {
        self.rulesManager = rulesManager
        editingRule = rule
        self.relatedRules = relatedRules.isEmpty ? rule.map { [$0] } ?? [] : relatedRules
        self.isEmbedded = isEmbedded
        _activeConditionID = State(initialValue: rule?.id)

        guard let rule else { return }
        let intent = Self.intent(for: rule)

        _selectedIntent = State(initialValue: intent)
        _fileKindChoice = State(initialValue: rule.type == .fileExtension ? .fileExtension : .category)
        _nameMatchChoice = State(initialValue: rule.type == .folderName ? .folderName : .fileName)
        _propertyChoice = State(initialValue: rule.type == .creationDate ? .creationDate : rule.type == .modificationDate ? .modificationDate : .fileSize)
        _advancedChoice = State(initialValue: rule.type == .systemFiles ? .systemFiles : rule.type == .pathContains ? .pathContains : rule.type == .regex ? .regex : .hiddenFiles)
        _selectedFinderTag = State(initialValue: Int(rule.pattern).flatMap(FinderTagColor.init(rawValue:)) ?? .red)
        _pattern = State(initialValue: rule.pattern)
        _description = State(initialValue: rule.description ?? "")
        _sizeUnit = State(initialValue: rule.sizeUnit ?? .megabytes)
        _dateAgeUnit = State(initialValue: rule.ageUnit ?? .days)
        let displayedValue: Double
        if rule.type == .fileSize {
            displayedValue = (rule.numericValue ?? 0) / (rule.sizeUnit ?? .megabytes).megabyteMultiplier
        } else if rule.type == .creationDate || rule.type == .modificationDate {
            displayedValue = (rule.ageIntervalSeconds ?? 0) / (rule.ageUnit ?? .days).secondsMultiplier
        } else {
            displayedValue = rule.numericValue ?? 100
        }
        _numericValue = State(initialValue: displayedValue)
        _selectedFileTypeCategory = State(initialValue: rule.fileTypeCategory ?? .images)
        _selectedFolderURL = State(initialValue: intent == .folder ? URL(fileURLWithPath: rule.pattern) : nil)
        _caseSensitive = State(initialValue: rule.caseSensitive)
        _negated = State(initialValue: rule.negated)
    }

    var body: some View {
        Group {
            if isEmbedded {
                editorContent
            } else {
                VStack(spacing: 0) {
                    header

                    Divider()

                    ScrollView {
                        editorContent
                            .padding(20)
                    }
                }
                .frame(width: 620, height: 620)
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                return
            }
            HapticFeedbackManager.shared.selection()
            selectedFolderURL = url.standardizedFileURL
        }
        .onAppear(perform: captureInitialConditionDraftIfNeeded)
        .confirmationDialog(
            "Unsaved changes to this condition",
            isPresented: $showingConditionSwitchConfirmation,
            titleVisibility: .visible
        ) {
            if isValidInput {
                Button("Save & Switch") {
                    saveActiveConditionAndSwitch()
                }
            }
            Button("Discard Changes", role: .destructive) {
                discardActiveConditionChanges()
            }
            Button("Keep Editing", role: .cancel) {
                pendingCondition = nil
            }
        } message: {
            Text("Your edits to the current condition haven't been saved yet.")
        }
    }

}
