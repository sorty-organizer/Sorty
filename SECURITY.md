# Security Policy

## Supported Versions

Security fixes are provided for the latest stable release. Users should update to the newest version before reporting an issue that may already be fixed.

## Reporting a Vulnerability

We take security seriously. If you discover a security vulnerability, please follow these steps:

1. **Do not** open a public issue on GitHub
2. Use [GitHub's private vulnerability reporting](https://github.com/sorty-organizer/Sorty/security/advisories/new) to submit details
3. Include steps to reproduce, if possible
4. Allow up to 48 hours for acknowledgment
5. We will provide an estimated timeline for the fix

## Security Considerations

### Release Signing

Sorty releases are distributed as pre-built ZIP archives. The app is not signed with an Apple Developer ID certificate or notarized. Sparkle update archives are separately signed with an Ed25519 update key and verified before installation. When installing the app for the first time:

- macOS may show a security warning on first launch
- You need to remove the quarantine attribute manually: `xattr -cr /Applications/Sorty.app`
- This is common for open source macOS applications without paid developer accounts
- Build from source if you prefer complete control over the build process

### Sandboxing

The main macOS app is **not sandboxed** in the current Xcode configurations.
It can access files permitted by the user's account and macOS privacy controls
(TCC). User-selected file and bookmark entitlements do not confine an
unsandboxed process to selected folders.

The Finder Sync and widget extensions are sandboxed. They share selected state
with the main app through the `group.com.sorty.app` app group.

Release builds are ad hoc signed, so the main app carries
`com.apple.security.cs.disable-library-validation` to load its bundled Sparkle
framework. Library validation would otherwise make it harder for other code to
load into Sorty and use its Full Disk Access. This entitlement can go once
releases are signed with a Developer ID.

### External Links

External `sorty://organize` and `sorty://scan` links select a folder but do not
start scanning or AI processing, including when `autostart=true` is supplied.
The user starts analysis inside Sorty. New watched folders proposed by links
are saved disabled with **Notify and Review** selected; the user must enable
them before monitoring starts. Links to existing watches do not change their
activation or apply policy.

Other links that change settings also leave the change switched off or ask
first:

- `sorty://storage?action=add` and `sorty://exclusions?action=add` (or
  `rules`) save the location or rule turned off.
- `sorty://persona?generate=true` asks before sending the description to the
  AI provider, and does not select the new persona.
- Links can't add folders inside `~/Library` (except iCloud Drive and
  `~/Library/CloudStorage`), hidden folders in the home folder,
  `/Applications`, or `/Library` as watched folders or storage locations.
  Storage locations refuse these folders however they are added, and plans
  that move files into them are rejected.

Path validation rejects unreadable directories and protected system paths,
including symlink targets. Readability alone does not authorize an AI request
or automatic file changes.

### Data Security

#### Local Data Protection

- **The Learnings Profile**: Stored with AES-256 encryption
- **Optional Authentication**: Sensitive-action authentication is disabled by default. When enabled, Sorty uses available biometrics with system-password fallback and a session timeout
- **Organization History**: Stored locally, not encrypted (contains file paths and metadata)
- **Settings**: Stored in standard UserDefaults

#### AI Provider Data

When using cloud-based AI providers (OpenAI, Anthropic, etc.):

- File names and metadata are sent for analysis
- Extracted content can be uploaded when Deep Scan is enabled; image payloads also depend on the vision settings and provider support. Review the effective settings before analyzing sensitive files
- API keys are stored in the macOS Keychain
- Built-in cloud endpoints use HTTPS. Custom endpoints can use HTTP; only use plaintext HTTP with a trusted local service

For maximum privacy, use local options:
- **Ollama**: Processes requests on the configured Ollama server; a loopback endpoint keeps processing on your machine
- **Apple Foundation Models**: On-device processing via Apple Intelligence

### Network Security

- TLS sessions for AI requests require TLS 1.2 or later. Local Ollama and explicitly configured HTTP endpoints do not use TLS
- API keys are never logged or transmitted outside AI provider endpoints
- Update checks fetch Sparkle appcasts and release archives from GitHub Releases over HTTPS
- Anonymous product analytics and crash reports are sent to PostHog only after
  explicit opt-in; file names, paths, contents, prompts, AI responses, and API
  keys are excluded
- **Block Internet Connections** disables analytics along with other non-local
  network access

### Supply Chain Security

- Dependencies are pinned in Package.resolved
- GitHub Actions workflows scan for secrets using Gitleaks
- Automated security checks run on every commit
- Release builds are produced by the repository's published GitHub Actions workflows

## Security Best Practices for Users

### Protecting Your Data

1. **Use Local AI When Possible**
   - A local Ollama endpoint keeps processing on your device
   - Apple Foundation Models require macOS 15+

2. **Secure Your API Keys**
   - Store keys in the macOS Keychain, not in plain text
   - Use environment variables for CLI tools
   - Rotate keys periodically
   - Never commit keys to version control

3. **Review Deep Scan Settings**
   - Deep Scan uploads file content excerpts
   - Only enable for files you are comfortable analyzing remotely
   - Disable for sensitive documents

4. **Monitor Watched Folders**
   - Watched folders have persistent file system access
   - Remove folders you no longer want monitored
   - Review permissions periodically

5. **Backup Before Major Operations**
   - Safe Deletion provides a recovery window
   - Consider Time Machine or other backups for important directories
   - Test the rollback feature before relying on it

### Reporting Suspicious Behavior

If you notice:
- Unexpected network connections
- Files being accessed without your action
- Unusual API usage patterns
- Potential data leaks

Report via [GitHub's private vulnerability reporting](https://github.com/sorty-organizer/Sorty/security/advisories/new) immediately with details.

## Incident Response

In the event of a security incident:

1. We will acknowledge reports within 48 hours
2. Affected users will be notified via GitHub releases and the in-app update system
3. Fixes will be prioritized based on severity
4. Post-incident reports will be published for transparency
5. CVE identifiers will be requested when applicable

## Security-Related Configuration

### Disabling Network Features

To minimize network exposure:

```swift
// Use local AI only
Settings → AI Provider → Ollama (localhost:11434)

// Disable automatic update checks
Settings → Updates → Manual only
```

### Verifying Releases

Sparkle verifies in-app updates against the Ed25519 public key embedded in Sorty. For a manual download, GitHub publishes a SHA-256 digest in the release asset metadata; you can also calculate the local archive digest:

```bash
# Download release
# Check the downloaded archive
shasum -a 256 Sorty-universal.zip

# Or build from source
git clone https://github.com/sorty-organizer/Sorty.git
cd Sorty
make build
```

## Third-Party Security

Sorty integrates with third-party services:

- **Sparkle Framework**: Verifies signed app updates against Sorty's embedded Ed25519 public key
- **Various AI Providers**: Each has their own security policies
- **GitHub**: Hosts releases and update feeds

Review the security policies of your chosen AI provider:
- [OpenAI Security](https://openai.com/security)
- [Anthropic Security](https://www.anthropic.com/security)
- [Groq Security](https://groq.com/security)

## Contact

- **Security Issues**: Use [GitHub's private vulnerability reporting](https://github.com/sorty-organizer/Sorty/security/advisories/new)
- **General Questions**: Open a GitHub discussion (not for vulnerabilities)

---

Last updated: November 2026
