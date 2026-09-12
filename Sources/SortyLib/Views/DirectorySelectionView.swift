//
//  DirectorySelectionView.swift
//  Sorty
//
//  Folder selection with drag-drop support and enhanced animations
//

import Beam
import SwiftUI
import UniformTypeIdentifiers

struct DirectorySelectionView: View {
    @SortyHotReload private var hotReload
    @Binding var selectedDirectory: URL?
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var menuBarController: MenuBarController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    let isPresented: Bool
    @State private var isTargeted = false
    @State private var isHovering = false
    @State private var isBrowseHovering = false
    @State private var isWindowVisible = true

    @State private var iconBounce = false
    @State private var hasAppeared = false

    init(
        selectedDirectory: Binding<URL?>,
        startsVisible: Bool = false,
        isPresented: Bool = true
    ) {
        _selectedDirectory = selectedDirectory
        _hasAppeared = State(initialValue: startsVisible)
        self.isPresented = isPresented
    }

    var body: some View {
        WorkflowContainer(currentStep: .selectFolder) {
            Spacer()
                .frame(minHeight: 40, maxHeight: .infinity)

            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text(headlineText)
                        .font(.title)
                        .fontWeight(.bold)
                        .id(headlineText)
                        .transition(.blurReplace)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: headlineText)
                        .opacity(hasAppeared ? 1 : 0)

                    Text("Drag and drop a folder here, or click to browse")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .opacity(hasAppeared ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.2).delay(0.05), value: hasAppeared)

                dropZone

