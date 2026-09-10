//
//  SettingsCategory.swift
//  Sorty
//
//  Shared settings category enum and utilities
//

import SwiftUI

public struct SettingsFeatureSnippet: Identifiable, Hashable {
    public let title: String
    public let summary: String
    public let keywords: [String]
    public let focusTarget: SettingsFocusTarget?

    public var id: String { "\(title)|\(summary)" }

    public init(
        title: String,
        summary: String,
        keywords: [String] = [],
        focusTarget: SettingsFocusTarget? = nil
    ) {
        self.title = title
        self.summary = summary
        self.keywords = keywords
        self.focusTarget = focusTarget
    }
}

public struct SettingsFeatureMatch: Identifiable, Hashable {
    public let category: SettingsCategory
    public let snippet: SettingsFeatureSnippet
    public let score: Int

    public var id: String { "\(category.rawValue)|\(snippet.id)" }
}

public enum SettingsFocusTarget: String, CaseIterable, Hashable, Sendable {
    case providerSelect = "settings.provider.select"
    case providerConfiguration = "settings.provider.configuration"
    case providerConnection = "settings.provider.connection"
    case providerOpenAI = "settings.provider.openai"
    case providerGitHubCopilot = "settings.provider.github-copilot"
    case providerGroq = "settings.provider.groq"
    case providerCompatibleAPI = "settings.provider.compatible-api"
    case providerOpenRouter = "settings.provider.openrouter"
    case providerOllama = "settings.provider.ollama"
    case providerAnthropic = "settings.provider.anthropic"
    case providerGemini = "settings.provider.gemini"
    case providerApple = "settings.provider.apple"
    case providerTestConnection = "settings.provider.test-connection"
    case strategyFastMode = "settings.strategy.fast-mode"
    case strategyVision = "settings.strategy.vision"
    case strategyRenaming = "settings.strategy.renaming"
    case strategyNamingTemplate = "settings.strategy.naming-template"
    case strategyNamingOptions = "settings.strategy.naming-options"
    case strategyNamingSeparator = "settings.strategy.naming-separator"
    case strategyNamingCase = "settings.strategy.naming-case"
    case strategyNamingDatePolicy = "settings.strategy.naming-date-policy"
    case strategyMaxFilenameLength = "settings.strategy.max-filename-length"
    case strategyNamingInstructions = "settings.strategy.naming-instructions"
    case rulesContentRules = "settings.rules.content-rules"
    case rulesFileTagging = "settings.rules.file-tagging"
    case rulesOrganizationStyle = "settings.rules.organization-style"
    case automationGlobalModel = "settings.automation.global-model"
    case automationSeparateModel = "settings.automation.separate-model"
    case automationLaunchAtLogin = "settings.automation.launch-at-login"
    case automationKeepInBackground = "settings.automation.keep-in-background"
    case automationHideDockIcon = "settings.automation.hide-dock-icon"
    case deeplinksOpenApp = "settings.deeplinks.open-app"
    case deeplinksSettings = "settings.deeplinks.settings"
    case deeplinksHelp = "settings.deeplinks.help"
    case deeplinksHistory = "settings.deeplinks.history"
    case deeplinksOrganizeFolder = "settings.deeplinks.organize-folder"
    case deeplinksDuplicates = "settings.deeplinks.duplicates"
    case deeplinksStorage = "settings.deeplinks.storage"
    case deeplinksWatchedFolders = "settings.deeplinks.watched-folders"
    case deeplinksRules = "settings.deeplinks.rules"
    case deeplinksExclusions = "settings.deeplinks.exclusions"
    case deeplinksPersona = "settings.deeplinks.persona"
    case deeplinksLearnings = "settings.deeplinks.learnings"
    case deeplinksProviderSettings = "settings.deeplinks.provider-settings"
    case deeplinksFinderOrganize = "settings.deeplinks.finder-organize"
    case deeplinksFinderWatch = "settings.deeplinks.finder-watch"
    case deeplinksFinderExclude = "settings.deeplinks.finder-exclude"
    case deeplinksFinderSettings = "settings.deeplinks.finder-settings"
    case finderIntegration = "settings.finder.integration"
    case finderCheckStatus = "settings.finder.check-status"
    case finderOrganize = "settings.finder.organize"
    case finderWatch = "settings.finder.watch"
    case finderExclude = "settings.finder.exclude"
    case finderExtension = "settings.finder.extension"
    case finderAutomationPermission = "settings.finder.automation-permission"
    case notificationsPermission = "settings.notifications.permission"
    case notificationsInAppHUD = "settings.notifications.in-app-hud"
    case notificationsSystem = "settings.notifications.system"
    case notificationsTypes = "settings.notifications.types"
    case notificationsProcessingComplete = "settings.notifications.processing-complete"
    case notificationsPreviewReady = "settings.notifications.preview-ready"
    case notificationsProcessingErrors = "settings.notifications.processing-errors"
    case notificationsWatchedFolderStarted = "settings.notifications.watched-folder-started"
    case notificationsWatchedFolderFinished = "settings.notifications.watched-folder-finished"
    case notificationsCompletionSound = "settings.notifications.completion-sound"
    case permissionsFilesAndFolders = "settings.permissions.files-and-folders"
    case permissionsFullDiskAccess = "settings.permissions.full-disk-access"
    case permissionsAutomation = "settings.permissions.automation"
    case permissionsNotifications = "settings.permissions.notifications"
    case permissionsStatusActions = "settings.permissions.status-actions"
    case permissionsUsage = "settings.permissions.usage"
    case advancedMenuBar = "settings.advanced.menu-bar"
    case advancedFinderWorkflow = "settings.advanced.finder-workflow"
    case advancedPrivacyMode = "settings.advanced.privacy-mode"
    case advancedInternetPrivacy = "settings.advanced.internet-privacy"
    case advancedAnalytics = "settings.advanced.analytics"
    case advancedTimeouts = "settings.advanced.timeouts"
    case advancedRequestTimeout = "settings.advanced.request-timeout"
    case advancedResourceTimeout = "settings.advanced.resource-timeout"
    case advancedDeveloper = "settings.advanced.developer"
    case advancedStats = "settings.advanced.stats"
    case advancedErrorLogs = "settings.advanced.error-logs"
    case troubleshootingMaintenance = "settings.troubleshooting.maintenance"
    case troubleshootingCache = "settings.troubleshooting.cache"
    case troubleshootingLearnings = "settings.troubleshooting.learnings"
    case troubleshootingReset = "settings.troubleshooting.reset"
    case troubleshootingAssistant = "settings.troubleshooting.assistant"
    case helpSupport = "settings.help.support"
    case helpLegal = "settings.help.legal"
    case helpDocumentation = "settings.help.documentation"
    case helpReportIssue = "settings.help.report-issue"
    case helpChangelog = "settings.help.changelog"
    case helpPrivacy = "settings.help.privacy"
    case helpTerms = "settings.help.terms"
    case helpIssueDetails = "settings.help.issue-details"
    case experimentalEmptyState = "settings.experimental.empty-state"
}

