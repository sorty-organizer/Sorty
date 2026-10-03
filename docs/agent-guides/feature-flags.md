# Feature Flags

Feature flags are controlled via `defaults` and defined in `Sources/SortyModels/FeatureFlags.swift`.

## Usage
```bash
# Enable a flag
defaults write com.sorty.app <key> -bool true

# Disable a flag
defaults write com.sorty.app <key> -bool false
```

## Available Flags

Flags are defined in `Sources/SortyModels/FeatureFlags.swift`. Terminal keys use the `com.sorty.app` defaults domain unless noted.

| Flag | Key | Default | Description |
|------|-----|---------|-------------|
| Finder Integration | `finderIntegrationEnabled` | `true` | Legacy preference for Finder Integration. Finder Integration is a core app feature; the key remains for migration and older installs, and new installs default to enabled. |
| Privacy Mode | `privacyModeEnabled` | `true` | Blurs sensitive handles until hover; hides API keys with manual reveal |
| Internet Privacy Mode | `internetPrivacyModeEnabled` | `false` | Allows only localhost network requests; blurs and disables cloud provider cards, with a hover explanation. Apple, Ollama, and Compatible API stay selectable for local workflows. Custom endpoints must use localhost. Available provider cards respond to clicks across the full rectangle. |
| Sensitive Action Authentication | `sensitiveActionAuthenticationEnabled` | `false` | Requires authentication for sensitive actions such as deleting usage data, changing network privacy mode, and revealing secrets |
| Subscription Auth | `subscriptionAuthEnabled` | `true` | Makes subscription-based auth methods available for supported AI providers |
| Support the Developer | `supportDeveloperEnabled` | `true` | In-app links and buttons for supporting the developer; uses the sandbox-container commands below |
| Sorty Codex Skill | `labs-sorty-codex-skill` | PostHog assignment | Experimental one-click installer in Settings → Experimental; currently registered at 100% rollout |

### Sorty Codex Skill

PostHog owns the normal rollout. The local override uses the exact same key and is useful for offline development:

```bash
# Show the installer without a PostHog assignment
defaults write com.sorty.app labs-sorty-codex-skill -bool true

# Remove the local override and return to PostHog assignment
defaults delete com.sorty.app labs-sorty-codex-skill
```

The installer copies Sorty's bundled skill into the user's Codex skills directory. Users can remove a matching installation or explicitly replace a conflicting `sorty` skill after confirmation. Anonymous, opted-in analytics record bounded install, replacement, removal, and availability outcomes so adoption can be evaluated while the feature remains experimental.

### Harness Mode

Harness mode is controlled by environment variables, not `defaults`:

| Flag | Variable | Default | Description |
|------|----------|---------|-------------|
| Harness Mode | `SORTY_HARNESS_MODE` | unset | Boots the app with minimal dependencies and mock services |

Set via `make harness`; see `docs/agent-guides/fast-loop.md`.

### Support the Developer
Quit Sorty before changing the value, then reopen it. The `-container` option writes to the same sandboxed preferences domain that Sorty reads; omitting it writes a separate host preference that the app does not reliably see.

```bash
# Hide all Support the Developer links and buttons
defaults -container com.sorty.app write com.sorty.app supportDeveloperEnabled -bool false

# Show them again
defaults -container com.sorty.app write com.sorty.app supportDeveloperEnabled -bool true

# Restore the default, which is shown
defaults -container com.sorty.app delete com.sorty.app supportDeveloperEnabled

# Confirm the stored value
defaults -container com.sorty.app read com.sorty.app supportDeveloperEnabled
```

## Finder integration setup

Open Settings -> Finder Integration. Sorty prepares its Finder actions and checks
extension registration automatically. Use **Open macOS Extensions** when shown to
enable the extension. An extension disabled in macOS stays disabled until you
change it there. Normal setup does not need Terminal commands.

The OpenAI authentication selector uses the same native capsule and tabs treatment as History filters, with API Key and Codex CLI options.
