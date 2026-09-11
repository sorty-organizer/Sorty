//
//  ModelSelector.swift
//  Sorty
//
//  Unified model selection component for consistent UX across the app
//

import AppKit
import SwiftUI

/// Drops the window's AppKit first responder so an in-window overlay can take
/// keyboard focus. Without this a focused `NSTextField`/`NSSecureTextField`
/// behind the overlay keeps first responder status (and keeps drawing its focus
/// ring on top of the overlay), swallowing typing meant for the overlay.
@MainActor
private func resignWindowFirstResponder() {
    let window = NSApp.keyWindow ?? NSApp.mainWindow
    window?.makeFirstResponder(nil)
}

// MARK: - Model Selector Row (Compact Display + Trigger)

struct ModelSelectorRow: View {
    @SortyHotReload private var hotReload
    let provider: AIProvider
    let model: String
    let onTap: () -> Void
    
    var body: some View {
        Button {
            HapticFeedbackManager.shared.light()
            onTap()
        } label: {
            HStack(spacing: 10) {
                ProviderLogoView(provider: provider, size: 16)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .numericTextTransition(animationValue: provider)
                    Text(model.isEmpty ? provider.defaultModel : model)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .numericTextTransition(
                            animationValue: model.isEmpty ? provider.defaultModel : model
                        )
                }

                Spacer()

                Text("Change")
                    .font(.caption)
                    .foregroundColor(.accentColor)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model Selector Compact Button (Inline Value + Trigger)

/// A compact, menu-picker-sized trigger that shows the current selection and
/// opens the model selection popover. Use in settings rows where the
/// full-width `ModelSelectorRow` would be too heavy.
struct ModelSelectorCompactButton: View {
    @SortyHotReload private var hotReload
    let provider: AIProvider
    let label: String
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            HapticFeedbackManager.shared.light()
            onTap()
        } label: {
            HStack(spacing: 6) {
                ProviderLogoView(provider: provider, size: 12)

                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 10)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: 220)
            .background {
                if #unavailable(macOS 26.0) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.1 : 0.06))
                }
            }
            .systemLiquidGlassBackground(cornerRadius: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovering ? 0.2 : 0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovering ? 0.09 : 0.05), radius: isHovering ? 6 : 3, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel("\(provider.displayName), \(label). Change model")
    }
}

private struct ModelSelectionTriggerBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    func modelSelectorTriggerBounds() -> some View {
        anchorPreference(key: ModelSelectionTriggerBoundsPreferenceKey.self, value: .bounds) { $0 }
    }

    func modelSelectionOverlay(
        isPresented: Binding<Bool>,
        currentProvider: AIProvider,
        currentModel: String,
        contextMessage: String? = nil,
        selectionActionTitle: String = "Select",
        isSelectionActionProminent: Bool = true,
        resetActionTitle: String? = nil,
        onReset: (() -> Void)? = nil,
        reasoningEffortForModel: ((AIProvider, String) -> ReasoningEffort)? = nil,
        onSelectReasoningEffort: ((ReasoningEffort) -> Void)? = nil,
        onSelect: @escaping (AIProvider, String, ProviderAuthMethod?) -> Void,
        isSubscriptionSelected: Bool = false
    ) -> some View {
        modifier(
            ModelSelectionOverlayModifier(
                isPresented: isPresented,
                currentProvider: currentProvider,
                currentModel: currentModel,
                contextMessage: contextMessage,
                selectionActionTitle: selectionActionTitle,
                isSelectionActionProminent: isSelectionActionProminent,
                resetActionTitle: resetActionTitle,
                onReset: onReset,
                reasoningEffortForModel: reasoningEffortForModel,
                onSelectReasoningEffort: onSelectReasoningEffort,
                onSelect: onSelect,
                isSubscriptionSelected: isSubscriptionSelected
            )
        )
    }
}

// MARK: - Model Selection Popover (Two-Column Layout)