public extension SettingsFocusTarget {
    static func providerChoice(_ provider: AIProvider) -> SettingsFocusTarget {
        switch provider {
        case .openAI:
            return .providerOpenAI
        case .githubCopilot:
            return .providerGitHubCopilot
        case .groq:
            return .providerGroq
        case .openAICompatible:
            return .providerCompatibleAPI
        case .openRouter:
            return .providerOpenRouter
        case .ollama:
            return .providerOllama
        case .anthropic:
            return .providerAnthropic
        case .gemini:
            return .providerGemini
        case .appleFoundationModel:
            return .providerApple
        }
    }

    var category: SettingsCategory {
        switch self {
        case .providerSelect, .providerConfiguration, .providerConnection,
             .providerOpenAI, .providerGitHubCopilot, .providerGroq,
             .providerCompatibleAPI, .providerOpenRouter, .providerOllama,
             .providerAnthropic, .providerGemini, .providerApple,
             .providerTestConnection:
            return .provider

        case .strategyFastMode, .strategyVision, .strategyRenaming,
             .strategyNamingTemplate, .strategyNamingOptions, .strategyNamingSeparator,
             .strategyNamingCase, .strategyNamingDatePolicy,
             .strategyMaxFilenameLength, .strategyNamingInstructions:
            return .strategy

        case .rulesContentRules, .rulesFileTagging, .rulesOrganizationStyle:
            return .rules

        case .automationGlobalModel, .automationSeparateModel, .automationLaunchAtLogin,
             .automationKeepInBackground, .automationHideDockIcon:
            return .automation

        case .deeplinksOpenApp, .deeplinksSettings, .deeplinksHelp, .deeplinksHistory,
             .deeplinksOrganizeFolder, .deeplinksDuplicates, .deeplinksStorage,
             .deeplinksWatchedFolders, .deeplinksRules, .deeplinksExclusions,
             .deeplinksPersona, .deeplinksLearnings, .deeplinksProviderSettings,
             .deeplinksFinderOrganize, .deeplinksFinderWatch, .deeplinksFinderExclude,
             .deeplinksFinderSettings:
            return .deeplinks

        case .finderIntegration, .finderCheckStatus, .finderOrganize, .finderWatch, .finderExclude,
             .finderExtension, .finderAutomationPermission:
            return .finder

        case .notificationsPermission, .notificationsInAppHUD, .notificationsSystem,
             .notificationsTypes, .notificationsProcessingComplete, .notificationsPreviewReady,
             .notificationsProcessingErrors, .notificationsWatchedFolderStarted,
             .notificationsWatchedFolderFinished, .notificationsCompletionSound:
            return .notifications

        case .permissionsFilesAndFolders, .permissionsFullDiskAccess,
             .permissionsAutomation, .permissionsNotifications,
             .permissionsStatusActions, .permissionsUsage:
            return .permissions

        case .advancedMenuBar, .advancedFinderWorkflow, .advancedPrivacyMode,
             .advancedInternetPrivacy, .advancedAnalytics, .advancedTimeouts, .advancedRequestTimeout,
             .advancedResourceTimeout, .advancedDeveloper, .advancedStats, .advancedErrorLogs:
            return .advanced

        case .troubleshootingMaintenance, .troubleshootingCache,
             .troubleshootingLearnings, .troubleshootingReset,
             .troubleshootingAssistant:
            return .troubleshooting

        case .helpSupport, .helpLegal, .helpDocumentation, .helpReportIssue,
             .helpChangelog, .helpPrivacy, .helpTerms, .helpIssueDetails:
            return .help

        case .experimentalEmptyState:
            return .experimental
        }
    }
}

