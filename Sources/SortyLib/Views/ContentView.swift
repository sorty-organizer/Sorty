//
//  ContentView.swift
//  Sorty
//
//  Main container view with full-width layout
//  Updated to include Duplicates navigation
//  Enhanced with micro-animations and haptic feedback
//

import SwiftUI

public struct ContentView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var extensionListener: ExtensionListener
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var customPersonaStore: CustomPersonaStore

    @ObservedObject private var analytics = AnalyticsManager.shared
    @State private var previousView: AppState.AppView?
    @State private var showCommandNumbers = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var commandFlagsMonitor: Any?
    @State private var personaHighlightDismissalTask: Task<Void, Never>?
    @StateObject private var windowLinkHoverState = WindowLinkHoverState()

    public init() {}

    public var body: some View {
        ZStack {
            if !appState.hasCompletedOnboarding {
                OnboardingView(
                    hasCompletedOnboarding: Binding(
                        get: { appState.hasCompletedOnboarding },
                        set: { isComplete in
                            if isComplete {
                                appState.recordOnboardingCompletion()
                            } else {
                                appState.hasCompletedOnboarding = false
                            }
                        }
                    )
                )
                    .transition(.opacity)
            } else {
                ZStack {
                    mainContent

                    // HUD notification overlay (bottom-left)
                    HUDNotificationOverlay()
                }
                .transition(.opacity)
            }

            WindowLinkHoverPillOverlay(hoverState: windowLinkHoverState)

            if appState.hasCompletedOnboarding, analytics.consent == .undecided {
                AnalyticsConsentView()
            }
        }
        .environment(\.windowLinkHoverUpdate) { hovering, url, sourceID in
            windowLinkHoverState.setHovering(hovering, url: url, sourceID: sourceID)
        }
        .onDisappear {
            windowLinkHoverState.clearAllHover()
            personaHighlightDismissalTask?.cancel()
        }
        .onChange(of: analytics.consent) { _, newConsent in
            guard newConsent == .granted, appState.hasCompletedOnboarding else { return }
            captureMainScreen(appState.currentView, source: "consent")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: appState.hasCompletedOnboarding)
        .sheet(item: $appState.personaGeneratorPresentationContext) { context in
            PersonaGeneratorView(
                store: customPersonaStore,
                selectedPersonaId: Binding(
                    get: { personaManager.selectedCustomPersonaId },
                    set: { id in
                        guard let id else { return }
                        personaManager.selectCustomPersona(id)
                    }
                ),
                onPersonaGenerated: {
                    if context == .settings {
                        showPersonaGenerationHighlight()
                    }
                }
            )
        }
    }

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            List(selection: Binding(
                get: { appState.currentView },
                set: { newValue in
                    if let newValue = newValue {
                        guard newValue != appState.currentView else { return }
                        previousView = appState.currentView
                        HapticFeedbackManager.shared.selection()
                        appState.navigatedFromSettings = false
                        appState.clearNavigationReturnRoute()
                        appState.currentView = newValue
                    }
                }
            )) {
                ForEach(Array(sidebarItems.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: item.view) {
                        sidebarRow(item: item, commandNumber: index + 1)
                    }
                    .accessibilityIdentifier(item.accessibilityIdentifier)
                    .accessibilityHint(Text(LocalizedStringKey(item.accessibilityHint)))
                    .help(String(localized: String.LocalizationValue(item.helpText)))
                }
            }
            .navigationTitle("Sorty")
            .listStyle(.sidebar)
            .frame(width: 220)
            .navigationSplitViewColumnWidth(220)
        } detail: {
            // Render the selected page in the same update as the sidebar selection.
            contentView(for: appState.currentView)
                .accessibilityIdentifier(contentAccessibilityIdentifier(for: appState.currentView))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EmptyView()
                }

                ToolbarItem(placement: .navigation) {
                    if let returnRoute = appState.navigationReturnRoute,
                       returnRoute.destination == appState.currentView {
                        Button {
                            HapticFeedbackManager.shared.tap()
                            appState.clearNavigationReturnRoute()
                            appState.currentView = returnRoute.returnView
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("RelatedViewReturnButton")
                        .accessibilityLabel("Return to previous view")
                    } else if appState.navigatedFromSettings,
                              let prev = previousView,
                              prev != appState.currentView {
                        Button {
                            HapticFeedbackManager.shared.tap()
                            appState.navigatedFromSettings = false
                            appState.currentView = prev
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("SettingsReturnButton")
                        .accessibilityLabel("Return to previous view")
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main Navigation")
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear {
            columnVisibility = appState.showingSidebar ? .all : .detailOnly
            captureMainScreen(appState.currentView)
        }
        .onChange(of: columnVisibility) { _, newValue in
            let isShowingSidebar = newValue != .detailOnly
            guard appState.showingSidebar != isShowingSidebar else { return }
            appState.showingSidebar = isShowingSidebar
        }
        .onChange(of: appState.showingSidebar) { _, isShowingSidebar in
            let nextVisibility: NavigationSplitViewVisibility = isShowingSidebar ? .all : .detailOnly
            guard columnVisibility != nextVisibility else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                columnVisibility = nextVisibility
            }
        }
        .onChange(of: appState.currentView) { oldValue, newValue in
            if oldValue != newValue {
                if let returnRoute = appState.navigationReturnRoute,
                   returnRoute.destination != newValue {
                    appState.clearNavigationReturnRoute()
                }
                if newValue != .organize {
                    appState.showsFinderWorkflowPicker = false
                }
                previousView = oldValue
                captureMainScreen(
                    newValue,
                    previousScreen: analyticsScreenName(for: oldValue)
                )
            }
        }
        .onChange(of: appState.showDirectoryPicker) { _, showPicker in
            if showPicker {
                appState.showsFinderWorkflowPicker = false
                openDirectoryPicker()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openOrganizeDirectoryPickerInMainWindow)) { notification in
            guard notification.targetsWindowSession(appState.windowSessionID) else { return }
            appState.showsFinderWorkflowPicker = false
            appState.currentView = .organize
            appState.showDirectoryPicker = true
        }
        .onAppear {
            installCommandKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeCommandKeyMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                showCommandNumbers = false
            }
        }
        .onReceive(extensionListener.$incomingURL) { url in
            if let url = url {
                appState.showsFinderWorkflowPicker = true
                appState.selectedDirectory = url
                appState.currentView = .organize
                extensionListener.incomingURL = nil
            }
        }
    }

    @ViewBuilder
    private func contentView(for view: AppState.AppView) -> some View {
        switch view {
        case .organize:
            OrganizeView()
        case .settings:
            SettingsView()
        case .history:
            HistoryView()
        case .duplicates:
            DuplicatesView()
        case .exclusions:
            ExclusionRulesView()
        case .watchedFolders:
            WatchedFoldersView()
        case .learnings:
            LearningsView()
        }
    }

    private var sidebarItems: [SidebarNavigationItem] {
        SidebarNavigationItem.mainItems
    }

    private func captureMainScreen(
        _ view: AppState.AppView,
        source: String = "navigation",
        previousScreen: String? = nil
    ) {
        guard let screen = analyticsScreenName(for: view) else { return }
        analytics.captureScreen(
            screen,
            source: source,
            previousScreen: previousScreen
        )
    }

    private func analyticsScreenName(for view: AppState.AppView) -> String? {
        switch view {
        case .settings: return "settings"
        case .organize: return "organize"
        case .history: return "history"
        case .duplicates: return "duplicates"
        case .exclusions: return "exclusions"
        case .watchedFolders: return "watched_folders"
        case .learnings: return "learnings"
        }
    }

    private func contentAccessibilityIdentifier(for view: AppState.AppView) -> String {
        switch view {
        case .settings: return "SettingsScreen"
        case .organize: return "OrganizerScreen"
        case .history: return "HistoryScreen"
        case .duplicates: return "DuplicatesScreen"
        case .exclusions: return "ExclusionsScreen"
        case .watchedFolders: return "WatchedFoldersScreen"
        case .learnings: return "LearningsScreen"
        }
    }

    private func showPersonaGenerationHighlight() {
        personaHighlightDismissalTask?.cancel()
        appState.currentView = .settings
        appState.selectedSettingsSection = .rules
        appState.settingsFocusTarget = .rulesOrganizationStyle
        personaHighlightDismissalTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled,
                  appState.settingsFocusTarget == .rulesOrganizationStyle
            else {
                return
            }
            appState.settingsFocusTarget = nil
        }
    }

    @ViewBuilder
    private func sidebarRow(item: SidebarNavigationItem, commandNumber: Int) -> some View {
        let shortcutLabel = item.view == .settings ? "," : "\(commandNumber)"
        let isSelected = appState.currentView == item.view

        Label {
            Text(LocalizedStringKey(item.title))
        } icon: {
            Image(systemName: item.systemImage)
        }
            // The stock .sidebar selection highlight renders from the system
            // accent (NSColor.controlAccentColor) and ignores window-level
            // .tint(), so the selected row carries its own accent background.
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, showCommandNumbers ? 38 : 0)
            .overlay(alignment: .trailing) {
                Text(shortcutLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(minWidth: 18)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                isSelected
                                    ? AnyShapeStyle(.white.opacity(0.22))
                                    : AnyShapeStyle(.quaternary)
                            )
                    }
                    .opacity(showCommandNumbers ? 1 : 0)
                    .offset(x: showCommandNumbers ? 0 : 14)
                    .scaleEffect(showCommandNumbers ? 1 : 0.96)
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.08),
                value: showCommandNumbers
            )
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SortyDesignSystem.Colors.resolvedAccent)
                    .padding(.horizontal, 4)
            )
    }

    private func installCommandKeyMonitorIfNeeded() {
        guard commandFlagsMonitor == nil else { return }

        commandFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let isCommandHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            if isCommandHeld != showCommandNumbers {
                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.08)) {
                    showCommandNumbers = isCommandHeld
                }
            }
            return event
        }
    }

    private func removeCommandKeyMonitor() {
        guard let monitor = commandFlagsMonitor else { return }
        NSEvent.removeMonitor(monitor)
        commandFlagsMonitor = nil
        showCommandNumbers = false
    }

    private func openDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a directory to organize"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            appState.selectedDirectory = url
            appState.currentView = .organize
            HapticFeedbackManager.shared.success()
        }

        appState.showDirectoryPicker = false
    }
}

// MARK: - Preview

#Preview("Content View - Main") {
    ContentView()
        .environmentObject(PreviewObjects.mainAppState)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(FolderOrganizer.preview)
        .environmentObject(ExclusionRulesManager.preview)
        .environmentObject(ExtensionListener.preview)
        .environmentObject(PersonaManager())
        .environmentObject(CustomPersonaStore())
        .frame(width: 1200, height: 800)
}

#Preview("Content View - Onboarding") {
    ContentView()
        .environmentObject(PreviewObjects.onboardingAppState)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(FolderOrganizer.preview)
        .environmentObject(ExclusionRulesManager.preview)
        .environmentObject(ExtensionListener.preview)
        .environmentObject(PersonaManager())
        .environmentObject(CustomPersonaStore())
        .frame(width: 1000, height: 720)
}

// MARK: - Preview Helpers

@MainActor
enum PreviewObjects {
    static var mainAppState: AppState {
        let state = AppState()
        state.hasCompletedOnboarding = true
        return state
    }

    static var onboardingAppState: AppState {
        let state = AppState()
        state.hasCompletedOnboarding = false
        return state
    }
}
