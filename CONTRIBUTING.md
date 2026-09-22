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

To add support for a new AI service:

1. **Create Client Implementation** (`Sources/SortyLib/AI/NewProviderClient.swift`):
```swift
import Foundation

public struct NewProviderClient: AIClientProtocol {
    private let apiKey: String
    private let baseURL: URL
    
    public var streamingDelegate: StreamingDelegate?
    
    public init(apiKey: String, baseURL: String) {
        self.apiKey = apiKey
        self.baseURL = URL(string: baseURL)!
    }
    
    public func analyze(files: [FileItem], 
                       persona: Persona,
                       options: OrganizationOptions) async throws -> OrganizationPlan {
        // 1. Build request using PromptBuilder
        // 2. Make network request
        // 3. Parse response with ResponseParser
        // 4. Return OrganizationPlan
    }
    
    public func checkHealth() async throws {
        // Verify API connectivity
    }
}
```

2. **Register in Factory** (`AIClientFactory.swift`):
```swift
case .newProvider:
    return NewProviderClient(apiKey: config.apiKey, baseURL: config.baseURL)
```

3. **Add Configuration** (`AIProvider.swift`):
```swift
public enum AIProvider: String, CaseIterable {
    case newProvider = "New Provider Name"
    
    public var defaultModel: String {
        switch self {
        case .newProvider: return "default-model-name"
        }
    }
}
```

4. **Add Tests** (`Tests/SortyTests/NewProviderClientTests.swift`):
```swift
func testAnalyze() async throws {
    let client = NewProviderClient(apiKey: "test", baseURL: "http://localhost")
    let files = [FileItem(name: "test.txt", path: "/tmp/test.txt")]
    let plan = try await client.analyze(files: files, ...)
    XCTAssertFalse(plan.operations.isEmpty)
}
```

5. **Update Documentation**: Add provider details to README.md and `HELP.md` or `HelpSettingsView.swift`

## Testing Requirements

### Unit Tests

All new functionality requires unit tests:

```swift
import XCTest
@testable import SortyLib

class FeatureNameTests: XCTestCase {
    func testFeature() {
        // Arrange
        let input = ...
        
        // Act
        let result = feature.process(input)
        
        // Assert
        XCTAssertEqual(result.expected, actual)
    }
}
```

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
   - For small code changes, run one relevant local test only if it materially speeds debugging.
   - For UI polish or documentation-only changes, local verification is optional.
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

1. Push the release branch and wait for **Swift CI** to pass on Blacksmith.
2. Trigger the **Release** workflow from GitHub Actions with the target version, or push the intended `v*` tag.
3. Confirm the release workflow completed all required Blacksmith jobs: changelog preparation, current test inventory, parallel unit tests, universal app build, Sparkle appcast generation, and release publication.
4. Use local release commands only to reproduce or debug a failure from the Blacksmith run.

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
