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

### Sorty Labs

Local opt-in experiments, defined in `Sources/SortyModels/SortyLabs.swift` and toggled in Settings → Experimental → Sorty Labs. All default to off and work without analytics consent.

| Feature | Key | What it does |
|---------|-----|--------------|
| Routing Rules | `labs.routingRules` | A card on the Rules page turns a sentence into a saved rule (exclusion-style conditions plus a relative destination with `{YYYY}`, `{MM}`, `{DD}`, `{Month}`). The AI runs once, when the rule is written. During manual organize runs, matching files skip the AI and merge into the plan (`FolderOrganizer+Routing.swift`). Rename-only runs and watched folders ignore routing rules. |
| Downloads Inbox | `labs.downloadsInbox` | `DownloadsInboxManager` watches `~/Downloads` with one vnode source and queues files added after the feature was turned on. The menu bar lists them with a suggested folder: a routing rule match, then a folder the user picked before for that extension, then a folder named for the kind of file inside Downloads. Return files the top item and ⌘Z undoes the last move. Moves never overwrite. |
| Expiring Files | `labs.expiringFiles` | `ExpiringFilesManager` lists installers, archives and screenshots at the top level of Downloads, the Desktop and the screenshot folder once they are older than `labs.expiring.days` (default 14), plus files the user marked "Trash in 7 Days" in the inbox. The menu bar asks for review and moves approved files to the Trash. "Keep" stops a file from being offered again. |
| Project Detection | `labs.projectDetection` | The organize scan skips folders that hold project markers (`.git`, `Package.swift`, `package.json`, `.xcodeproj` and similar; see `ProjectFolderDetector`), so their files are never moved. `ProjectClusterDetector` groups loose files that share a distinctive name word across two or more file kinds and asks the AI to keep each group in one folder. |

### Sorty Codex Skill

The Sorty skill installer is a regular setting in Settings → Features → Sorty Skill. It is always available and does not require a feature flag or PostHog assignment. Setup installs the bundled skill and lets users choose which Sorty preferences to share. Existing installations can import updated settings, and removal or replacement requires confirmation.

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