public enum SettingsCategoryGroup: String, CaseIterable {
    case aiAndOrganization = "AI & Organization"
    case features = "Features"
    case system = "System"
}

public enum SettingsCategory: String, CaseIterable, Identifiable {
    case provider = "AI Provider"
    case strategy = "Analysis & Naming"
    case rules = "Organize Rules"
    case automation = "Automation"
    case deeplinks = "Deeplinks"
    case finder = "Finder Integration"
    case notifications = "Notifications"
    case permissions = "Permissions"
    case advanced = "Advanced"
    case troubleshooting = "Troubleshooting"
    case help = "Help & Support"
    case experimental = "Experimental"
    
    public var id: String { rawValue }
    
    public var group: SettingsCategoryGroup {
        switch self {
        case .provider, .strategy, .rules:
            return .aiAndOrganization
        case .automation, .deeplinks, .finder, .notifications:
            return .features
        case .permissions, .advanced, .troubleshooting, .help, .experimental:
            return .system
        }
    }
    
    public static func categories(for group: SettingsCategoryGroup) -> [SettingsCategory] {
        allCases.filter { $0.group == group }
    }
    
    public var icon: String {
        switch self {
        case .rules: return "folder.badge.gearshape"
        case .provider: return "cpu"
        case .strategy: return "wand.and.stars"
        case .automation: return "bolt.circle"
        case .deeplinks: return "link.badge.plus"
        case .finder: return "folder.badge.plus"
        case .notifications: return "bell"
        case .permissions: return "hand.raised.fill"
        case .advanced: return "gearshape.2"
        case .troubleshooting: return "wrench.and.screwdriver"
        case .help: return "questionmark.circle"
        case .experimental: return "flask"
        }
    }
    
    public var color: Color {
        switch self {
        case .rules: return .blue
        case .provider: return .purple
        case .strategy: return .orange
        case .automation: return .green
        case .deeplinks: return .cyan
        case .finder: return .cyan
        case .notifications: return .pink
        case .permissions: return .blue
        case .advanced: return .gray
        case .troubleshooting: return .red
        case .help: return .teal
        case .experimental: return .indigo
        }
    }

