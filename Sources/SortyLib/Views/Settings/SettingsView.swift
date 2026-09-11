//
//  SettingsView.swift
//  Sorty
//
//  Lightweight settings container with sidebar navigation
//

import SwiftUI

struct SettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState
    @ObservedObject private var analytics = AnalyticsManager.shared
    @State private var selectedCategory: SettingsCategory = .rules
    @State private var searchText = ""
    @StateObject private var windowLinkHoverState = WindowLinkHoverState()

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearchText.isEmpty
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                settingsSidebar
                    .frame(width: 200)
                    .animatedAppearance(delay: 0.03)
                Divider()
                contentView
                    .animatedAppearance(delay: 0.08)
            }

            WindowLinkHoverPillOverlay(hoverState: windowLinkHoverState)
        }
        .navigationTitle("Settings")
        .searchable(text: $searchText, prompt: "Search settings")
        .environment(\.windowLinkHoverUpdate) { hovering, url, sourceID in
            windowLinkHoverState.setHovering(hovering, url: url, sourceID: sourceID)
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
            windowLinkHoverState.clearAllHover()
        }
    }

    private var settingsSidebar: some View {
        let categories = filteredCategories
        let categoriesByGroup = Dictionary(grouping: categories, by: \.group)
        let groups = SettingsCategoryGroup.allCases.filter { categoriesByGroup[$0]?.isEmpty == false }

        return VStack(alignment: .leading, spacing: 4) {
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
                    sectionHeader(group.rawValue)
                    ForEach(categoriesByGroup[group] ?? []) { category in
                        SidebarButton(
                            title: category.rawValue,
                            icon: category.icon,
                            color: category.color,
                            isSelected: selectedCategory == category
                        ) {
                            appState.openSettingsWindow(section: category)
                            HapticFeedbackManager.shared.selection()
                        }
                        .help("\(category.rawValue) settings")
                        .accessibilityHint("Open \(category.rawValue) settings")
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func sectionHeader(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
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
                            categoryHeader
                                .animatedAppearance(delay: 0.03)
                            Group {
                                categoryContent
                                    .settingsFocusTarget(appState.settingsFocusTarget)
                                    .settingsFocusDismissAction { target in
                                        guard appState.settingsFocusTarget == target else { return }
                                        appState.settingsFocusTarget = nil
                                    }
                            }
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
            Image(systemName: selectedCategory.icon)
                .font(.title2)
                .foregroundStyle(selectedCategory.color)
                .frame(width: 32, height: 32)
                .symbolReplaceTransition(animationValue: selectedCategory)
                .background(selectedCategory.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(LocalizedStringKey(selectedCategory.rawValue))
                .font(.title2.bold())
                .numericTextTransition(animationValue: selectedCategory)
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
            DeeplinkSettingsView()
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
}

// MARK: - Previews

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
