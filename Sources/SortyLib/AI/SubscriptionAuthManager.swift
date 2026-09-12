import Foundation
import Combine

@MainActor
public final class SubscriptionAuthManager: ObservableObject {

    let provider: AIProvider
    private let codexAuthManager: CodexCLIAuthManager
    private var codexStatusSubscription: AnyCancellable?

    @Published var isAuthenticated = false
    @Published var accountLabel: String?
    @Published var authError: String?

    /// Construction does not probe the Codex CLI. The manager mirrors
    /// `CodexCLIAuthManager` as its published state changes, so the launch
    /// probe that `SortyApp` starts after the first window is ready flows
    /// through here without a second subprocess.
    public init(provider: AIProvider, codexAuthManager: CodexCLIAuthManager) {
        self.provider = provider
        self.codexAuthManager = codexAuthManager
        guard provider == .openAI else { return }

        codexStatusSubscription = Publishers.CombineLatest(
            codexAuthManager.$isAuthenticated,
            codexAuthManager.$accountEmail
        )
        .sink { [weak self] isAuthenticated, accountEmail in
            self?.mirrorCodexStatus(isAuthenticated: isAuthenticated, accountEmail: accountEmail)
        }
    }

    var hasAccountSession: Bool {
        isAuthenticated
    }

    var accountStatusText: String {
        guard isAuthenticated else {
            return "Not signed in via Codex CLI"
        }
        if let accountLabel, !accountLabel.isEmpty {
            return "Signed in as \(accountLabel)"
        }
        return "Signed in via Codex CLI"
    }

    /// Explicit refresh, used by settings and setup repair. Launch relies on the
    /// Combine mirror instead so it never triggers an extra CLI probe.
    public func checkAuthenticationStatus() {
        guard provider == .openAI else {
            isAuthenticated = false
            accountLabel = nil
            return
        }

        let codex = codexAuthManager
        // `refreshStatus()` performs its blocking Codex CLI probes off the main
        // thread; await it so we mirror the resolved state instead of reading
        // stale values, while keeping the main thread free during launch.
        Task { [weak self] in
            await codex.refreshStatus()
            guard let self else { return }
            self.synchronizeWithCodexStatus()
        }
    }

    /// Mirrors the already-resolved Codex state without launching another CLI probe.
    func synchronizeWithCodexStatus() {
        guard provider == .openAI else { return }
        mirrorCodexStatus(
            isAuthenticated: codexAuthManager.isAuthenticated,
            accountEmail: codexAuthManager.accountEmail
        )
    }

    private func mirrorCodexStatus(isAuthenticated: Bool, accountEmail: String?) {
        if self.isAuthenticated != isAuthenticated {
            self.isAuthenticated = isAuthenticated
        }
        if accountLabel != accountEmail {
            accountLabel = accountEmail
        }
    }

    func signOut() {
        guard provider == .openAI else { return }
        codexAuthManager.signOut()
        isAuthenticated = false
        accountLabel = nil
    }
}

extension AIProvider {
    var subscriptionProductName: String {
        switch self {
        case .openAI:
            return "ChatGPT"
        default:
            return displayName
        }
    }
}
