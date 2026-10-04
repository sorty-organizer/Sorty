# Contributing to Sorty

Thank you for your interest in contributing to Sorty. This document provides comprehensive guidelines for development, testing, and submitting changes.

## Code of Conduct

This project follows our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold these standards. Report violations via [GitHub Discussions](https://github.com/sorty-organizer/Sorty/discussions).

## Development Environment

### Prerequisites

- macOS 15.0 or later
- Xcode 16.0 or later (including Swift 6.0)
- Git
- Optional: Ollama for local AI testing

### Initial Setup

```bash
# Clone the repository
git clone https://github.com/sorty-organizer/Sorty.git
cd Sorty

# Install dependencies
swift package resolve

# Build the project
make dev

# Optional: run one focused diagnostic test while developing
swift test --disable-sandbox --filter SortyTests.TestClass/testMethod
```

### Useful Make Commands

| Command | Purpose |
|---------|---------|
| `make build` | Full local build with tests, for diagnostics |
| `make run` | Build and launch app |
| `make now` | Fast debug build + launch (recommended for dev) |
| `make dev` | Fastest build (debug, no tests, no launch) |
| `make test` | Run local unit tests, for diagnostics |
| `make test-fast` | Run local fast unit tests only |
| `make install` | Install app to /Applications |
| `make harness` | Preview harness for rapid UI iteration |
| `make ci` | Run local CI-style diagnostics |
| `make ci-report` | Legacy local CI status reporting; do not use to skip Blacksmith |
| `make benchmark` | Measure build times |

For the full fast development loop guide, see [docs/agent-guides/fast-loop.md](docs/agent-guides/fast-loop.md).

## Architecture Overview

Sorty uses MVVM with Service Layers. Understanding the architecture helps you make consistent contributions.

### Key Architectural Patterns

**State Management:**
- `@MainActor` classes for thread safety
- `@EnvironmentObject` for dependency injection
- `ObservableObject` for reactive UI updates
- Managers handle business logic, ViewModels handle presentation

**AI Provider System:**
- All AI clients implement `AIClientProtocol`
- Factory pattern via `AIClientFactory`
- Protocol defines: `analyze(files:)`, `generateText(prompt:)`, `checkHealth()`

**Data Flow:**
```
View → ViewModel/Manager → FolderOrganizer → AIClient → OrganizationPlan → Preview → Apply
```

### Project Structure

```
Sources/
├── SortyApp/           # App entry point, AppCoordinator
├── SortyLib/
│   ├── AI/             # AI clients, prompts, parsers
│   ├── FileSystem/     # File operations, bookmarks
│   ├── Models/         # Data models, organization plans
│   ├── Services/       # Business logic, managers
│   ├── ViewModels/     # Presentation logic
│   ├── Views/          # SwiftUI views
│   └── Utilities/      # Helpers, security, deeplinks
```

## Code Style Guidelines

### Swift Conventions

Follow the [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/):

- Use descriptive names that read well at call sites
- Prefer methods and properties over free functions
- Use `lowerCamelCase` for variables, `UpperCamelCase` for types
- Prefer strong type inference where clear

### Sorty-Specific Conventions

**Manager Classes:**
```swift
@MainActor
class SomeManager: ObservableObject {
    @Published var state: SomeState
    // Business logic here
}
```

**AI Client Implementation:**
```swift
public struct SomeAIClient: AIClientProtocol {
    public var streamingDelegate: StreamingDelegate?
    
    public func analyze(files: [FileItem], ...) async throws -> OrganizationPlan {
        // Implementation
    }
}
```

**UI Testing Support:**
```swift
// Always add accessibility identifiers
Button("Organize") {}
    .accessibilityIdentifier("OrganizeButton")
```

### Naming Conventions

- **Files**: `PascalCase.swift`
- **Tests**: `ComponentNameTests.swift`
- **Views**: Suffix with `View` (e.g., `SettingsView`)
- **Managers**: Suffix with `Manager` (e.g., `FileSystemManager`)
- **Protocols**: Describe capability (e.g., `AIClientProtocol`)

## Adding a New AI Provider

1. Add the client in `Sources/SortyAI/` and implement the current
   [AIClientProtocol](Sources/SortyAI/AIClientProtocol.swift). Use an existing
   client for the request, cancellation, streaming, and error-handling pattern.
2. Add the provider case and configuration in
   [AIConfig.swift](Sources/SortyModels/AIConfig.swift), including its default
   model, endpoint, and supported authentication methods.
3. Register the client in [AIClientFactory.swift](Sources/SortyAI/AIClientFactory.swift).
   Keep credential resolution and transport details inside the AI target.
4. Add focused coverage for the provider's distinct transport or authentication
   contract. Follow the [test audit](.agents/skills/test-audit/SKILL.md) value bar;
   reuse shared request and parser coverage.
5. Update README.md and HELP.md for any user-facing setup or capability change.

## Testing Requirements

### Unit Tests

Add tests for observable behavior and credible regressions. Before adding or
changing a test, follow the [test audit](.agents/skills/test-audit/SKILL.md).
Extend existing owner-boundary coverage when it already exercises the contract;
avoid tests that only restate defaults or implementation details.

### Testing Standards

- Use `MockAIClient` for testing AI-dependent features
- Create temporary directories in `setUp()`, clean in `tearDown()`
- Test edge cases (empty inputs, invalid paths, network failures)
- Use `XCTAssertThrowsError` for error conditions

### UI Tests

Add `accessibilityIdentifier` to all interactive elements:

```swift
.accessibilityIdentifier("SettingsSidebarItem")
.accessibilityIdentifier("PersonaPickerButton")
```

## Commit, Push, and Pull Request Process

Prefer small, reviewable commits and push them early. The goal is to get Blacksmith feedback on the actual branch state as work progresses, not to hold a large local-only batch until the end.

### Before Submitting

1. **Commit and push coherent checkpoints**:
   - Commit after each focused fix, feature slice, or documentation update.
   - Push the branch after meaningful checkpoints so Blacksmith starts validating while follow-up work can continue.
   - If Blacksmith fails, fix it in a follow-up commit and push again.

2. **Keep local checks focused**:
   - For minor changes, skip local verification as required by AGENTS.md.
   - For larger changes, use focused diagnostics appropriate to the affected behavior.
   - Do not run `make ci-report`; Blacksmith checks must run for the pushed commit.

3. **Check Code Style**:
   - No warnings in Xcode
   - Consistent with existing code
   - Proper documentation comments for public APIs

4. **Update Documentation**:
   - README.md if user-facing changes
   - `HELP.md` or `HelpSettingsView.swift` if adding new features
   - AGENTS.md if changing build process

### PR Requirements

- Clear description of what changed and why
- Link to related issues (e.g., "Fixes #123")
- Small, coherent commits that reviewers can inspect independently
- Screenshots for UI changes
- Blacksmith Swift CI result for the pushed branch
- Any local diagnostic command you ran, clearly marked as local

### Review Process

1. Automated Blacksmith CI runs security checks, build, current test inventory, parallel unit tests, and app bundle validation
2. Maintainers review for code quality and architecture alignment
3. Feedback is provided within 48 hours
4. Changes may be requested before approval

## Release Process

Releases are validated and built on Blacksmith. Do not create release confidence from local `make release`, `make prerelease`, or `make ci` output.
Use [the Sorty release checklist](.agents/skills/sorty-release/SKILL.md) to prepare version metadata, release notes, artwork, the in-app tour, Sparkle, and the website before publishing.

1. Push `main` and wait for **Swift CI** to pass on Blacksmith.
2. Trigger the **Release** workflow from GitHub Actions with the target version, or push the intended `v*` tag.
3. Confirm the release workflow completed all required Blacksmith jobs: changelog preparation, current test inventory, serial unit tests, universal app build, Sparkle appcast generation, and release publication.
4. Use local release commands only to reproduce or debug a failure from the Blacksmith run.

To check the release path without publishing, dispatch it on `main` with the
current version from `Info.plist` and `validate_only=true`:

```bash
gh workflow run release.yml --ref main -f version=1.3.0 -f validate_only=true
```

This runs tests, builds both architectures, verifies the signed ZIP, launches the
packaged app, builds the installer DMG, and validates the Sparkle appcast. The
DMG is saved as the `release-dmg` workflow artifact, including validation runs.
It skips Sentry publication,
tag creation, and GitHub release publication. A successful run also saves the
universal build cache on `main`, where subsequent releases can restore it.
Normal releases leave `validate_only` off. Tests and the universal build run in
parallel jobs; tests within the release test job run serially because they share
macOS Trash and Keychain services.

Sentry release metadata and symbols publish in a separate job after the GitHub
release succeeds. Check that job before treating crash symbolication as ready;
retry it if needed. Compilation jobs in CI and Release pin Xcode 26.3.
Release builds retain both architectures and whole-module Swift optimization,
with Thin LTO disabled.

The release publishes `Sorty.dmg` for drag-to-install setup and `Sorty.zip` for
Sparkle updates. To package an existing release app locally, run
`bash scripts/package-dmg.sh`. It uses a temporary Python environment with
`dmgbuild==1.6.7`, the artwork in `Assets/DMG`, and a saved Finder layout without
UI automation. Python 3.10+ and network access to PyPI are required. It verifies
the app signature and disk image, then writes `releases/Sorty.dmg`. Temporary
files are removed automatically. This does not sign or notarize the DMG.

The local `make release`, `scripts/release.sh`, and `scripts/auto-release.sh`
also call this same DMG packager after creating the ZIP. `make release` keeps
its ZIP name, `Sorty-macOS.zip`; the hosted workflow publishes `Sorty.zip`.
All paths use the committed background and `scripts/dmg-settings.py` without
regenerating the artwork or changing the Finder layout. Keep the window size,
icon coordinates, icon size, text size, and Retina representations together
when deliberately changing the design. See [the DMG layout](Assets/DMG/README.md).

## Commit Message Guidelines

Use clear, descriptive commit messages:

```
feat: Add support for new AI provider X

- Implement NewProviderClient following AIClientProtocol
- Add configuration UI for API key and model selection
- Include unit tests for client implementation

Fixes #456
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `test`: Adding or fixing tests
- `refactor`: Code change that neither fixes nor adds features
- `perf`: Performance improvement
- `chore`: Build process or auxiliary tool changes

## Documentation

### Code Documentation

Document public APIs with documentation comments:

```swift
/// Analyzes files and generates an organization plan
/// - Parameters:
///   - files: Array of FileItems to analyze
///   - persona: The persona to use for organization logic
///   - options: Organization options (deep scan, temperature, etc.)
/// - Returns: OrganizationPlan containing proposed file operations
/// - Throws: AIClientError if the analysis fails
public func analyze(files: [FileItem], ...) async throws -> OrganizationPlan
```

### User-Facing Documentation

When adding features that affect users:

1. Update relevant `HELP.md` or `HelpSettingsView.swift` sections
2. Add to README.md if significant
3. Update CHANGELOG.md with user-facing description

## Questions and Support

- **General questions**: Open a GitHub Discussion
- **Bug reports**: Use the bug report template
- **Security issues**: Use [GitHub's private vulnerability reporting](https://github.com/sorty-organizer/Sorty/security/advisories/new) (do not open public issues)
- **Code of Conduct violations**: Report via [GitHub Discussions](https://github.com/sorty-organizer/Sorty/discussions)

## License

By contributing to Sorty, you agree that your contributions will be licensed under the GPL v3 license.

---

Thank you for helping make Sorty better.
