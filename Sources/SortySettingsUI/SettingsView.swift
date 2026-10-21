//
//  SettingsView.swift
//  Sorty
//
//  Lightweight settings container with sidebar navigation
//

import SwiftUI

/// One shared page-change animation for Settings. Only the incoming page
/// animates; the outgoing page is removed immediately so the switch never
/// lays out and composites two heavy pages at once.
enum SettingsPageTransition {
    /// How long pages should wait before starting main-actor probes, so
    /// permission or Finder checks never land mid-transition.
    static let settleMilliseconds = 240

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.26, dampingFraction: 0.9)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)),
            removal: .identity
        )
    }
}

package struct SettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState
    @ObservedObject private var analytics = AnalyticsManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedCategory: SettingsCategory = .general
    @State private var appStateSyncTask: Task<Void, Never>?
    @State private var searchText = ""
    @StateObject private var windowLinkHoverState = WindowLinkHoverState()

    package init() {}

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearchText.isEmpty
    }

    package var body: some View {
        trackedSettingsLayout
        .onChange(of: appState.selectedSettingsSection) { _, newSection in
            if let section = newSection, section != selectedCategory {
                // Cards and header controls animate locally. Animating this
                // replacement also animates the outgoing page and its layout.
                selectedCategory = section
            }
        }
        .onChange(of: searchText) { _, _ in
            guard !filteredCategories.contains(selectedCategory) else { return }
            if let firstCategory = filteredCategories.first {
                selectedCategory = firstCategory
            }
        }
        .task(id: appState.settingsFocusTarget) {
            guard let target = appState.settingsFocusTarget else { return }

            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, appState.settingsFocusTarget == target else { return }
            appState.settingsFocusTarget = nil
        }
        .onDisappear {
            // Leaving mid-transition still remembers the page, without
            // re-running openSettingsWindow and navigating back here.
            if appStateSyncTask != nil, appState.selectedSettingsSection != selectedCategory {
                let category = selectedCategory
                Task { @MainActor in
                    appState.selectedSettingsSection = category
                }
            }
            appStateSyncTask?.cancel()
            windowLinkHoverState.clearAllHover()
        }
    }

    /// Switches pages from the sidebar. Only this view's state changes on the
    /// click frame; publishing to AppState re-renders the whole window, so
    /// that waits until the incoming page has finished animating in.
    private func selectFromSidebar(_ category: SettingsCategory) {
        HapticFeedbackManager.shared.selection()
        if appState.settingsFocusTarget != nil {
            // A pending focus target would route straight back to its own page.
            appState.settingsFocusTarget = nil
        }
        guard category != selectedCategory else { return }

        withAnimation(SettingsPageTransition.animation(reduceMotion: reduceMotion)) {
            selectedCategory = category
        }

        appStateSyncTask?.cancel()
        appStateSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(SettingsPageTransition.settleMilliseconds))
            guard !Task.isCancelled, selectedCategory == category else { return }
            appState.openSettingsWindow(section: category)
        }
    }

    private var settingsSidebar: some View {
        let categories = filteredCategories
        let categoriesByGroup = Dictionary(grouping: categories, by: \.group)
        let groups = SettingsCategoryGroup.allCases.filter { categoriesByGroup[$0]?.isEmpty == false }

        return VStack(alignment: .leading, spacing: 2) {
            if categories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing found")
                        .font(.subheadline.weight(.medium))
                    Text("Sorty could not find that setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
            } else {
                ForEach(groups, id: \.self) { group in
                    if !group.rawValue.isEmpty {
                        sectionHeader(group.rawValue)
                    }
                    ForEach(categoriesByGroup[group] ?? []) { category in
                        SidebarButton(
                            title: category.rawValue,
                            icon: category.sidebarIcon,
                            color: category.color,
                            isSelected: selectedCategory == category
                        ) {
                            selectFromSidebar(category)
                        }
                        .help("\(category.rawValue) settings")
                        .accessibilityHint("Open \(category.rawValue) settings")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func sectionHeader(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private var contentView: some View {
        GeometryReader { geometry in
            let results = isSearching ? searchResults : []

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if isSearching {
                            searchResultsHeader(results: results)
                                .animatedAppearance(delay: 0.03)
                            searchResultsContent(
                                results: results,
                                minHeight: max(geometry.size.height - 128, 320)
                            )
                                .animatedAppearance(delay: 0.08)
                        } else {
                            VStack(alignment: .leading, spacing: 20) {
                                categoryHeader
                                categoryContent
                                    .settingsFocusTarget(appState.settingsFocusTarget)
                                    .settingsFocusDismissAction { target in
                                        guard appState.settingsFocusTarget == target else { return }
                                        appState.settingsFocusTarget = nil
                                    }
                            }
                            // A fresh identity per page gives each one its own
                            // state and lets the page transition run on insert.
                            .id(selectedCategory)
                            .transition(SettingsPageTransition.transition(reduceMotion: reduceMotion))
                        }
                    }
                    .padding(24)
                }
                .onAppear {
                    routeToFocusedSetting(using: proxy)
                }
                .onChange(of: appState.settingsFocusTarget) { _, _ in
                    routeToFocusedSetting(using: proxy)
                }
                .onChange(of: selectedCategory) { _, _ in
                    routeToFocusedSetting(using: proxy)
                }
                .onChange(of: isSearching) { _, isSearching in
                    if !isSearching {
                        routeToFocusedSetting(using: proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var availableCategories: [SettingsCategory] {
        SettingsCategory.allCases
    }
    
    private var filteredCategories: [SettingsCategory] {
        guard isSearching else {
            return availableCategories
        }

        let matchedCategorySet = Set(searchResults.map(\.category))
        return availableCategories.filter { matchedCategorySet.contains($0) || $0.matchesSearch(query: trimmedSearchText) }
    }

    private var searchResults: [SettingsFeatureMatch] {
        guard isSearching else { return [] }

        let query = trimmedSearchText
        return availableCategories
            .flatMap { category in
                let matches = category.featureMatches(query: query)
                if !matches.isEmpty {
                    return matches
                }

                if category.matchesSearch(query: query) {
                    let fallback = SettingsFeatureSnippet(
                        title: category.rawValue,
                        summary: "Open this section to review settings related to \"\(query)\"."
                    )
                    return [SettingsFeatureMatch(category: category, snippet: fallback, score: 1)]
                }
                return []
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                if $0.category.rawValue != $1.category.rawValue {
                    return $0.category.rawValue < $1.category.rawValue
                }
                return $0.snippet.title < $1.snippet.title
            }
    }
    
    private func analyticsSectionName(_ category: SettingsCategory) -> String {
        switch category {
        case .general: return "general"
        case .provider: return "ai_provider"
        case .strategy: return "analysis_and_naming"
        case .rules: return "organize_rules"
        case .automation: return "automation"
        case .deeplinks: return "deeplinks"
        case .finder: return "finder_integration"
        case .notifications: return "notifications"
        case .permissions: return "permissions"
        case .advanced: return "advanced"
        case .troubleshooting: return "troubleshooting"
        case .help: return "help_and_support"
        case .experimental: return "experimental"
        }
    }

    private func captureSettingsScreen(
        _ category: SettingsCategory,
        source: String = "settings_navigation"
    ) {
        let section = analyticsSectionName(category)
        analytics.captureScreen(
            "settings_\(section)",
            section: section,
            source: source
        )
    }

    private var categoryHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: selectedCategory.sidebarIcon)
                .symbolVariant(.fill)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(selectedCategory.color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(LocalizedStringKey(selectedCategory.rawValue))
                .font(.title2.bold())
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private func searchResultsHeader(results: [SettingsFeatureMatch]) -> some View {
        let uniqueCategoryCount = Set(results.map(\.category)).count

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Search Results")
                    .font(.title2.bold())
            }

            Text("\"\(trimmedSearchText)\" matched \(results.count) \(results.count == 1 ? "setting" : "settings") in \(uniqueCategoryCount) \(uniqueCategoryCount == 1 ? "section" : "sections").")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .numericTextTransition(
                    animationValue: "\(trimmedSearchText)-\(results.count)-\(uniqueCategoryCount)"
                )
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func searchResultsContent(results: [SettingsFeatureMatch], minHeight: CGFloat) -> some View {
        if results.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 96, weight: .regular))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .frame(width: 220, height: 160)
                    .animatedEmptyStateIcon(tint: Color.accentColor)
                    .accessibilityLabel("No matching settings")

                VStack(spacing: 5) {
                    Text("Sorty came up empty")
                        .font(.headline)
                    Text("Nothing matches \"\(trimmedSearchText)\" yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sorty came up empty. Nothing matches \(trimmedSearchText) yet.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(results) { result in
                    SettingsCard(
                        title: result.snippet.title,
                        icon: result.category.icon,
                        color: result.category.color
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(LocalizedStringKey(result.snippet.summary))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Label {
                                    Text(LocalizedStringKey(result.category.rawValue))
                                } icon: {
                                    Image(systemName: result.category.icon)
                                }
                                    .font(.caption)
                                    .foregroundStyle(result.category.color)

                                Spacer()

                                Button {
                                    openSearchResult(result)
                                } label: {
                                    Label("Show Setting", systemImage: "arrow.right.circle")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.sortyBordered)
                                .controlSize(.small)
                                .minimumHitTarget()
                            }
                        }
                    }
                }
            }
        }
    }

    private func openSearchResult(_ result: SettingsFeatureMatch) {
        let target = result.category.focusTarget(for: result.snippet)
        let destinationCategory = target?.category ?? result.category

        selectedCategory = destinationCategory
        searchText = ""
        appState.openSettingsWindow(
            section: destinationCategory,
            focusTarget: target
        )
        HapticFeedbackManager.shared.selection()
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsView()
        case .rules:
            OrganizationRulesSettingsView()
                .environmentObject(appState)
                .environmentObject(viewModel)
        case .provider:
            AIProviderSettingsView().environmentObject(viewModel)
        case .strategy:
            OrganizationStrategySettingsView().environmentObject(viewModel)
        case .automation:
            AutomationSettingsView()
                .environmentObject(viewModel)
                .environmentObject(appState)
        case .deeplinks:
            VStack(alignment: .leading, spacing: 20) {
                CodexSkillInstallerCard()
                    .settingsFocusable(.deeplinksSortySkill)
                DeeplinkSettingsView()
            }
        case .finder:
            FinderIntegrationSettingsView()
        case .notifications:
            NotificationsSettingsView()
        case .permissions:
            PermissionsSettingsView()
                .environmentObject(appState)
        case .advanced:
            AdvancedSettingsView().environmentObject(viewModel)
        case .troubleshooting:
            TroubleshootingSettingsView().environmentObject(viewModel)
        case .help:
            HelpSettingsView().environmentObject(appState)
        case .experimental:
            ExperimentalSettingsView()
        }
    }

    private func routeToFocusedSetting(using proxy: ScrollViewProxy) {
        guard !isSearching else { return }
        guard let target = appState.settingsFocusTarget else { return }

        let targetCategory = target.category
        if selectedCategory != targetCategory {
            selectedCategory = targetCategory
        }
        if appState.selectedSettingsSection != targetCategory {
            appState.selectedSettingsSection = targetCategory
        }

        DispatchQueue.main.async {
            guard !isSearching,
                  appState.settingsFocusTarget == target,
                  selectedCategory == targetCategory
            else {
                return
            }

            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                proxy.scrollTo(target.rawValue, anchor: .center)
            }

            // Leaving search results or switching categories swaps the whole
            // content tree, and the first attempt can run before SwiftUI has
            // mounted the target, silently scrolling nowhere. Re-issue after
            // layout settles; each attempt is idempotent and still guarded by
            // the live focus target.
            for delay in [0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard !isSearching,
                          appState.settingsFocusTarget == target,
                          selectedCategory == targetCategory
                    else {
                        return
                    }
                    proxy.scrollTo(target.rawValue, anchor: .center)
                }
            }
        }
    }

    private var settingsLayout: some View {
        HStack(spacing: 0) {
            ScrollView {
                settingsSidebar
            }
            .frame(width: 224)
            .background(Color(NSColor.windowBackgroundColor))
            .animatedAppearance(delay: 0.03)
            Divider()
            contentView
                .animatedAppearance(delay: 0.08)
        }
    }

    private var trackedSettingsLayout: some View {
        settingsLayout
        .overlay {
            WindowLinkHoverPillOverlay(hoverState: windowLinkHoverState)
        }
        .navigationTitle("Settings")
        .searchable(text: $searchText, prompt: "Search settings")
        .environment(\.windowLinkHoverUpdate) { hovering, url, sourceID in
            MainActor.assumeIsolated {
                windowLinkHoverState.setHovering(hovering, url: url, sourceID: sourceID)
            }
        }
        .onAppear {
            if let section = appState.selectedSettingsSection {
                selectedCategory = section
            }
            captureSettingsScreen(selectedCategory)
        }
        .onChange(of: selectedCategory) { _, category in
            captureSettingsScreen(category)
        }
        .onChange(of: analytics.consent) { _, consent in
            guard consent == .granted else { return }
            captureSettingsScreen(selectedCategory, source: "consent")
        }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private enum SettingsPreviewObjects {
    static var appStateWithSection: (_ section: SettingsCategory) -> AppState {
        { section in
            let state = AppState()
            state.selectedSettingsSection = section
            return state
        }
    }
}

#Preview("Settings - Rules") {
    SettingsView()
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(SettingsPreviewObjects.appStateWithSection(.rules))
        .frame(width: 900, height: 700)
}

#Preview("Settings - Provider") {
    SettingsView()
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(SettingsPreviewObjects.appStateWithSection(.provider))
        .frame(width: 900, height: 700)
}

#Preview("Settings - Strategy") {
    SettingsView()
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(SettingsPreviewObjects.appStateWithSection(.strategy))
        .frame(width: 900, height: 700)
}

#Preview("Settings - Notifications") {
    SettingsView()
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(SettingsPreviewObjects.appStateWithSection(.notifications))
        .frame(width: 900, height: 700)
}

#Preview("Settings - Advanced") {
    SettingsView()
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(SettingsPreviewObjects.appStateWithSection(.advanced))
        .frame(width: 900, height: 700)
}

#endif
