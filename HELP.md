# Sorty Help

## Table of Contents
1. [Getting Started](#getting-started)
2. [Features Overview](#features-overview)
3. [Organizing Files](#organizing-files)
4. [The Learnings](#the-learnings)
5. [Personas](#personas)
6. [Managing Duplicates](#managing-duplicates)
7. [Watched Folders](#watched-folders)
8. [Exclusion Rules](#exclusion-rules)
10. [App Deeplinks](#app-deeplinks)
11. [Keyboard Shortcuts](#keyboard-shortcuts)
12. [Menu Bar Commands](#menu-bar-commands)
13. [Version & Updates](#version--updates)
14. [Troubleshooting](#troubleshooting)
    - [Update Check Issues](#update-check-issues)
15. [Privacy & Data](#privacy--data)
16. [FAQ](#faq)

---

## Getting Started

Welcome to Sorty! This app uses AI to intelligently sort your files into logical folders.

### Quick Start Guide

1. **Select a Folder**: Click "Open Directory" (⌘O) or drag a folder onto the app to choose the folder you want to organize.

2. **Choose a Persona**: Select a persona (e.g., "Developer", "Photographer") in Settings to tailor the organization logic to your workflow.

3. **Preview the Organization**: Click "Organize" to see a preview of the proposed changes. The AI will analyze your files and suggest a folder structure.

4. **Review and Customize**: Expand each suggested folder to see which files will be moved. You can remove files from suggestions if needed. Rename suggestions show a confidence label and the source evidence. High-confidence names are selected. Medium- and low-confidence names keep the original filename until you check "Use".

5. **Apply Changes**: If you're happy with the preview, click "Apply Changes". You can always undo with ⌘Z.

### First-Time Setup

Before your first organization, we recommend:

- **Configure your API Key** in Settings if using OpenAI (not needed for Apple Intelligence or local Ollama)
- **Set up Exclusion Rules** to protect important files you never want moved
- **Enable Deep Scan** for smarter organization (uses more resources)
- **Enable File Tagging** to get Finder-compatible tags on your files

---

## Features Overview

### Smart Organization
AI-powered sorting based on filenames, file types, and optionally content metadata. The AI recognizes patterns like project structures, date sequences, and semantic groupings.

### Deep Scan
When enabled, Sorty reads file content for better accuracy:
- PDF text extraction
- Image EXIF metadata (camera, date, location)
- Document titles and keywords
- Audio/video metadata

### File Tagging
Files can be tagged with Finder-compatible tags like "Invoice", "Personal", "Important", or "Archive". These tags are searchable in Spotlight and Finder.

### Watched Folders
Set up automatic organization for folders like Downloads. New files are organized as they arrive.

### Duplicate Detection
Find and safely remove duplicate files using SHA-256 content hashing. Recover space while maintaining a safety net.

---

## Organizing Files

### How Organization Works

1. **Scanning**: Sorty scans your selected directory and collects information about each file.

2. **AI Analysis**: The AI analyzes patterns in your files:
   - Naming conventions (project_v1, project_v2, etc.)
   - File types and categories
   - Date patterns (YYYY-MM-DD prefixes)
   - Project structures

3. **Structure Proposal**: Based on analysis, the AI proposes a folder structure with categories and subcategories.

4. **Tagging**: Files receive relevant Finder tags for easy searching.

### Custom Instructions

Before organizing, you can provide specific guidance:
- "Group all 2024 files together"
- "Organize by client name"
- "Keep design files separate from code"
- "Create a folder for each project"

Enter custom instructions in the text field before clicking "Organize".

### Temperature Control

Adjust the AI's creativity in Settings:
- **Low (0.0-0.3)**: More predictable, strict categorization
- **Medium (0.4-0.6)**: Balanced approach
- **High (0.7-1.0)**: More creative groupings, may find novel patterns

### Including Reasoning

Enable "Include Reasoning" in Settings to see detailed explanations for each folder:
- Why files are grouped together
- What patterns the AI noticed
- Why alternatives were rejected

This is helpful for understanding and fine-tuning the organization.

---

## The Learnings

The Learnings is a **passive learning system** that builds a personalized understanding of how you prefer to organize files. It observes your organization habits, corrections, and feedback to continuously improve AI suggestions over time.

### Getting Started

1. **Enable Learning**: Navigate to **The Learnings** (⇧⌘L) and grant consent
2. **Authenticate**: Set up Touch ID / Face ID / Passcode protection for your data
3. **Use the App Normally**: Organize files, provide feedback, and make corrections

After initial setup, you'll need to authenticate each time you access The Learnings dashboard (for security).

### What Gets Learned

| Behavior | What's Captured | Priority |
|----------|-----------------|----------|
| **Steering Prompts** | Post-organization feedback and instructions | Highest |
| **Guiding Instructions** | Instructions you provide before organizing | High |
| **Manual Corrections** | Files you move after AI organization | Medium |
| **Reverts** | Organization sessions you undo | Medium |
| **Additional Instructions** | Custom instructions during organization | Medium |

### How Learning Improves AI

The system uses your learnings in several ways:

1. **Pattern Recognition**: Identifies how you prefer to organize specific file types
2. **Temporal Weighting**: Recent behavior is weighted more heavily than older patterns
3. **Rule Induction**: AI analyzes patterns to create explicit organization rules
4. **Contextual Understanding**: Learns folder preferences for different contexts

### The Dashboard

The Learnings dashboard has three tabs:

- **Overview**: Quick stats, learning progress, and action buttons
- **Preferences**: Grouped view of inferred rules and feedback
- **Activity**: Timeline of corrections, reverts, and instructions with expandable details

Learnings are inferred passively from normal use, corrections, reversions, and feedback. For explicit persistent instructions, create or edit a Persona.

### Security & Privacy

| Feature | Description |
|---------|-------------|
| **Biometric Protection** | Touch ID / Face ID required after initial setup |
| **AES-256 Encryption** | All learning data encrypted with Keychain-stored keys |
| **Local Storage Only** | Data never leaves your device |
| **Session Timeout** | Automatic lock after 5 minutes of inactivity |
| **Secure Deletion** | Data overwritten before removal |

### Data Management

- **Pause Learning / Resume Learning**: Stop or restart data collection while preserving existing data
- **Delete All Data**: Permanently and securely remove all learning data
- **Export**: (Coming soon) Export your preferences as JSON

### CLI Commands

```bash
# View learning status
learnings-cli --status

# Clear all learning data
learnings-cli --clear

# Open Learnings dashboard
sorty learnings
```

### Deeplinks

| Deeplink | Description |
|----------|-------------|
| `sorty://learnings` | Open Learnings dashboard |
| `sorty://learnings?action=stats` | View learning statistics |

---

## Personas

Personas customize how the AI organizes your files based on your profession or use case.

### Available Personas

| Persona | Best For | Key Features |
|---------|----------|--------------|
| **General** | Most users | Standard categories (Documents, Media, Archives) |
| **Developer** | Programmers | Groups by project, language, and tech stack |
| **Photographer** | Photo professionals | Organizes by shoots, dates, camera metadata |
| **Music Producer** | Audio creators | Groups projects, samples, stems, sessions |
| **Student** | Academic work | Organizes by subject, course, semester |
| **Business** | Professional work | Groups by client, project, fiscal period |

### Customizing Personas

You can customize the system prompt for each persona:

1. Go to Settings → Advanced Settings
2. Select the persona to customize
3. Edit the "Custom System Prompt" text
4. Your changes persist per-persona

**Tip**: Reset to default by clicking "Reset to Default" next to the prompt editor.

---

## Managing Duplicates

### How Duplicate Detection Works

Sorty uses SHA-256 content hashing to find files with **identical content**, regardless of filename. Files are grouped by hash, and you can choose which copy to keep.

### Safe Deletion (Recommended)

When enabled, "deleted" duplicates aren't immediately removed:
- Files are tracked and can be restored later
- Go to History → find the cleanup session → click "Restore"
- Disk space is only recovered after you confirm the deletion

### Bulk Operations

- **Delete All (Keep Newest)**: Removes all duplicates, keeping the most recently modified version
- **Delete All (Keep Oldest)**: Removes all duplicates, keeping the original version

### Independent Scanning

You can scan any folder for duplicates without changing your main organization target. Use the "Settings" button in the Duplicates view to configure scanning depth and file filters.

---

## App Deeplinks

The app provides comprehensive URL schemes to control all aspects of the application.

### Organization Routes

| Route | Parameters | Description |
|-------|------------|-------------|
| `sorty://organize` | Open the organization view |
| `path` | Path to organize |
| `persona` | ID of persona (sorty_general, developer, etc.). |
| `autostart=true` | Automatically begin organization |

### Duplicates

| Route | Parameters | Description |
|-------|------------|-------------|
| `sorty://duplicates` | Open duplicates view |
| `path` | Path to scan |
| `autostart=true` | Automatically begin scan |

### Persona Management

| Route | Parameters | Description |
|-------|------------|-------------|
| `sorty://persona` | | Open persona management |
| | `action=generate` | Generate a new persona |
| | `prompt=<description>` | Description for persona generation |
| | `generate=true` | Trigger generation immediately |

**Examples:**
- `sorty://persona` - Open persona view
- `sorty://persona?action=generate&prompt=sci-fi%20ebook%20collector` - Generate persona from description

### Watched Folders

| Route | Parameters | Description |
|-------|------------|-------------|
| `sorty://watched` | | Open watched folders view |
| | `action=add` | Add a new watched folder |
| | `path=<folder_path>` | Path to add as watched |

**Examples:**
- `sorty://watched` - Open watched folders
- `sorty://watched?action=add&path=/Users/me/Downloads` - Add Downloads as watched

### Rules

| Route | Parameters | Description |
|-------|------------|-------------|
| `sorty://rules` | | Open exclusion rules |
| | `action=add` | Add a new rule |
| | `type=<pattern\|folder\|extension>` | Type of exclusion rule |
| | `pattern=<glob_pattern>` | Pattern to exclude (e.g., "*.tmp") |

**Examples:**
- `sorty://rules` - Open rules view
- `sorty://rules?action=add&type=pattern&pattern=*.log` - Add pattern rule

### Health

| Route | Parameters | Description |
|-------|------------|-------------|

### Navigation Routes

| Route | Parameters | Description |
|-------|------------|-------------|
| `sorty://settings` | | Open Settings |
| `sorty://learnings` | | Open Learnings |
| `sorty://history` | | Open History |
| `sorty://help` | | Open Help |
| `sorty://help` | `section=updates` | Jump to updates section |

---

## Watched Folders

### Setting Up Watched Folders

1. Go to Settings → Watched Folders
2. Click "Add Folder"
3. Select the directory to monitor
4. Configure per-folder settings

### Per-Folder Settings

Each watched folder can have:
- Its own persona (e.g., Developer for your code folder)
- Custom enable/disable state
- Smart Drop mode settings

### Smart Drop Mode

When enabled, only **new** files dropped into the folder root are organized:
- Existing files and nested contents are left untouched
- Prevents infinite reorganization loops
- Files are sorted into existing folder structure

### Calibration

Run "Calibrate" to perform a one-time full organization. This establishes the baseline folder structure that Smart Drop will use going forward.

---

## Exclusion Rules

### Types of Rules

| Rule Type | Examples |
|-----------|----------|
| **Pattern Matching** | `*.log`, `*.tmp`, `config*` |
| **Folder Exclusions** | `/node_modules`, `/.git`, `/venv` |
| **Finder Tags** | Red, Orange, Yellow, Green, Blue, Purple, Gray |
| **Extension Filters** | `.DS_Store`, `.gitignore` |
| **Size-Based** | Files > 1GB, Files < 1KB |

### Creating Rules

1. Go to Settings → Exclusion Rules
2. Click "Add Rule"
3. Choose rule type and enter criteria
4. Rule applies immediately to future organizations

Finder tag exclusions also apply to Watched Folders. If you tag a folder, Sorty leaves the folder and everything inside it alone.

### Common Exclusion Patterns

- `node_modules/*` - JavaScript dependencies
- `.git/*` - Git repository data
- `*.tmp`, `*.temp` - Temporary files
- `Desktop.ini`, `.DS_Store` - System files
- `*.log` - Log files

---

## Keyboard Shortcuts

### Navigation

| Shortcut | Action |
|----------|--------|
| ⌘1 | Go to Organize |
| ⌘3 | Go to Duplicates |
| ⌘4 | Go to Exclusions |
| ⌘5 | Go to Watched Folders |
| ⌘, | Open Settings |
| ⇧⌘H | Open History |
| ⇧⌘L | Open The Learnings |
| ⌘\ | Toggle Sidebar |

### File Operations

| Shortcut | Action |
|----------|--------|
| ⌘N | New Session |
| ⌘O | Open Directory |
| ⌘E | Export Results |
| ⌘A | Select All Files |
| ⌘Z | Undo |

### Organization

| Shortcut | Action |
|----------|--------|
| ⌘R | Start Organization |
| ⇧⌘R | Regenerate Organization |
| ⌘⏎ | Apply Changes |
| ⇧⌘P | Preview Changes |
| ⎋ | Cancel Operation |

## Menu Bar Commands

Sorty provides a comprehensive menu bar with commands organized into logical groups.

### File Menu

| Command | Shortcut | Description |
|---------|----------|-------------|
| New Session | ⌘N | Clear current state and start fresh |
| Open Directory... | ⌘O | Select a folder to organize |
| Export Results... | ⌘E | Export organization plan as JSON, CSV, or HTML |

### View Menu

| Command | Shortcut | Description |
|---------|----------|-------------|
| Show/Hide Sidebar | ⌘\ | Toggle the navigation sidebar |
| Organize | ⌘1 | Navigate to main organization view |
| Duplicates | ⌘3 | Navigate to duplicate finder |
| Exclusions | ⌘4 | Navigate to exclusion rules |
| Watched Folders | ⌘5 | Navigate to watched folders |
| The Learnings | ⇧⌘L | Navigate to learning dashboard |
| Settings | ⌘, | Open app settings |
| History | ⇧⌘H | View organization history |

### Organize Menu

| Command | Shortcut | Description |
|---------|----------|-------------|
| Start Organization | ⌘R | Begin AI analysis of selected folder |
| Regenerate Organization | ⇧⌘R | Re-run analysis with current settings |
| Apply Changes | ⌘⏎ | Execute the proposed organization |
| Preview Changes | ⇧⌘P | Preview what will change before applying |
| Cancel | ⎋ | Stop the current operation |

### Learnings Menu

| Command | Shortcut | Description |
|---------|----------|-------------|
| Open Dashboard | ⇧⌘L | Open The Learnings dashboard |
| View Statistics | — | See learning metrics and progress |
| Pause Learning / Resume Learning | — | Temporarily stop or restart data collection |
| Export Learning Profile... | — | Save preferences to a file |
| Import Learning Profile... | — | Load preferences from a file |

### Help Menu

| Command | Shortcut | Description |
|---------|----------|-------------|
| Sorty Help | ⌘? | Open this help documentation |
| Delete All Usage Data | — | Remove Safe Deletion and usage history |
| GitHub Repository | — | Open Sorty's GitHub page |
| About Sorty | — | View app version and credits |
| Check for Updates... | — | Check for new versions of Sorty |

---

## Version & Updates

### Checking for Updates

Sorty includes a built-in update checker that helps you stay current with the latest features and bug fixes.

**To check for updates:**
1. Go to **Help → Check for Updates...** (or use the About menu)
2. Sorty will check the configured Sparkle update feed for a newer version
3. If an update is available, Sparkle will show the available release and install options

For a new installation, download [`Sorty.zip`](https://github.com/sorty-organizer/Sorty/releases/latest/download/Sorty.zip), open it, and move `Sorty.app` to `/Applications`. Sorty shows onboarding until setup is completed.

### How the Update System Works

The update checker uses **Sparkle** to compare your installed version against the configured appcast feed:

1. **Feed Request**: Sorty checks the configured Sparkle appcast feed
2. **Version Comparison**: Sparkle compares the feed version with the current app version
3. **Release Notes**: If a newer version exists, Sparkle displays the release notes
4. **Install Flow**: Sparkle handles download, verification, and installation

### What's Included in Updates

Updates may include:
- New AI providers and models
- Enhanced organization algorithms
- Bug fixes and performance improvements
- New personas and file type support
- Security patches

### Automatic Notifications

Sorty periodically checks for updates in the background and will notify you when a new version is available. You can always manually check via the Help menu.

### Update Check Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| "Rate limit exceeded" | Too many API requests | Wait 60 minutes, then retry |
| "Network error" | No internet connection | Check your connection and retry |
| "404 Not Found" | No releases published yet | The repository has no releases; check back later |
| Timeout | Slow connection or GitHub issues | Increase timeout in settings or retry later |

### Release Notes

View the full changelog at:
- **In-app**: Check for Updates dialog shows release notes
- **Online**: [GitHub Releases](https://github.com/sorty-organizer/Sorty/releases)

---

## Troubleshooting

Choose **Help → Report Bug** to describe a problem. Sorty opens a GitHub issue draft for you to review and submit. If anonymous analytics is allowed and internet access is enabled, you can separately choose to send your description to Sentry. Review it for private details first. Sentry feedback is queued when you open the GitHub draft; the GitHub issue still needs your submission.

### Support Assistant

Open **Settings → Troubleshooting** to run Sorty's local support checks. The assistant appears at the bottom of the page, verifies the active provider configuration, internet privacy policy, Finder integration, and analytics support context, then links directly to the setting that can resolve each detected problem.

**Generate Diagnostic Report** in **Settings → Advanced → Developer** lets you choose where to save a ZIP containing app and system details, bounded configuration (exact model ID, auth readiness, timeouts, vision/rename options as presence flags, counts, and buckets — never keys, URLs, prompts, or custom instruction text), storage/permission/Finder-enablement signals, structural log counts with per-file sizes, time range, and a signal histogram, a privacy-safe failure timeline with truncation totals, local activity totals (top categories), and PostHog/Sentry status including active experiment IDs. When reliability sharing is active, Sorty also sends Sentry a sanitized event with the same random diagnostic ID, letting support correlate the public ZIP with server-side reliability data without identifying the user. The archive deliberately excludes raw log messages, filenames, paths, contents, prompts, credentials, API URLs and hosts, user or device identifiers, timezone cities, PostHog event payloads, Sentry envelopes, and crash dumps.

### AI Not Responding

- ✓ Check your internet connection
- ✓ Verify your API Key is correct in Settings
- ✓ Ensure the API URL is correct for your provider
- ✓ Check if the selected model is available
- ✓ Try increasing the Request Timeout in Advanced Settings
- ✓ For Ollama: ensure the server is running (`ollama serve`)

### Files Not Moving

- ✓ Check Exclusion Rules to ensure files aren't protected
- ✓ Verify you have write permissions for the directory
- ✓ Ensure the source files still exist
- ✓ Check for file locks (files open in other apps)

### Slow Organization

- ✓ Disable Deep Scan for faster processing
- ✓ Reduce the number of files by using exclusions
- ✓ Enable Streaming for responsive feedback
- ✓ Consider using a faster AI model

### Tags Not Appearing

- ✓ Ensure "Enable File Tagging" is ON in Settings
- ✓ Tags only apply after "Apply Changes" is clicked
- ✓ Refresh Finder (close and reopen the folder)
- ✓ Enable reasoning to verify AI is suggesting tags

### Safe Deletion Issues

- ✓ Check History tab for restoration options
- ✓ Verify files weren't permanently deleted (Safe Deletion was ON)
- ✓ Look in the original locations for restored files

### Update Check Issues

- ✓ **Network error**: Check your internet connection and firewall settings.
- ✓ **Feed unavailable**: The appcast may not be reachable yet. Retry later.
- ✓ **Timeout**: Try again later; the update feed may be temporarily unavailable.
- ✓ **Version parsing error**: The appcast format may have changed. Check the [releases page](https://github.com/sorty-organizer/Sorty/releases) manually.

---

## Privacy & Data

### What Data is Processed

| Data Type | Local | Cloud |
|-----------|-------|-------|
| File names | ✓ | ✓ (sent to AI) |
| File metadata | ✓ | ✓ (sent to AI) |
| File content | ✓ (Deep Scan only) | ✗ |
| Organization history | ✓ | ✗ |
| Settings | ✓ | ✗ |
| Anonymous feature and screen analytics | ✓ (choice and queue) | ✓ (PostHog, opt-in only) |
| Sanitized crash reports | ✓ (queued after a crash) | ✓ (PostHog, opt-in only) |

### AI Providers

- **Apple Intelligence**: Processed on-device (requires M-series chip + macOS 15.1+)
- **OpenAI/Compatible**: Cloud-based, file names and metadata sent to API
- **Ollama**: Local processing, nothing leaves your machine

### Data Storage

All data is stored locally:
- Organization history: `~/Library/Preferences/`
- Safe deletion metadata: Local database
- Settings: UserDefaults

### Anonymous Analytics

Sorty uses PostHog for the lightweight product and reliability telemetry that is
normal for most apps, such as understanding which screens and features are used
and diagnosing failures. It asks once after onboarding before starting anonymous
analytics or crash reporting. Declining keeps the PostHog SDK dormant and the
decision is not reported. If enabled, Sorty records named screens, feature and
workflow actions, important buttons, coarse count and duration buckets, and
sanitized error or crash context. It does not create a person profile or send a
name, email address, account identifier, advertising identifier, or any other
information linked to you. It never sends file names, paths, contents, prompts,
AI responses, or API keys to PostHog; file contents are never transmitted to
PostHog.

This is separate from AI processing. If you explicitly enable Deep Scan with a
cloud AI provider, content may be sent directly to that provider for the
organization plan, never to Sorty or PostHog.

Change the choice at any time in **Settings → Advanced → Privacy**. Turning on
**Block Internet Connections** also suspends analytics, and deleting all usage
data clears the local analytics queue and consent preference.

### Clearing Data

- **Help → Delete All Usage Data**: Removes Safe Deletion history
- **Reset Settings**: Restores all settings to defaults

---

## FAQ

### Q: Can I undo organization?

**A**: Yes! Press ⌘Z immediately after applying, or go to History and click "Revert" on any past session.

### Q: Will Sorty delete my files?

**A**: No. Organization only **moves** files into folders. The only deletion feature is for duplicates, and it has Safe Deletion enabled by default.

### Q: Does "Deep Scan" upload my file contents?

**A**: No. Deep Scan extracts metadata locally. Only file names and metadata summaries are sent to the AI.

### Q: Can I use Sorty offline?

**A**: Yes, with Ollama (local AI) or Apple Intelligence. Cloud providers (OpenAI) require internet.

### Q: How do I get better organization results?

**A**: 
1. Choose the right persona for your work
2. Enable Deep Scan for content-aware organization
3. Provide custom instructions before organizing
4. Use exclusion rules to protect files that shouldn't move

### Q: Why are some files marked "unorganized"?

**A**: The AI couldn't confidently categorize them. This happens with:
- Files with generic names
- Uncommon file types
- Files that don't fit clear categories

### Q: Can I customize the folder names?

**A**: Yes! After previewing, you can edit folder names before applying. Or provide custom instructions like "use lowercase folder names".

---

*Sorty © 2025-2026 Shirish Pothi. Special thanks to the Apple Developer community.*