                Button {
                    HapticFeedbackManager.shared.tap()
                    AnalyticsManager.shared.captureImportantButton(
                        "browse_for_folder",
                        screen: "organize",
                        feature: "folder_selection"
                    )
                    selectDirectory()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 15, weight: .medium))
                        Text("Browse for Folder")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.sortyPrimary)
                .beam(
                    .small,
                    palette: .ocean,
                    theme: .dark,
                    active: hasAppeared
                        && isPresented
                        && !reduceMotion
                        && isWindowVisible
                        && controlActiveState != .inactive,
                    shape: .capsule,
                    strength: 1
                )
                .contentShape(Capsule())
                .scaleEffect(isBrowseHovering ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isBrowseHovering)
                .onHover { hovering in
                    let wasHovering = isBrowseHovering
                    if hovering && !wasHovering {
                        HapticFeedbackManager.shared.selection()
                    }
                    isBrowseHovering = hovering
                }
                .keyboardShortcut("o", modifiers: .command)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.2).delay(0.1), value: hasAppeared)
                .accessibilityIdentifier("BrowseForFolderButton")

                if settingsViewModel.config.enableSmartRename {
                    organizationModePicker
                        .opacity(hasAppeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.2).delay(0.12), value: hasAppeared)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()
                .frame(minHeight: 40, maxHeight: .infinity)

            quickTips
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.2).delay(0.15), value: hasAppeared)
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .siriDropZone(isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onAppear {
            withAnimation {
                hasAppeared = true
            }
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Directory Selection Area")
        .accessibilityHint("Drag and drop a folder here or use the Browse button")
    }

    private var headlineText: String {
        guard settingsViewModel.config.enableSmartRename else {
            return "Select a directory to organize"
        }
        switch settingsViewModel.config.mode {
        case .organize:
            return "Select a directory to organize"
        case .organizeAndRename:
            return "Select a directory to organize & rename"
        case .renameOnly:
            return "Select a directory to rename"
        }
    }

    private var organizationModePicker: some View {
        HStack(spacing: 4) {
            ForEach(OrganizationMode.allCases, id: \.self) { mode in
                OrganizationModeSegment(
                    mode: mode,
                    isSelected: settingsViewModel.config.mode == mode
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        settingsViewModel.config.mode = mode
                    }
                    HapticFeedbackManager.shared.tap()
                    AnalyticsManager.shared.captureFeature(
                        feature: "organize",
                        subfeature: "organization_mode",
                        action: "select",
                        outcome: "success",
                        properties: ["mode": mode.rawValue]
                    )
                }
            }
        }
        .padding(4)
        .systemLiquidGlassBackground(cornerRadius: 999)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Organization mode")
    }

    private var dropZone: some View {
        let dropZoneHeight: CGFloat = settingsViewModel.config.enableSmartRename ? 140 : 150
        let dropZoneCornerRadius: CGFloat = 16
        let folderAccent = SortyDesignSystem.Colors.resolvedAccent
        let dropZoneContent = VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isTargeted ? folderAccent.opacity(0.16) : folderAccent.opacity(0.08))
                    .frame(width: 64, height: 64)
                    .scaleEffect(isTargeted ? 1.1 : 1.0)

                Image(systemName: isTargeted ? "folder.fill.badge.plus" : "folder.badge.plus")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(isTargeted ? folderAccent : folderAccent.opacity(0.9))
                    .symbolReplaceTransition(animationValue: isTargeted)
                    .animatedEmptyStateIcon()
                    .scaleEffect(iconBounce ? 1.1 : 1.0)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isTargeted)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: iconBounce)

            Text(isTargeted ? "Drop to select" : "Drop folder here")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isTargeted ? SortyDesignSystem.Colors.resolvedAccent : .secondary)
                .numericTextTransition(animationValue: isTargeted)
        }
        .frame(width: 220, height: dropZoneHeight)

        return Button {
            HapticFeedbackManager.shared.tap()
            selectDirectory()
        } label: {
            Group {
                if #available(macOS 26.0, *) {
                    dropZoneContent
                        .systemLiquidGlassBackground(cornerRadius: dropZoneCornerRadius, clear: true)
                        .overlay {
                            RoundedRectangle(cornerRadius: dropZoneCornerRadius, style: .continuous)
                                .fill(isTargeted ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.08) : .clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: dropZoneCornerRadius, style: .continuous)
                                .strokeBorder(
                                    isTargeted ? SortyDesignSystem.Colors.resolvedAccent : Color.secondary.opacity(0.3),
                                    lineWidth: 1
                                )
                        }
                } else {
                    dropZoneContent
                        .background {
                            RoundedRectangle(cornerRadius: dropZoneCornerRadius, style: .continuous)
                                .fill(
                                    isTargeted
                                        ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.08)
                                        : Color.secondary.opacity(0.05))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: dropZoneCornerRadius, style: .continuous)
                                .fill(isTargeted ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.08) : .clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: dropZoneCornerRadius, style: .continuous)
                                .strokeBorder(
                                    isTargeted ? SortyDesignSystem.Colors.resolvedAccent : Color.secondary.opacity(0.3),
                                    lineWidth: 1
                                )
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isTargeted ? 1.05 : 1.0)
        .shadow(color: isTargeted ? .accentColor.opacity(0.2) : .clear, radius: 12, y: 4)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.9)
        .animation(
            reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8).delay(0.1),
            value: hasAppeared
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { hovering in
            isHovering = hovering
            if hovering, !reduceMotion {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                    iconBounce = true
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        iconBounce = false
                    }
                }
            }
        }
        .accessibilityLabel("Browse for a folder")
        .accessibilityInputLabels(["Browse for a folder", "Drop folder here"])
        .accessibilityHint("Opens the folder picker")
    }

    private var quickTips: some View {
        HStack(spacing: 32) {
            QuickTipItemCompact(
                icon: "hand.draw",
                title: "Drag & Drop",
                description: "Drop any folder"
            ) {
                HapticFeedbackManager.shared.tap()
                selectDirectory()
            }

            if FeatureFlags.finderSyncEnabled {
                QuickTipItemCompact(
                    icon: "cursorarrow.click.2",
                    title: "Finder Menu",
                    description: "Select and right-click"
                ) {
                    openFinderForRightClick()
                }
            } else {
                QuickTipItemCompact(
                    icon: "menubar.rectangle",
                    title: "Menu Bar",
                    description: "Open menu"
                ) {
                    openMenuBarTip()
                }
            }

            QuickTipItemCompact(
                icon: "keyboard",
                title: "Keyboard",
                description: "⌘O to browse"
            ) {
                HapticFeedbackManager.shared.tap()
                selectDirectory()
            }
        }
        .padding(.bottom, 24)
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            HapticFeedbackManager.shared.success()
            AnalyticsManager.shared.captureFeature(
                feature: "organize",
                subfeature: "folder_selection",
                action: "select",
                outcome: "success",
                properties: ["source": "folder_picker"]
            )
            withAnimation(workflowNavigationAnimation) {
                selectedDirectory = url
            }
        }
    }

    private var workflowNavigationAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.38, dampingFraction: 0.86)
    }

    private func openMenuBarTip() {
        HapticFeedbackManager.shared.tap()
        menuBarController.showGreeting()
        if !UserDefaults.standard.bool(forKey: "showMenuBarIcon") {
            UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
        }
        showMenuBarExtra()
    }

    /// Selects the current folder in Finder so the user can open Sorty's native menu.
    /// Before a folder is selected, Finder opens at the user's home directory instead.
    private func openFinderForRightClick() {
        HapticFeedbackManager.shared.tap()

        let requestedDirectory = selectedDirectory?.standardizedFileURL ?? URL.homeDirectory
        let directory = FileManager.default.fileExists(atPath: requestedDirectory.path)
            ? requestedDirectory
            : URL.homeDirectory

        NSWorkspace.shared.activateFileViewerSelecting([directory])
        NotificationManager.shared.showInfo(
            title: "Folder Selected in Finder",
            message: "Right-click it to use Organize, Watch, or Exclude."
        )
    }

    private func showMenuBarExtra() {
        if !UserDefaults.standard.bool(forKey: "showMenuBarExtra") {
            UserDefaults.standard.set(true, forKey: "showMenuBarExtra")
            NotificationCenter.default.post(name: NSNotification.Name("com.sorty.showMenuBar"), object: nil)
        }

        if !attemptOpenMenuBarExtra() {
            NotificationManager.shared.showInfo(
                title: "Check Menu Bar",
                message: "The Sorty icon is now active in your status bar."
            )
        }
    }

    private func attemptOpenMenuBarExtra() -> Bool {
        let script = """
        tell application "System Events"
            tell process "SystemUIServer"
                set menuBarItems to menu bar items of menu bar 1
                repeat with itemRef in menuBarItems
                    try
                        set itemDesc to (description of itemRef) as string
                        if itemDesc contains "Sorty" then
                            click itemRef
                            return true
                        end if
                    end try
                end repeat
            end tell
        end tell
        return false
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return false }
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            DebugLogger.log("Menu bar open failed: \(error)")
            return false
        }
        return result.booleanValue
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
            item, error in
            if let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil),
                url.hasDirectoryPath
            {
                Task { @MainActor in
                    HapticFeedbackManager.shared.success()
                    AnalyticsManager.shared.captureFeature(
                        feature: "organize",
                        subfeature: "folder_selection",
                        action: "select",
                        outcome: "success",
                        properties: ["source": "drag_and_drop"]
                    )
                    withAnimation(workflowNavigationAnimation) {
                        selectedDirectory = url
                    }
                }
            }
        }

        return true
    }
}

struct QuickTipItemCompact: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let icon: String
    let title: String
    let description: String
    var action: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            } else {
                content
            }
        }
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7), value: isHovering)
        .contentShape(Rectangle())
        .onHover { isHovering = action != nil && $0 }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(isHovering ? SortyDesignSystem.Colors.resolvedAccent : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title))
                    .font(.callout.bold())
                Text(LocalizedStringKey(description))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct OrganizationModeSegment: View {
    @SortyHotReload private var hotReload
    let mode: OrganizationMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolReplaceTransition(animationValue: mode)
                Text(mode.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
                    .numericTextTransition(animationValue: mode)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? SortyDesignSystem.Colors.resolvedAccent
                            : (isHovering ? Color.secondary.opacity(0.12) : Color.clear)
                    )
            }
            .foregroundColor(isSelected ? .white : .primary)
            .contentShape(Capsule())
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering && !isHovering {
                HapticFeedbackManager.shared.selection()
            }
            isHovering = hovering
        }
        .help(mode.description)
        .accessibilityLabel(mode.displayName)
        .accessibilityHint(mode.description)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension UTType {
    static var fileURL: UTType {
        UTType(exportedAs: "public.file-url")
    }
}