    public var searchKeywords: [String] {
        switch self {
        case .provider:
            return ["api key", "provider", "model", "endpoint", "token", "connection", "copilot", "ollama", "openrouter", "anthropic", "gemini"]
        case .strategy:
            return ["strategy", "analysis", "fast mode", "deep scan", "deep scanning", "content analysis", "vision", "image analysis", "naming style", "rename", "renaming", "folder structure", "organization style"]
        case .rules:
            return ["rules", "controls", "organization controls", "instructions", "tagging", "pattern"]
        case .automation:
            return ["automation", "watched folders", "auto organize", "background", "scheduler", "spring cleaning", "folder trigger", "custom model", "global model", "launch at login", "login item", "dock icon", "menu bar app"]
        case .deeplinks:
            return ["deeplink", "deeplinks", "deep link", "url scheme", "sorty://", "shortcuts", "raycast", "automation links", "scripts", "downloads", "desktop", "documents", "open url"]
        case .finder:
            return ["finder", "quick action", "organize action", "watch action", "exclude action", "extension", "service", "automation permission", "repair"]
        case .notifications:
            return ["notification", "notifications", "alerts", "sound", "banner", "hud", "in app hud", "notificli", "completion", "foreground", "permissions", "notification center"]
        case .permissions:
            return ["permission", "permissions", "privacy", "security", "files and folders", "full disk access", "finder automation", "notifications", "system settings", "folder access"]
        case .advanced:
            return ["advanced", "menu bar", "streaming", "performance", "developer", "diagnostics", "debug", "logs", "error logs", "red logs"]
        case .troubleshooting:
            return ["troubleshoot", "errors", "reset", "logs", "repair", "recovery", "diagnose"]
        case .help:
            return ["help", "support", "documentation", "faq", "guide", "tips", "contact", "issue details", "bug report", "diagnostics"]
        case .experimental:
            return ["experimental", "labs", "beta", "feature flags"]
        }
    }

