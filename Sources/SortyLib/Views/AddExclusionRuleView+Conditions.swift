import SwiftUI
import UniformTypeIdentifiers

// MARK: - Conditions
extension AddExclusionRuleView {
    var folderConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedFolderURL {
                HStack(spacing: 14) {
                    FolderThumbnailView(
                        url: selectedFolderURL,
                        size: CGSize(width: 36, height: 36)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedFolderURL.lastPathComponent)
                            .font(.subheadline.weight(.medium))
                        PrivacySensitivePathText(
                            path: selectedFolderURL.deletingLastPathComponent().path
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer()

                    Button("Change") {
                        showingFolderPicker = true
                    }
                    .buttonStyle(.sortyBordered(size: .small))
                }
            } else {
                HStack(spacing: 16) {
                    Image(systemName: "folder.badge.minus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                        .frame(width: 44, height: 44)
                        .background(SortyDesignSystem.Colors.resolvedAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Choose the folder to exclude")
                            .font(.subheadline.weight(.semibold))
                        Text("The folder and everything inside it will be excluded from organizations and renames.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Button {
                        HapticFeedbackManager.shared.tap()
                        showingFolderPicker = true
                    } label: {
                        Label("Choose Folder", systemImage: "folder.badge.minus")
                    }
                    .buttonStyle(.sortyPrimary)
                    .accessibilityIdentifier("ChooseExclusionFolderButton")
                }
            }
        }
    }

    var fileKindConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Match", selection: $fileKindChoice) {
                ForEach(FileKindChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if fileKindChoice == .category {
                Picker("Category", selection: $selectedFileTypeCategory) {
                    ForEach(FileTypeCategory.allCases) { category in
                        Label(category.rawValue, systemImage: category.icon).tag(category)
                    }
                }
                .pickerStyle(.menu)

                Text(categorySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                labeledPatternField(
                    title: "Extension",
                    placeholder: "pdf",
                    help: "Enter it with or without the dot."
                )
            }
        }
    }

    var finderTagConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Finder tag", selection: $selectedFinderTag) {
                ForEach(FinderTagColor.allCases) { tag in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(tag.name)
                    }
                    .tag(tag)
                }
            }
            .pickerStyle(.menu)

            Text("Tag a file or folder in Finder. Sorty will leave it alone. A tagged folder protects everything inside it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var nameConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Match", selection: $nameMatchChoice) {
                ForEach(NameMatchChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            labeledPatternField(
                title: nameMatchChoice == .fileName ? "Text in the file name" : "Folder name",
                placeholder: nameMatchChoice == .fileName ? "draft" : "node_modules",
                help: nameMatchChoice == .fileName
                    ? "Any matching file will be excluded from organizations and renames."
                    : "Every matching folder and its contents will be excluded from organizations and renames."
            )
        }
    }

    var propertyConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Property", selection: $propertyChoice) {
                ForEach(PropertyChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if propertyChoice == .fileSize {
                HStack(spacing: 10) {
                    Picker("Exclude files", selection: $comparisonGreater) {
                        Text("Exclude files larger than").tag(true)
                        Text("Exclude files smaller than").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()

                    TextField("100", value: $numericValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    Picker("Size unit", selection: $sizeUnit) {
                        ForEach(ExclusionSizeUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 82)

                    Spacer()
                }
            } else {
                HStack(spacing: 10) {
                    Picker("Exclude files", selection: $comparisonGreater) {
                        Text("Exclude files older than").tag(true)
                        Text("Exclude files newer than").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()

                    TextField("30", value: $numericValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    Picker("Time unit", selection: $dateAgeUnit) {
                        ForEach(ExclusionAgeUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Spacer()
                }
            }
        }
    }

    var advancedConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Rule", selection: $advancedChoice) {
                ForEach(AdvancedRuleChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.menu)

            switch advancedChoice {
            case .hiddenFiles:
                explanationRow("Files and folders whose names begin with a period will be excluded from organizations and renames.")
            case .systemFiles:
                explanationRow("Common macOS metadata and system-generated files will be excluded from organizations and renames.")
            case .pathContains:
                labeledPatternField(
                    title: "Text in the path",
                    placeholder: "backups",
                    help: "Matches any path that contains this text. To exclude a folder and everything inside it, use “A specific folder” instead."
                )
                if trimmedPattern.hasPrefix("/") {
                    pathSemanticsHint
                }
            case .regex:
                labeledPatternField(
                    title: "Regular expression",
                    placeholder: "^temp_.*\\.log$",
                    help: "Matches against the file or folder name."
                )
                if let patternValidationIssue {
                    patternErrorRow(patternValidationIssue)
                }
            }
        }
    }

    /// Explains that a free-text path rule matches text, not a folder tree, so
    /// "/backups/" doesn't silently behave like a chosen folder.
    var pathSemanticsHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text("“\(trimmedPattern)” matches any path containing that text. To exclude a folder and its contents, go back and choose “A specific folder”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("ExclusionRulePathSemanticsHint")
    }

    func patternErrorRow(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityIdentifier("ExclusionRulePatternError")
    }

    func labeledPatternField(title: String, placeholder: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            TextField(placeholder, text: $pattern)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ExclusionRulePatternField")
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func explanationRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
