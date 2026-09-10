# Sorty Documentation

Welcome to the official Sorty documentation. Sorty is a smart file organization app for macOS that sorts your files into logical folders.

## Table of Contents

- [Getting Started](#getting-started)
- [Features](#features)
- [Organization](#organization)
- [The Learnings](#the-learnings)
- [Personas](#personas)
- [Duplicate Detection](#duplicate-detection)
- [Exclusion Rules](#exclusion-rules)
- [Watched Folders](#watched-folders)
- [Finder Integration](#finder-integration)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [App Deeplinks](#app-deeplinks)
- [Codex Skill](sorty-skill.md)
- [Startup performance](agent-guides/startup-performance.md)
- [CLI Tool](#cli-tool)
- [Analytics](analytics.md)
- [Privacy & Security](#privacy--security)
- [Uninstalling Sorty](#uninstalling-sorty)
- [FAQ](#faq)

---

## Getting Started

### Quick Start

1. **Select a Folder**: Click "Open Directory" (⌘O) or drag a folder onto the app
2. **Choose a Persona**: Select a persona (e.g., "Developer", "Photographer") to tailor organization
3. **Preview**: Click "Organize" to see Sorty's proposed folder structure
4. **Apply**: Review the preview and click "Apply Changes" — undo anytime with ⌘Z

### System Requirements

- macOS 15.1 or later
- Apple Silicon or Intel Mac
- An AI provider configured (Apple Intelligence, OpenAI, or local Ollama)

---

## Features

### Smart Organization
Sorty sorts based on filenames, file types, and optionally content metadata. It recognizes patterns like project structures, date sequences, and semantic groupings.

### Deep Scan
When enabled, Sorty reads file content for better accuracy:
- PDF text extraction
- Image EXIF metadata (camera, date, location)
- Document titles and keywords
- Audio/video metadata

### File Tagging
Files can be tagged with Finder-compatible tags like "Invoice", "Personal", "Important", or "Archive". These tags are searchable in Spotlight and Finder.

---

## Organization

### How It Works

1. **Scanning**: Sorty scans your selected directory and collects information about each file
2. **Sorty Analysis**: Sorty analyzes patterns (naming conventions, file types, dates, project structures)
3. **Structure Proposal**: Based on analysis, the app proposes a folder structure
4. **Tagging**: Files receive relevant Finder tags for easy searching

### Custom Instructions

Before organizing, you can provide specific guidance:
- "Group all 2024 files together"
- "Organize by client name"
- "Keep design files separate from code"
- "Rename only red-tagged files"
- "Organize only folders tagged green"

Sorty passes existing Finder tag names and visible Finder label colors to the organizer. When an instruction selects a tagged folder, its descendants are included; items that do not match an "only" instruction stay unchanged.

## The Learnings

The Learnings is a passive learning system that builds a personalized understanding of how you prefer to organize files.

### What Gets Learned

| Behavior | Description | Priority |
|----------|-------------|----------|
| Steering Prompts | Post-organization feedback | Highest |
| Guiding Instructions | Pre-organization instructions | High |
| Manual Corrections | Files you move after Sorty organization | Medium |
| Reverts | Sessions you undo | Medium |
| Accepted Regenerations | Differences between discarded previews and the plan you apply, confirmed across repeated runs | Low |

### Security

- **Biometric Protection**: Touch ID / Face ID required
- **AES-256 Encryption**: All learning data encrypted
- **Local Storage Only**: Data never leaves your device

---

## Personas

Personas customize how Sorty organizes your files based on your profession or use case.

| Persona | Best For | Key Features |
|---------|----------|--------------|
| **General** | Most users | Standard categories (Documents, Media, Archives) |
| **Developer** | Programmers | Groups by project, language, and tech stack |
| **Photographer** | Photo professionals | Organizes by shoots, dates, camera metadata |
| **Music Producer** | Audio creators | Groups projects, samples, stems, sessions |
| **Student** | Academic work | Organizes by subject, course, semester |
| **Business** | Professional work | Groups by client, project, fiscal period |

---

## Duplicate Detection

Sorty uses SHA-256 content hashing to find files with identical content, regardless of filename.

Large folders use a staged scan: Sorty indexes lightweight size metadata first, samples the beginning and end of large same-size files, and only reads the full contents of plausible matches. Hashing stays at two concurrent utility-priority workers, and similarity analysis is skipped when a folder is too large to analyze completely within a stable resource budget; exact duplicate results remain complete.

### Safe Deletion

When enabled (default), "deleted" duplicates aren't immediately removed:
- Files are tracked and can be restored later
- Go to History → find the cleanup session → click "Restore"
- Disk space is only recovered after you confirm the deletion

### Bulk Operations

- **Clean Up Exact Copies**: Keeps one copy from each byte-identical group using
  the saved Bulk Cleanup preference, then moves the rest to Trash
- Similar-file matches are always excluded from bulk cleanup and require review
- Duplicate Preferences controls similar-file matching and the saved cleanup rule;
  the cleanup action does not ask for the same choice again

---

## Exclusion Rules

Define files and folders to skip during organization.

### Rule Types

| Type | Description | Example |
|------|-------------|---------|
| File Extension | Exclude by extension | `.tmp`, `.log` |
| File Name | Exclude exact filenames | `.DS_Store` |
| Folder Name | Exclude folders by name | `node_modules`, `.git` |
| Path Contains | Exclude paths with text | `/backup/` |
| Finder Tag | Exclude files and folder trees by Finder tag | Red, Blue |
| File Size | Exclude by size | `> 100MB` |
| Hidden Files | Skip `.` prefixed files | All hidden files |
| System Files | Skip macOS system files | `.DS_Store`, etc. |

### Managing Rules

- **Add Rule**: Click "Add Rule" button
- **Toggle**: Enable/disable individual rules
- **Clear All**: Remove all exclusion rules at once

---

## Watched Folders

Set up automatic organization for folders like Downloads. New files are organized as they arrive.

### Configuration

1. Navigate to Watched Folders view
2. Click "Add Folder" or use suggested folders (Downloads, Desktop, Documents)
3. Configure auto-organization settings
4. Enable the folder to start monitoring

### Large Folder Behavior

Watched folders use a coalesced FSEvents stream and persist the last processed
event cursor, so routine monitoring does not rescan folders or retain metadata
for every existing file. Nested watched roots share the same OS monitor, new
directories are enumerated on a utility queue in 256-file batches, and
automation applies backpressure when its bounded queue is full. Watched-folder
configuration is stored as an append-only journal instead of re-encoding the
entire list after every trigger or setting change.

---

## Finder Integration

Sorty can expose Finder actions without needing terminal commands.

### Quick Action and Finder Sync Repair (In-App)

1. Open **Settings -> Finder Integration**
2. In **Quick Action**, click **Install** (or **Uninstall/Install** to reinstall)
3. Click **Repair Finder Sync** (or **Activate Extension**) to refresh the `.appex` registration
4. Click **Open Extensions** and confirm Sorty is enabled under Finder extensions

If Finder still shows stale state, run the in-app repair buttons again and then re-open Finder.

On the organize screen, click the **Right-Click** tip to open Finder at the selected
folder. Before a folder is selected, it opens Finder at your home folder so you can
try the Sorty actions on any directory. When macOS grants Sorty Accessibility access,
the tip also opens the folder's context menu and highlights the first Sorty action.
macOS may ask for that access the first time. Without it, Finder opens with the
folder selected so you can right-click it yourself.

---

## Keyboard Shortcuts

### Navigation

| Shortcut | Action |
|----------|--------|
| ⌘O | Open Directory |
| ⌘1 | Organize View |
| ⌘3 | Duplicates |
| ⌘4 | Exclusions |
| ⌘5 | Watched Folders |
| ⌘, | Settings |
| ⇧⌘H | History |
| ⇧⌘L | The Learnings |

### Organization

| Shortcut | Action |
|----------|--------|
| ⌘R | Start Organization |
| ⇧⌘R | Regenerate |
| ⌘⏎ | Apply Changes |
| ⌘Z | Undo |
| ⎋ | Cancel |

---

## App Deeplinks

Control Sorty via URL schemes.

### Examples

```
sorty://organize?path=/Users/me/Downloads&autostart=true
sorty://duplicates?path=/Users/me/Documents
sorty://persona?action=generate&prompt=sci-fi%20collector
sorty://watched?action=add&path=/Users/me/Downloads
sorty://rules?action=add&type=pattern&pattern=*.log
sorty://settings
```

---

## CLI Tool

Sorty includes a CLI tool for terminal control.

### Installation

```bash
make install
```

### Usage

```bash
# Organize a folder
sorty organize /path/to/folder --persona developer

# Scan for duplicates
sorty duplicates /path/to/scan --auto

# Add watched folder
sorty watched add /path/to/watch

# Manage learnings
learnings-cli --status
learnings-cli --clear
```

---

## Privacy & Security

### Permission requests

Sorty uses the native macOS request for Files & Folders, Finder Automation, and
Notifications. If macOS requires a manual Settings change, the permission
button flies into a guide beside the matching System Settings pane. Full Disk
Access also lets you drag the Sorty app into the system list. Automation and
Notifications use step-specific guidance instead because those panes do not
accept app drops. Reduce Motion removes the flight while keeping the guide.
Permission status refreshes when Sorty becomes active and when you click
**Refresh Status**. Files & Folders verifies a real read through the saved
bookmark, Full Disk Access opens a protected file, Automation asks macOS about
Finder Apple Events, and Notifications reads Notification Center authorization.
The signed app carries the Apple Events entitlement required to request Finder
automation. Its consent alert explains that Sorty reads selected Finder files and
reveals the folders it organizes.
An Automation request uses macOS's native Allow / Don't Allow alert while the
decision is undecided. Once denied, macOS does not allow Sorty to prompt again,
so Sorty takes you directly to the matching Automation pane instead.
The guide includes **Sorty isn't listed?** for the rare case where macOS has not
registered the app. It returns to Sorty with a copyable, user-run reset command
and clear relaunch steps; the Automation pane itself cannot add an app manually.
After reopening, choosing Enable sends a harmless Finder read request, which
causes macOS to show its standard Allow / Don't Allow alert and register Sorty.
Right-click a granted permission in onboarding or Settings to remove or disable
it. Permissions that macOS does not let apps revoke directly open the matching
System Settings pane.

### Data Processing

| Data Type | Local | Cloud |
|-----------|-------|-------|
| File names | ✓ | ✓ (sent to AI) |
| File metadata | ✓ | ✓ (sent to AI) |
| File content | ✓ (Deep Scan) | Bounded extracted summaries (Deep Scan) |
| Organization history | ✓ | ✗ |
| Settings | ✓ | ✗ |

### AI Providers

- **Apple Intelligence**: Processed on-device (M-series chip required)
- **OpenAI/Compatible**: Cloud-based, metadata sent to API
- **Ollama**: Local processing, nothing leaves your machine

For models whose provider reports reasoning levels, the model picker footer includes a Reasoning effort menu. Automatic keeps the provider's reported default. Explicit levels are remembered separately for each provider and model, and provider-defined levels appear without a Sorty model-name mapping. Models without reasoning metadata do not show the menu.

---

## Uninstalling Sorty

Choose **Help -> Uninstall Sorty...** and confirm. Sorty removes its saved settings, history, app support data, caches, logs, Keychain credentials, Finder actions and extension state, login/background item registrations, notifications, and privacy permissions. It then closes and deletes the app and any temporary copy it staged in `~/Applications`. If you move the running app from Applications to Trash, Sorty detects the move and performs the same cleanup before quitting. Files and folders organized with Sorty are not touched.

If macOS still shows stale Finder extension state, restart Finder:

```bash
killall Finder
```

---

## FAQ

### Can I undo organization?
Yes! Press ⌘Z immediately after applying, or go to History and click "Revert" on any past session.

### Will Sorty delete my files?
No. Organization only moves files into folders. The only deletion feature is for duplicates, with Safe Deletion enabled by default.

### Does Deep Scan upload my file contents?
Sorty always sends relative folder structure and available file metadata to the selected AI provider. Deep Scan also extracts supported content locally and sends bounded text, OCR, EXIF, and media summaries; it does not upload the original file itself.

### Can I use Sorty offline?
Yes, with Ollama (local AI) or Apple Intelligence. Cloud providers require internet.

### How do I get better organization results?
1. Choose the right persona
2. Enable Deep Scan for content-aware organization
3. Provide custom instructions
4. Use exclusion rules to protect files that shouldn't move

---

## Support

- [GitHub Repository](https://github.com/sorty-organizer/Sorty)
- [Report Issues](https://github.com/sorty-organizer/Sorty/issues)
- [Full Help Documentation](../HELP.md)

---

*Sorty © 2026 Shirish Pothi*