    public var featureSnippets: [SettingsFeatureSnippet] {
        func feature(
            _ title: String,
            _ summary: String,
            keywords: [String] = [],
            target: SettingsFocusTarget
        ) -> SettingsFeatureSnippet {
            SettingsFeatureSnippet(
                title: title,
                summary: summary,
                keywords: keywords,
                focusTarget: target
            )
        }

        switch self {
        case .provider:
            return [
                feature("Select Provider", "Choose OpenAI, Anthropic, Gemini, Copilot, Ollama, or OpenAI-compatible APIs.", target: .providerSelect),
                feature("API Configuration", "Set endpoint URL and API key/token details for your selected provider.", keywords: ["api key", "endpoint", "token", "authentication"], target: .providerConfiguration),
                feature("Model Catalog", "Search and pick models available for each provider.", keywords: ["model picker", "model selection"], target: .providerConfiguration),
                feature("Reasoning Effort", "Choose how much reasoning supported models use.", keywords: ["reasoning", "thinking", "effort", "speed"], target: .providerConfiguration),
                feature("Connection Testing", "Validate credentials and endpoint connectivity before organizing files.", keywords: ["test connection", "connection status"], target: .providerConnection),
                feature("OpenAI", "Use OpenAI with an API key or ChatGPT subscription.", keywords: ["gpt", "chatgpt", "codex"], target: .providerOpenAI),
                feature("GitHub Copilot", "Use models through a GitHub Copilot subscription.", keywords: ["copilot", "subscription"], target: .providerGitHubCopilot),
                feature("Groq", "Use Groq for fast hosted inference.", keywords: ["fast inference"], target: .providerGroq),
                feature("OpenAI-Compatible API", "Connect Sorty to a custom OpenAI-compatible endpoint.", keywords: ["compatible api", "custom endpoint"], target: .providerCompatibleAPI),
                feature("OpenRouter", "Use OpenRouter’s multi-provider model catalog.", keywords: ["model router"], target: .providerOpenRouter),
                feature("Ollama", "Use local models running through Ollama.", keywords: ["local models", "localhost"], target: .providerOllama),
                feature("Anthropic Claude", "Use Anthropic Claude models.", keywords: ["claude"], target: .providerAnthropic),
                feature("Google Gemini", "Use Google Gemini models.", keywords: ["gemini"], target: .providerGemini),
                feature("Apple Foundation Model", "Use Apple’s private on-device foundation model.", keywords: ["apple intelligence", "on device"], target: .providerApple),
                feature("Organization Model", "Choose the model used to organize files.", keywords: ["model picker", "model selection"], target: .providerConfiguration),
                feature("Test Connection", "Test the selected provider’s credentials and endpoint.", keywords: ["connection test", "validate provider"], target: .providerTestConnection)
            ]
        case .strategy:
            return [
                feature("Fast Mode", "Uses names, basic metadata, and folder context; skips deep content analysis.", keywords: ["deep scanning", "scan content"], target: .strategyFastMode),
                feature("AI Vision for Images", "Use image understanding to classify screenshots and photos.", keywords: ["vision", "image analysis"], target: .strategyVision),
                feature("Renaming", "Control how Sorty names organized files.", keywords: ["rename", "filename"], target: .strategyRenaming),
                feature("Naming Template", "Choose a built-in or custom naming preset.", keywords: ["naming preset", "template"], target: .strategyNamingTemplate),
                feature("Filename Format", "Set separators, letter case, dates, and maximum filename length.", keywords: ["separator", "case", "date policy", "max length"], target: .strategyNamingOptions),
                feature("Filename Separator", "Choose spaces, underscores, hyphens, or another filename separator.", keywords: ["separator", "spaces", "underscores", "hyphens"], target: .strategyNamingSeparator),
                feature("Filename Letter Case", "Choose the capitalization style used for renamed files.", keywords: ["case", "capitalization", "camel case", "title case"], target: .strategyNamingCase),
                feature("Filename Dates", "Choose whether renamed files include dates.", keywords: ["date policy", "dates"], target: .strategyNamingDatePolicy),
                feature("Maximum Filename Length", "Set the maximum character length for renamed files.", keywords: ["max length", "filename length", "slider"], target: .strategyMaxFilenameLength),
                feature("Naming Instructions", "Add custom rules or generate a reusable naming template.", keywords: ["custom naming instructions", "additional naming instructions", "generate naming template"], target: .strategyNamingInstructions)
            ]
        case .rules:
            return [
                feature("Content Rules", "Control AI suggestions that affect organized files.", keywords: ["rules", "organization controls"], target: .rulesContentRules),
                feature("Enable File Tagging", "Allow AI to suggest and apply Finder tags to files.", keywords: ["tagging", "finder tags", "smart tags"], target: .rulesFileTagging),
                feature("Organization Style", "Pick personas and style preferences for folder structures.", keywords: ["persona", "folder style"], target: .rulesOrganizationStyle)
            ]
        case .automation:
            return [
                feature("Global Automation Model", "Use one dedicated model for watched-folder automation, overriding folder-specific model picks while enabled.", keywords: ["custom model", "watched folder model override"], target: .automationGlobalModel),
                feature("Use Separate Automation Model", "Turn the dedicated watched-folder automation model on or off.", keywords: ["separate model", "automation override"], target: .automationSeparateModel),
                feature("Launch at Login", "Automatically start Sorty when you log in to macOS.", keywords: ["launch-at-login", "login item", "start on login"], target: .automationLaunchAtLogin),
                feature("Keep in Background", "Continue monitoring folders even when all windows are closed.", keywords: ["background activity", "background app", "folder watching"], target: .automationKeepInBackground),
                feature("Hide Dock Icon", "Run Sorty as a menu bar app without showing in the Dock.", keywords: ["dock visibility", "menu bar app"], target: .automationHideDockIcon)
            ]
        case .deeplinks:
            // One snippet per library entry so search navigates to and
            // highlights the exact deeplink row instead of its whole group.
            // Every entry carries the "deeplink" keyword so multi-term
            // queries like "persona deeplink" still resolve.
            return [
                feature("Open App", "Copy the sorty://open link to bring Sorty to front and preload a directory.", keywords: ["deeplink", "sorty://open"], target: .deeplinksOpenApp),
                feature("Settings", "Copy the sorty://settings link to open Settings at a specific section.", keywords: ["deeplink", "sorty://settings"], target: .deeplinksSettings),
                feature("Help", "Copy the sorty://help link to open help and support content.", keywords: ["deeplink", "sorty://help"], target: .deeplinksHelp),
                feature("History", "Copy the sorty://history link to open organization history.", keywords: ["deeplink", "sorty://history"], target: .deeplinksHistory),
                feature("Organize Folder", "Copy the sorty://organize link to organize a folder with persona, mode, and autostart options.", keywords: ["deeplink", "sorty://organize", "downloads", "desktop", "documents"], target: .deeplinksOrganizeFolder),
                feature("Duplicates", "Copy the sorty://duplicates link to open duplicate review for a folder.", keywords: ["deeplink", "sorty://duplicates"], target: .deeplinksDuplicates),
                feature("Storage", "Copy the sorty://storage link to open storage locations and add a path.", keywords: ["deeplink", "sorty://storage"], target: .deeplinksStorage),
                feature("Watched Folders", "Copy the sorty://watched link to open watched folders and add a path.", keywords: ["deeplink", "sorty://watched"], target: .deeplinksWatchedFolders),
                feature("Rules", "Copy the sorty://rules link to open rules and add a rule.", keywords: ["deeplink", "sorty://rules"], target: .deeplinksRules),
                feature("Exclusions", "Copy the sorty://exclusions link to open exclusions and add a pattern.", keywords: ["deeplink", "sorty://exclusions"], target: .deeplinksExclusions),
                feature("Persona", "Copy the sorty://persona link for persona create and select flows.", keywords: ["deeplink", "sorty://persona"], target: .deeplinksPersona),
                feature("Learnings", "Copy the sorty://learnings link for learnings stats, export, import, or clear actions.", keywords: ["deeplink", "sorty://learnings"], target: .deeplinksLearnings),
                feature("Provider Settings", "Copy the provider setup link that jumps straight to provider settings.", keywords: ["deeplink", "sorty://settings?section=provider", "provider setup"], target: .deeplinksProviderSettings),
                feature("Organize with Sorty", "Copy the Finder service link that organizes the selected folder.", keywords: ["deeplink", "sorty://organize", "finder service", "finder actions"], target: .deeplinksFinderOrganize),
                feature("Watch with Sorty", "Copy the Finder service link that watches the selected folder.", keywords: ["deeplink", "sorty://watched", "finder service", "finder actions"], target: .deeplinksFinderWatch),
                feature("Exclude from Sorty", "Copy the Finder service link that excludes the selected file or folder.", keywords: ["deeplink", "sorty://exclude", "finder service", "finder actions"], target: .deeplinksFinderExclude),
                feature("Finder Settings", "Copy the Finder integration link that jumps straight to Finder settings.", keywords: ["deeplink", "sorty://settings?section=finder", "finder integration", "finder settings"], target: .deeplinksFinderSettings)
            ]
        case .finder:
            return [
                feature("Organize with Sorty", "Run Sorty directly from Finder context menus.", keywords: ["quick action", "service"], target: .finderOrganize),
                feature("Check Finder Status", "Refresh Finder Integration status and permission checks.", keywords: ["check now", "refresh finder"], target: .finderCheckStatus),
                feature("Watch with Sorty", "Add watched folders directly from Finder context menus.", keywords: ["quick action", "service", "watched folders"], target: .finderWatch),
                feature("Exclude from Sorty", "Add files and folders to exclusions directly from Finder context menus.", keywords: ["quick action", "service", "exclude path", "exclusion rules"], target: .finderExclude),
                feature("Finder Extension", "Activate or repair the Finder Sync extension and jump to macOS Extensions settings.", keywords: ["finder sync", "extensions"], target: .finderExtension),
                feature("Automation Permission", "Grant and recover Finder automation permission required for workflow controls.", keywords: ["apple events", "recover permission"], target: .finderAutomationPermission)
            ]
        case .notifications:
            return [
                feature("Notification Permission", "Check macOS notification authorization status.", keywords: ["system notification permission", "settings gear"], target: .notificationsPermission),
                feature("In-App HUD", "Show notifications as subtle bottom-left overlays.", keywords: ["delivery method", "hud", "overlay"], target: .notificationsInAppHUD),
                feature("System Notifications", "Show notifications in macOS Notification Center.", keywords: ["delivery method", "notification center", "system notification"], target: .notificationsSystem),
                feature("Notification Types", "Control which organization events send notifications.", target: .notificationsTypes),
                feature("Processing Complete", "Notify when file processing finishes successfully.", keywords: ["finished", "success"], target: .notificationsProcessingComplete),
                feature("Preview Ready", "Notify when Sorty finishes generating an organization plan.", keywords: ["plan ready"], target: .notificationsPreviewReady),
                feature("Processing Errors", "Notify when organization encounters an error.", keywords: ["failure", "failed"], target: .notificationsProcessingErrors),
                feature("Watched Folder Activity", "Notify when Sorty starts or finishes organizing detected additions.", keywords: ["watcher", "automatic", "detected", "complete"], target: .notificationsWatchedFolderFinished),
                feature("Completion Sound", "Play a sound when organization finishes.", keywords: ["sounds", "audio"], target: .notificationsCompletionSound)
            ]
        case .permissions:
            return [
                feature("Files & Folders", "Choose the folders Sorty can scan and organize.", keywords: ["folder picker", "grant access"], target: .permissionsFilesAndFolders),
                feature("Full Disk Access", "Allow access to protected folders you explicitly choose.", keywords: ["privacy and security", "protected folders"], target: .permissionsFullDiskAccess),
                feature("Finder Automation", "Allow Sorty to read Finder selections for Finder Integration.", keywords: ["automation permission", "apple events"], target: .permissionsAutomation),
                feature("Notifications", "Allow Sorty to deliver alerts through macOS Notification Center.", keywords: ["notification permission", "alerts"], target: .permissionsNotifications),
                feature("Refresh Permission Status", "Recheck every permission shown by Sorty.", keywords: ["refresh status", "check permissions"], target: .permissionsStatusActions),
                feature("Open Privacy & Security", "Open the macOS Privacy & Security settings page.", keywords: ["system settings", "privacy settings"], target: .permissionsStatusActions),
                feature("How Sorty Uses Access", "Review how folder, disk, and system permissions are used and revoked.", keywords: ["privacy", "revoke", "source code", "terms"], target: .permissionsUsage)
            ]
        case .advanced:
            return [
                feature("Show Menu Bar Icon", "Display the Sorty icon in the menu bar for quick access.", keywords: ["menu bar", "menubar"], target: .advancedMenuBar),
                feature("Finder Workflow", "Open Finder and highlight newly organized folders after each completed run.", keywords: ["automatically reveal organized folders", "view in finder", "auto reveal"], target: .advancedFinderWorkflow),
                feature("Privacy Mode", "Mask sensitive paths, usernames, API keys, and raw AI details.", keywords: ["privacy", "redact", "mask", "hide"], target: .advancedPrivacyMode),
                feature("Block Internet Connections", "Allow only localhost requests for local models and offline workflows.", keywords: ["internet privacy", "network privacy", "offline", "localhost"], target: .advancedInternetPrivacy),
                feature("Share Anonymous Analytics", "Choose whether Sorty shares anonymous feature usage and sanitized reliability data.", keywords: ["analytics", "telemetry", "posthog", "crash reporting"], target: .advancedAnalytics),
                feature("Timeouts", "Tune request timeout and maximum total request duration.", target: .advancedTimeouts),
                feature("Request Timeout", "Set how long Sorty waits for the initial AI response.", keywords: ["initial response", "seconds"], target: .advancedRequestTimeout),
                feature("Resource Timeout", "Set the maximum total duration of an AI request.", keywords: ["total request duration", "seconds"], target: .advancedResourceTimeout),
                feature("Stats for Nerds", "Show detailed generation metrics.", keywords: ["developer", "metrics", "tokens", "throughput", "cost"], target: .advancedStats),
                feature("Generate Diagnostic Report", "Save a privacy-safe ZIP with app, system, log, PostHog, and Sentry diagnostics.", keywords: ["developer tools", "report", "zip", "error logs", "logs", "analytics"], target: .advancedErrorLogs)
            ]
        case .troubleshooting:
            return [
                feature("Support Assistant", "Run local health checks and open the exact setting needed to recover.", keywords: ["health check", "diagnose", "repair", "support"], target: .troubleshootingAssistant),
                feature("Cache", "Clear cached data and recover from stale state.", keywords: ["clear cache"], target: .troubleshootingCache),
                feature("Learnings Data", "Inspect or reset learning signals and history.", keywords: ["delete learnings"], target: .troubleshootingLearnings),
                feature("Reset Sorty", "Perform a full reset of app configuration.", keywords: ["erase all data", "factory reset"], target: .troubleshootingReset)
            ]
        case .help:
            return [
                feature("Support Links", "Open documentation, changelog, issue reporting, privacy, and terms.", target: .helpSupport),
                feature("Documentation", "Open Sorty’s help and usage documentation.", keywords: ["help guide", "readme"], target: .helpDocumentation),
                feature("Report Issue", "Open GitHub Issues to report a bug or request a feature.", keywords: ["bug report", "github issue"], target: .helpReportIssue),
                feature("View Changelog", "Review recent Sorty releases and product changes.", keywords: ["release notes", "what's new"], target: .helpChangelog),
                feature("Privacy Policy", "Read Sorty’s privacy policy.", keywords: ["legal", "data"], target: .helpPrivacy),
                feature("Terms of Service", "Read Sorty’s terms of service.", keywords: ["legal", "terms"], target: .helpTerms),
                feature("Copy Support Report", "Copy privacy-safe app, system, and configuration details.", keywords: ["support data", "diagnostics", "bug report"], target: .helpIssueDetails)
            ]
        case .experimental:
            return [
                feature("Experimental Features", "Install the experimental Sorty skill for Codex and see other available labs.", keywords: ["experimental", "labs", "beta", "feature flags", "codex", "skill", "install"], target: .experimentalEmptyState)
            ]
        }
    }

