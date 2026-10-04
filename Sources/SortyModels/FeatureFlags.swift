//
//  FeatureFlags.swift
//  Sorty
//
//  Created on Sun Jan 25 2026
//

import Foundation

@MainActor
public enum FeatureFlags {
    /// Retired rollout key, retained to hide stale PostHog assignments from Experimental.
    public static let codexSkillInstallerKey = "labs-sorty-codex-skill"

    /// Legacy preference for Finder Integration.
    ///
    /// Finder Integration is a core app feature. The key remains for migration and
    /// older installs that may have written it, but new installs default to enabled.
    public static var finderSyncEnabled: Bool {
        enabledByDefault("finderIntegrationEnabled")
    }

    /// Controls privacy features like blurring sensitive handles and hiding API keys by default.
    ///
    /// Enabled by default. Disable via Terminal:
    /// ```
    /// defaults write com.sorty.app privacyModeEnabled -bool false
    /// ```
    /// Enable:
    /// ```
    /// defaults write com.sorty.app privacyModeEnabled -bool true
    /// ```
    public static var privacyModeEnabled: Bool {
        enabledByDefault("privacyModeEnabled")
    }

    /// Controls internet network blocking privacy mode.
    ///
    /// Disabled by default. Enable via Terminal:
    /// ```
    /// defaults write com.sorty.app internetPrivacyModeEnabled -bool true
    /// ```
    /// Disable:
    /// ```
    /// defaults write com.sorty.app internetPrivacyModeEnabled -bool false
    /// ```
    public static var internetPrivacyModeEnabled: Bool {
        // Canonical key lives on NetworkPrivacyPolicy up in SortyCore; the
        // literal is repeated here so this leaf target stays dependency-free.
        UserDefaults.standard.bool(forKey: "internetPrivacyModeEnabled")
    }

    /// Controls whether Sorty requires authentication for sensitive actions such as
    /// deleting usage data, changing network privacy mode, and revealing secrets.
    ///
    /// Disabled by default. Enable via Terminal:
    /// ```
    /// defaults write com.sorty.app sensitiveActionAuthenticationEnabled -bool true
    /// ```
    /// Disable:
    /// ```
    /// defaults write com.sorty.app sensitiveActionAuthenticationEnabled -bool false
    /// ```
    public static var sensitiveActionAuthenticationEnabled: Bool {
        UserDefaults.standard.bool(forKey: "sensitiveActionAuthenticationEnabled")
    }

    /// Controls whether subscription-based auth methods are available for supported AI providers.
    ///
    /// Enabled by default. Disable via Terminal:
    /// ```
    /// defaults write com.sorty.app subscriptionAuthEnabled -bool false
    /// ```
    /// Re-enable:
    /// ```
    /// defaults write com.sorty.app subscriptionAuthEnabled -bool true
    /// ```
    public static var subscriptionAuthEnabled: Bool {
        enabledByDefault("subscriptionAuthEnabled")
    }

    /// Controls whether in-app links and buttons supporting the developer are shown.
    ///
    /// Shown by default. Hide them via Terminal:
    /// ```
    /// defaults -container com.sorty.app write com.sorty.app supportDeveloperEnabled -bool false
    /// ```
    /// Show them again:
    /// ```
    /// defaults -container com.sorty.app write com.sorty.app supportDeveloperEnabled -bool true
    /// ```
    public static var supportDeveloperEnabled: Bool {
        enabledByDefault("supportDeveloperEnabled")
    }

    /// Preview harness mode for rapid development iteration.
    /// When enabled, the app boots with minimal dependencies and mock services.
    ///
    /// Enable via environment variable (set by `make harness`):
    /// ```
    /// SORTY_HARNESS_MODE=1 open Sorty.app
    /// ```
    public static var harnessMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SORTY_HARNESS_MODE"] == "1"
        #else
        false
        #endif
    }

    private static func enabledByDefault(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            || UserDefaults.standard.bool(forKey: key)
    }
}