struct ModelSelectionPopover: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var isSearchAccessibilityFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @Binding var isPresented: Bool
    let currentProvider: AIProvider
    let currentModel: String
    let contextMessage: String?
    let selectionActionTitle: String
    let isSelectionActionProminent: Bool
    let resetActionTitle: String?
    let onReset: (() -> Void)?
    let reasoningEffortForModel: ((AIProvider, String) -> ReasoningEffort)?
    let onSelectReasoningEffort: ((ReasoningEffort) -> Void)?
    let popoverSize: CGSize
    let onSelect: (AIProvider, String, ProviderAuthMethod?) -> Void
    let isSubscriptionSelected: Bool

    private let cornerRadius: CGFloat = 12
    
    @StateObject private var modelCatalog = ModelCatalog.shared
    
    @State private var selectedProvider: AIProvider = .openAI
    @State private var selectedModel: String = ""
    @State private var selectedReasoningEffort: ReasoningEffort = .automatic
    @State private var searchText: String = ""
    @State private var showAllModels: Bool = false
    @State private var customModelText: String = ""
    @State private var showCustomInput: Bool = false
    @State private var showFreeOnly: Bool = false
    @State private var showCodexOnly: Bool = false
    @State private var isContextMessageVisible = true
    @AppStorage("hasDismissedModelPickerGuidance") private var hasDismissedGuidance = false
    @AppStorage(CodexSubscriptionSettings.fastModeKey) private var isCodexFastModeEnabled = false
    @AppStorage(FastModeSettings.openAIFastModeKey) private var isOpenAIFastModeEnabled = false
    @AppStorage(FastModeSettings.openRouterFastModeKey) private var isOpenRouterFastModeEnabled = false

    init(
        isPresented: Binding<Bool>,
        currentProvider: AIProvider,
        currentModel: String,
        contextMessage: String? = nil,
        selectionActionTitle: String = "Select",
        isSelectionActionProminent: Bool = true,
        resetActionTitle: String? = nil,
        onReset: (() -> Void)? = nil,
        reasoningEffortForModel: ((AIProvider, String) -> ReasoningEffort)? = nil,
        onSelectReasoningEffort: ((ReasoningEffort) -> Void)? = nil,
        popoverSize: CGSize = CGSize(width: 500, height: 420),
        onSelect: @escaping (AIProvider, String, ProviderAuthMethod?) -> Void,
        isSubscriptionSelected: Bool = false
    ) {
        self._isPresented = isPresented
        self.currentProvider = currentProvider
        self.currentModel = currentModel
        self.contextMessage = contextMessage
        self.selectionActionTitle = selectionActionTitle
        self.isSelectionActionProminent = isSelectionActionProminent
        self.resetActionTitle = resetActionTitle
        self.onReset = onReset
        self.reasoningEffortForModel = reasoningEffortForModel
        self.onSelectReasoningEffort = onSelectReasoningEffort
        self.popoverSize = popoverSize
        self.onSelect = onSelect
        self.isSubscriptionSelected = isSubscriptionSelected
        self._showCodexOnly = State(initialValue: isSubscriptionSelected && currentProvider == .openAI && FeatureFlags.subscriptionAuthEnabled)
    }
    
    private var availableProviders: [AIProvider] {
        AIProvider.userSelectableProviders.filter { $0.isAvailable }
    }
    
    private var filteredProviders: [AIProvider] {
        if searchText.isEmpty {
            return availableProviders
        }
        return availableProviders.filter { provider in
            provider.displayName.localizedCaseInsensitiveContains(searchText) ||
            getModelsForProvider(provider).contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    private var modelsForSelectedProvider: [String] {
        var models = getModelsForProvider(selectedProvider)

        // Filter free models for OpenRouter if toggled
        if showFreeOnly && selectedProvider == .openRouter {
            let catalogModels = modelCatalog.cachedModels(for: selectedProvider)
            let freeIds = Set(catalogModels.filter { $0.isFree }.map { $0.id })
            models = models.filter { freeIds.contains($0) }
        }

        // Filter Codex (subscription) models for OpenAI if toggled
        if showCodexOnly && selectedProvider == .openAI {
            models = modelCatalog.codexSubscriptionModels.map(\.id)
        }

        if !searchText.isEmpty {
            models = models.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
        return showAllModels || !searchText.isEmpty ? models : Array(models.prefix(10))
    }

    /// Returns whether a model ID is free (for badge display)
    private func isModelFree(_ modelId: String) -> Bool {
        let catalogModels = modelCatalog.cachedModels(for: selectedProvider)
        return catalogModels.first(where: { $0.id == modelId })?.isFree ?? false
    }

    private func isCodexModel(_ modelId: String) -> Bool {
        modelCatalog.isCodexSubscriptionModel(modelId)
    }

    private func codexFastModeAvailability(for modelId: String) -> Bool? {
        guard let model = modelCatalog.codexSubscriptionModels.first(where: { $0.id == modelId }) else {
            return nil
        }
        return model.capabilities?.contains("service:priority") == true
    }

    private func supportsCodexFastMode(_ modelId: String) -> Bool {
        codexFastModeAvailability(for: modelId) == true
    }

    private func fastModeRow(
        isOn: Binding<Bool>,
        disabled: Bool,
        helpText: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.orange)

            Text("Fast mode")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            Toggle("Fast mode", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .help(helpText)
    }

    /// Codex and API-key fetches share the OpenAI provider but fail independently;
    /// only surface the error for the auth mode currently on screen.
    private var activeFetchError: Error? {
        if selectedProvider == .openAI && showCodexOnly {
            return modelCatalog.lastCodexError
        }
        return modelCatalog.lastError[selectedProvider] as? Error
    }

    /// Prefers the actionable failure reason (e.g. the Codex CLI message) over the generic description.
    private func fetchErrorMessage(for error: Error) -> String {
        if let aiError = error as? AIClientError,
           let reason = aiError.failureReason,
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return reason
        }
        return error.localizedDescription
    }

    /// Returns whether a model supports vision (for badge display)
    private func isVisionModel(_ modelId: String) -> Bool {
        modelCatalog.supportsVision(modelId: modelId, provider: selectedProvider)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let contextMessage, !contextMessage.isEmpty, isContextMessageVisible, !hasDismissedGuidance {
                contextMessageView(message: contextMessage)
                Divider()
            }
            twoColumnContent
            Divider()
            footer
        }
        .frame(width: popoverSize.width, height: popoverSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .modifier(ModelSelectionPopoverGlassModifier(cornerRadius: cornerRadius))
        .onAppear {
            selectedProvider = currentProvider
            selectedModel = currentModel
            selectedReasoningEffort = reasoningEffortForModel?(currentProvider, currentModel) ?? .automatic
        }
        .task {
            // Take keyboard focus away from whatever field is focused behind the
            // overlay before claiming it for the search field.
            resignWindowFirstResponder()
            await Task.yield()
            isSearchFocused = true
            isSearchAccessibilityFocused = true
            await modelCatalog.refresh(provider: currentProvider, authMethod: selectedAuthMethod)
        }
        .onChange(of: showCodexOnly) { _, isEnabled in
            guard selectedProvider == .openAI else { return }
            selectedModel = ""
            Task {
                await modelCatalog.refresh(
                    provider: .openAI,
                    authMethod: isEnabled ? .accountSignIn : .apiKey
                )
            }
        }
        .onChange(of: selectedModel) { _, model in
            if showCodexOnly && (model.isEmpty || codexFastModeAvailability(for: model) == false) {
                isCodexFastModeEnabled = false
            }
            refreshSelectedReasoningEffort(for: model)
        }
        .onChange(of: modelCatalog.codexSubscriptionModels) { _, _ in
            if codexFastModeAvailability(for: selectedModel) == false {
                isCodexFastModeEnabled = false
            }
        }
    }

    private func contextMessageView(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 12))

            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                HapticFeedbackManager.shared.light()
                hasDismissedGuidance = true
                if reduceMotion {
                    isContextMessageVisible = false
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isContextMessageVisible = false
                    }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss guidance")
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SortyDesignSystem.Colors.resolvedAccent.opacity(0.05))
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            
            TextField("Search providers or models...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                .accessibilityFocused($isSearchAccessibilityFocused)
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            
            Spacer()

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(chromeBackground)
    }
    
    // MARK: - Two Column Content
    
    private var twoColumnContent: some View {
        HStack(spacing: 0) {
            providerList
            
            Divider()
            
            modelList
        }
    }
    
    private var providerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PROVIDER")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredProviders, id: \.self) { provider in
                        providerRow(provider)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 160)
        .background(sidebarBackground)
    }
    
    private func providerRow(_ provider: AIProvider) -> some View {
        Button {
            guard provider != selectedProvider else { return }
            HapticFeedbackManager.shared.selection()
            withAnimation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.3, dampingFraction: 0.82)
            ) {
                selectedProvider = provider
                selectedModel = ""
                showCustomInput = false
            }
            Task {
                await modelCatalog.refresh(provider: provider, authMethod: selectedAuthMethod)
            }
        } label: {
            HStack(spacing: 8) {
                ProviderLogoView(provider: provider, size: 12)
                    .foregroundColor(selectedProvider == provider ? .white : .accentColor)
                    .frame(width: 16)

                Text(provider.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(selectedProvider == provider ? .white : .primary)
                    .lineLimit(1)

                Spacer()

                if provider == currentProvider {
                    Circle()
                        .fill(selectedProvider == provider ? Color.white.opacity(0.8) : Color.green)
                        .frame(width: 6, height: 6)
                }

                if modelCatalog.isFetching[provider] ?? false {
                    SortyGradientCircularLoader(size: 9, lineWidth: 1.8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedProvider == provider ? SortyDesignSystem.Colors.resolvedAccent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var modelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("MODEL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer()

                if selectedProvider == .openRouter {
                    HStack(spacing: 4) {
                        Text("Free")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Toggle("", isOn: $showFreeOnly)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                    .fixedSize()
                    .help("Show only free models")
                }

                if selectedProvider == .openAI && FeatureFlags.subscriptionAuthEnabled {
                    HStack(spacing: 4) {
                        Text("Codex")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Toggle("", isOn: $showCodexOnly)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                    .fixedSize()
                    .help("Show only Codex (ChatGPT subscription) models")
                }

                Button {
                    Task {
                        if showCodexOnly && selectedProvider == .openAI {
                            await modelCatalog.refreshCodexSubscriptionModels(force: true)
                        } else {
                            await modelCatalog.refresh(provider: selectedProvider, force: true, authMethod: selectedAuthMethod)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9))
                        Text("Refresh")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(modelCatalog.isFetching[selectedProvider] ?? false)
                .help("Refresh model list from provider")
                
                if getModelsForProvider(selectedProvider).count > 10 {
                    Button {
                        showAllModels.toggle()
                    } label: {
                        Text(showAllModels ? "Show Less" : "Show All")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                            .numericTextTransition(animationValue: showAllModels)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if selectedProvider == .openAI && showCodexOnly {
                fastModeRow(
                    isOn: $isCodexFastModeEnabled,
                    disabled: !supportsCodexFastMode(selectedModel),
                    helpText: supportsCodexFastMode(selectedModel)
                        ? "Use Codex's faster priority service tier"
                        : "Fast mode isn't available for this model"
                )
            } else if selectedProvider == .openAI {
                fastModeRow(
                    isOn: $isOpenAIFastModeEnabled,
                    disabled: false,
                    helpText: "Use OpenAI's fast service tier (billed at a premium)"
                )
            } else if selectedProvider == .openRouter {
                fastModeRow(
                    isOn: $isOpenRouterFastModeEnabled,
                    disabled: false,
                    helpText: "Prefer higher token throughput; provider prices may vary"
                )
            }
            
            ScrollView {
                LazyVStack(spacing: 2) {
                    if let error = activeFetchError {
                        errorView(error)
                    }
                    
                    if modelCatalog.usingFallback[selectedProvider] ?? false {
                        fallbackWarningView
                    }

                    if modelCatalog.isFetching[selectedProvider] ?? false {
                        modelListSkeleton
                    } else {
                        ForEach(modelsForSelectedProvider, id: \.self) { model in
                            modelRow(model)
                                .transition(modelRowTransition)
                        }
                    }
                    
                    if !showCustomInput {
                        customModelButton
                    } else {
                        customModelInput
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private func modelRow(_ model: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.1)) {
                selectedModel = model
                showCustomInput = false
            }
        } label: {
            HStack(spacing: 8) {
                Text(model)
                    .font(.system(size: 12))
                    .foregroundColor(selectedModel == model ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if isVisionModel(model) {
                    HStack(spacing: 3) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Vision")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(selectedModel == model ? .white : .teal)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(selectedModel == model ? Color.white.opacity(0.2) : Color.teal.opacity(0.15))
                    )
                    .fixedSize()
                }

                if selectedProvider == .openRouter && isModelFree(model) {
                    Text("Free")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(selectedModel == model ? .white : .green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(selectedModel == model ? Color.white.opacity(0.2) : Color.green.opacity(0.15))
                        )
                        .fixedSize()
                }

                if selectedProvider == .openAI && isCodexModel(model) {
                    Text("Codex")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(selectedModel == model ? .white : .purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(selectedModel == model ? Color.white.opacity(0.2) : Color.purple.opacity(0.15))
                        )
                        .fixedSize()
                }

                Spacer()

                if model == selectedProvider.defaultModel {
                    Text("Default")
                        .font(.system(size: 9))
                        .foregroundColor(selectedModel == model ? .white.opacity(0.8) : .secondary)
                        .fixedSize()
                }

                if model == currentModel && selectedProvider == currentProvider {
                    Text("Current")
                        .font(.system(size: 9))
                        .foregroundColor(selectedModel == model ? .white.opacity(0.8) : .green)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedModel == model ? SortyDesignSystem.Colors.resolvedAccent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func errorView(_ error: Error) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: 12))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Fetch Failed")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.red)
                Text(fetchErrorMessage(for: error))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
        .cornerRadius(6)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
    
    private var fallbackWarningView: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12))
            
            Text("Using offline model list")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var modelListSkeleton: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 140, height: 12)
                Spacer()
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 52, height: 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .shimmer(isLoading: true)
            .accessibilityHidden(true)
        }
    }
    
    private var customModelButton: some View {
        Button {
            showCustomInput = true
            customModelText = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Use custom model ID...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var customModelInput: some View {
        HStack(spacing: 6) {
            TextField("model-id", text: $customModelText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(customFieldBackground)
            
            Button("Use") {
                if !customModelText.isEmpty {
                    selectedModel = customModelText
                    showCustomInput = false
                }
            }
            .buttonStyle(.sortyBordered)
            .controlSize(.small)
            .disabled(customModelText.isEmpty)
            
            Button {
                showCustomInput = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
    
    // MARK: - Footer
    
    private var selectedAuthMethod: ProviderAuthMethod? {
        guard selectedProvider == .openAI else { return nil }
        return showCodexOnly ? .accountSignIn : .apiKey
    }

    private var isFastBadgeVisible: Bool {
        switch selectedProvider {
        case .openAI:
            if showCodexOnly {
                return isCodexFastModeEnabled && supportsCodexFastMode(selectedModel)
            }
            return isOpenAIFastModeEnabled
        case .openRouter:
            return isOpenRouterFastModeEnabled
        case .githubCopilot, .groq, .openAICompatible, .ollama, .anthropic, .gemini, .appleFoundationModel:
            return false
        }
    }

    private var footer: some View {
        HStack {
            if !selectedModel.isEmpty {
                HStack(spacing: 4) {
                    ProviderLogoView(provider: selectedProvider, size: 12)
                    Text("\(selectedProvider.displayName) / \(selectedModel)")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .numericTextTransition(
                            animationValue: "\(selectedProvider.rawValue)-\(selectedModel)"
                        )
                    if isFastBadgeVisible {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .fixedSize()
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                            .help("Fast mode enabled")
                            .accessibilityLabel("Fast mode enabled")
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isFastBadgeVisible)
            } else {
                Text("Select a model")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()

            if onSelectReasoningEffort != nil, !reasoningOptions.isEmpty {
                Picker("Reasoning effort", selection: $selectedReasoningEffort) {
                    ForEach(reasoningOptions, id: \.self) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 104)
                .foregroundColor(.primary)
                .tint(.primary)
                .help(reasoningHelpText)
                .accessibilityLabel("Reasoning effort")
                .accessibilityValue(selectedReasoningEffort.displayName)
                .accessibilityHint(reasoningHelpText)
                .accessibilityIdentifier("ReasoningEffortPicker")
            }
            
            if let resetActionTitle, let onReset {
                Button(resetActionTitle) {
                    HapticFeedbackManager.shared.selection()
                    onReset()
                    isPresented = false
                }
                .buttonStyle(.sortyBordered)
            }

            Button("Cancel") {
                isPresented = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .keyboardShortcut(.escape, modifiers: [])
            
            Button(selectionActionTitle) {
                onSelect(selectedProvider, selectedModel, selectedAuthMethod)
                onSelectReasoningEffort?(selectedReasoningEffort)
                isPresented = false
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(selectionActionButtonStyle)
            .disabled(selectedModel.isEmpty || (modelCatalog.isFetching[selectedProvider] ?? false))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(chromeBackground)
    }

    private var selectionActionButtonStyle: SortyStandardButtonStyle {
        isSelectionActionProminent ? .sortyProminent : .sortyBordered(intent: .primary)
    }

    private var reasoningConfiguration: (efforts: [ReasoningEffort], defaultEffort: ReasoningEffort?)? {
        modelCatalog.reasoningConfiguration(for: selectedModel, provider: selectedProvider)
    }

    private var reasoningOptions: [ReasoningEffort] {
        guard let efforts = reasoningConfiguration?.efforts else { return [] }
        return [.automatic] + efforts.filter { $0 != .automatic }
    }

    private var reasoningHelpText: String {
        if selectedReasoningEffort == .automatic,
           let defaultEffort = reasoningConfiguration?.defaultEffort {
            return "Uses the model default: \(defaultEffort.displayName)."
        }
        return selectedReasoningEffort.helpText
    }

    private func refreshSelectedReasoningEffort(for model: String) {
        let saved = reasoningEffortForModel?(selectedProvider, model) ?? .automatic
        selectedReasoningEffort = reasoningOptions.contains(saved) ? saved : .automatic
    }

    @ViewBuilder
    private var chromeBackground: some View {
        if #available(macOS 26.0, *) {
            Color.white.opacity(0.02)
        } else {
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.05),
                    Color.primary.opacity(0.015)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        if #available(macOS 26.0, *) {
            Color.white.opacity(0.015)
        } else {
            LinearGradient(
                colors: [
                    SortyDesignSystem.Colors.resolvedAccent.opacity(0.08),
                    Color.primary.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var customFieldBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
    
    // MARK: - Helpers
    
    private func getModelsForProvider(_ provider: AIProvider) -> [String] {
        let catalogModels = modelCatalog.cachedModels(for: provider)
        if !catalogModels.isEmpty {
            return catalogModels.map { $0.id }
        }
        return provider.recommendedModels
    }

    private var modelRowTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }

        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.96, anchor: .top))
                .combined(with: .offset(y: 5)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }
}

private struct ModelSelectionPopoverGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .systemLiquidGlassPopover(cornerRadius: cornerRadius)
    }
}

private struct ModelSelectionOverlayModifier: ViewModifier {
    @Binding var isPresented: Bool
    let currentProvider: AIProvider
    let currentModel: String
    let contextMessage: String?
    let selectionActionTitle: String
    let isSelectionActionProminent: Bool
    let resetActionTitle: String?
    let onReset: (() -> Void)?
    let reasoningEffortForModel: ((AIProvider, String) -> ReasoningEffort)?
    let onSelectReasoningEffort: ((ReasoningEffort) -> Void)?
    let onSelect: (AIProvider, String, ProviderAuthMethod?) -> Void
    let isSubscriptionSelected: Bool

    private let contentPadding: CGFloat = 12
    private let idealPopoverSize = CGSize(width: 500, height: 420)

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(ModelSelectionTriggerBoundsPreferenceKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor {
                        let frame = proxy[anchor]

                        Color.clear
                            .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                            .popover(
                                isPresented: $isPresented,
                                attachmentAnchor: .rect(.bounds),
                                arrowEdge: .bottom
                            ) {
                                ModelSelectionPopover(
                                    isPresented: $isPresented,
                                    currentProvider: currentProvider,
                                    currentModel: currentModel,
                                    contextMessage: contextMessage,
                                    selectionActionTitle: selectionActionTitle,
                                    isSelectionActionProminent: isSelectionActionProminent,
                                    resetActionTitle: resetActionTitle,
                                    onReset: onReset,
                                    reasoningEffortForModel: reasoningEffortForModel,
                                    onSelectReasoningEffort: onSelectReasoningEffort,
                                    popoverSize: resolvedPopoverSize,
                                    onSelect: onSelect,
                                    isSubscriptionSelected: isSubscriptionSelected
                                )
                            }
                    }
                }
            }
            .onChange(of: isPresented) { _, presented in
                guard presented else { return }
                resignWindowFirstResponder()
            }
    }

    private var resolvedPopoverSize: CGSize {
        let activeScreen = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen ?? NSScreen.main
        guard let screenSize = activeScreen?.visibleFrame.size else {
            return idealPopoverSize
        }

        return CGSize(
            width: min(idealPopoverSize.width, max(0, screenSize.width - (contentPadding * 2))),
            height: min(idealPopoverSize.height, max(0, screenSize.height - (contentPadding * 2)))
        )
    }

}

// MARK: - Preview

#Preview {
    ModelSelectionPopover(
        isPresented: .constant(true),
        currentProvider: .openAI,
        currentModel: "gpt-4o",
        contextMessage: nil,
        selectionActionTitle: "Select",
        onSelect: { _, _, _ in }
    )
}