    public var searchableFeatureText: [String] {
        featureSnippets.flatMap { [$0.title, $0.summary] + $0.keywords }
    }

    public func featureMatches(query: String) -> [SettingsFeatureMatch] {
        let normalizedQuery = query.normalizedSearchText
        guard !normalizedQuery.isEmpty else { return [] }

        return featureSnippets
            .compactMap { snippet in
                let score = snippet.searchScore(matching: normalizedQuery)
                guard score > 0 else { return nil }
                return SettingsFeatureMatch(category: self, snippet: snippet, score: score)
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.snippet.title < $1.snippet.title
            }
    }

    public func matchesSearch(query: String) -> Bool {
        let normalizedQuery = query.normalizedSearchText
        guard !normalizedQuery.isEmpty else { return true }

        let haystack = ([rawValue] + searchKeywords + searchableFeatureText)
            .map(\.normalizedSearchText)
            .joined(separator: " ")

        if haystack.contains(normalizedQuery) {
            return true
        }

        let terms = normalizedQuery.searchTerms
        return !terms.isEmpty && terms.allSatisfy { haystack.contains($0) }
    }

    public func focusTarget(for snippet: SettingsFeatureSnippet) -> SettingsFocusTarget? {
        snippet.focusTarget ?? (snippet.title == rawValue ? fallbackFocusTarget : nil)
    }

    private var fallbackFocusTarget: SettingsFocusTarget? {
        switch self {
        case .provider:
            return .providerSelect
        case .strategy:
            return .strategyFastMode
        case .rules:
            return .rulesContentRules
        case .automation:
            return .automationGlobalModel
        case .deeplinks:
            return .deeplinksOpenApp
        case .finder:
            return .finderIntegration
        case .notifications:
            return .notificationsPermission
        case .permissions:
            return .permissionsFilesAndFolders
        case .advanced:
            return .advancedMenuBar
        case .troubleshooting:
            return .troubleshootingMaintenance
        case .help:
            return .helpSupport
        case .experimental:
            return .experimentalEmptyState
        }
    }
}

private extension SettingsFeatureSnippet {
    func searchScore(matching normalizedQuery: String) -> Int {
        let normalizedTitle = title.normalizedSearchText
        let normalizedSummary = summary.normalizedSearchText
        let normalizedKeywords = keywords.map(\.normalizedSearchText)
        let queryTerms = normalizedQuery.searchTerms

        let searchableText = ([normalizedTitle, normalizedSummary] + normalizedKeywords)
            .joined(separator: " ")

        guard !searchableText.isEmpty else { return 0 }

        var score = 0

        if normalizedTitle == normalizedQuery {
            score += 48
        } else if normalizedTitle.hasPrefix(normalizedQuery) {
            score += 32
        } else if normalizedTitle.contains(normalizedQuery) {
            score += 24
        }
        if normalizedSummary.contains(normalizedQuery) {
            score += 14
        }
        if normalizedKeywords.contains(normalizedQuery) {
            score += 18
        } else if normalizedKeywords.contains(where: { $0.contains(normalizedQuery) }) {
            score += 10
        }

        var matchedTermCount = 0
        for term in queryTerms where !term.isEmpty {
            if normalizedTitle.contains(term) {
                score += 6
                matchedTermCount += 1
            } else if normalizedSummary.contains(term) {
                score += 4
                matchedTermCount += 1
            } else if normalizedKeywords.contains(where: { $0.contains(term) }) {
                score += 3
                matchedTermCount += 1
            }
        }

        guard matchedTermCount == queryTerms.count else { return 0 }

        if queryTerms.count > 1 {
            score += 8
        }

        return score
    }
}

private extension String {
    var normalizedSearchText: String {
        self.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchTerms: [String] {
        normalizedSearchText
            .split(separator: " ")
            .map(String.init)
    }
}
