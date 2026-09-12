//
//  RollingCreditsView.swift
//  Sorty
//
//  Looping open-source credits list used across app windows.
//

import SwiftUI
import AppKit

private struct GitHubContributorPayload: Decodable, Sendable {
    let login: String
}

private struct GitHubPullRequestPayload: Decodable, Sendable {
    let user: GitHubContributorPayload?
}

private struct CachedContributorRecord: Codable, Sendable {
    let name: String
    let role: String
    let profileURL: String
}

private struct CachedEndpointRecord: Codable, Sendable {
    let users: [String]
    let etag: String?
    let timestamp: TimeInterval
}

private struct GitHubErrorPayload: Decodable, Sendable {
    let message: String?
}

public struct CreditItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let license: String
    public let url: URL

    public init(name: String, license: String, url: URL) {
        self.id = UUID()
        self.name = name
        self.license = license
        self.url = url
    }
}

public enum OpenSourceCredits {
    public static let all: [CreditItem] = [
        CreditItem(
            name: "Sparkle",
            license: "MIT",
            url: URL(string: "https://github.com/sparkle-project/Sparkle")!
        ),
        CreditItem(
            name: "bsdiff (via Sparkle)",
            license: "BSD-2-Clause",
            url: URL(string: "https://github.com/sparkle-project/Sparkle/blob/master/LICENSE")!
        ),
        CreditItem(
            name: "sais-lite (via Sparkle)",
            license: "MIT",
            url: URL(string: "https://github.com/sparkle-project/Sparkle/blob/master/LICENSE")!
        ),
        CreditItem(
            name: "ed25519 (via Sparkle)",
            license: "zlib",
            url: URL(string: "https://github.com/orlp/ed25519")!
        ),
        CreditItem(
            name: "SUSignatureVerifier (via Sparkle)",
            license: "BSD-2-Clause",
            url: URL(string: "https://github.com/sparkle-project/Sparkle/blob/master/LICENSE")!
        ),
        CreditItem(
            name: "Beam",
            license: "MIT",
            url: URL(string: "https://github.com/tornikegomareli/beam")!
        ),
        CreditItem(
            name: "Permiso",
            license: "MIT",
            url: URL(string: "https://github.com/jevonmao/Permiso")!
        ),
        CreditItem(
            name: "TourKit",
            license: "MIT · design reference",
            url: URL(string: "https://github.com/rampatra/TourKit")!
        ),
        CreditItem(
            name: "SymbolParticleMorph",
            license: "MIT · animation reference",
            url: URL(string: "https://github.com/AndreasInk/SymbolParticleMorph")!
        ),
        CreditItem(
            name: "thinking-orbs",
            license: "MIT · animation reference",
            url: URL(string: "https://github.com/Jakubantalik/thinking-orbs")!
        )
    ]
}

// MARK: - GitHub Contributors Fetcher

@MainActor
final class GitHubContributorsFetcher: ObservableObject {
    @Published private(set) var contributors: [CreditItem] = []
    @Published private(set) var isLoading = false

    private static let repoOwner = "sorty-organizer"
    private static let repoName = "Sorty"
    private static let cacheKey = "cachedGitHubContributors"
    private static let cacheTimestampKey = "cachedGitHubContributorsTimestamp"
    private static let repoEndpointCacheKey = "cachedGitHubContributorsRepoEndpoint"
    private static let prEndpointCacheKey = "cachedGitHubContributorsPREndpoint"
    private static let nextAllowedFetchKey = "cachedGitHubContributorsNextAllowedFetch"
    private static let retryAttemptKey = "cachedGitHubContributorsRetryAttempt"
    private static let cacheTTL: TimeInterval = 86400 // 24 hours
    private static let maxContributors = 120
    private static let initialBackoffDelay: TimeInterval = 10
    private static let maxBackoffDelay: TimeInterval = 600

    private static let loginAllowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

    private enum EndpointFetchStatus {
        case fresh
        case cacheFallback
        case failed
    }

    private struct EndpointFetchResult {
        let users: [GitHubUser]
        let status: EndpointFetchStatus

        static let failed = EndpointFetchResult(users: [], status: .failed)
    }

    private struct RateLimitState {
        let remaining: Int?
        let resetDate: Date?
    }

    private enum ContributorRole: String {
        case repo = "Repo Contributor"
        case pr = "PR Contributor"
        case repoAndPR = "Repo + PR Contributor"
    }

    private var scheduledFetchTask: Task<Void, Never>?
    private var contributorFetchEnabled = true

    func fetchIfNeeded(enabled: Bool = true, forceRefresh: Bool = false) {
        contributorFetchEnabled = enabled

        if !enabled {
            scheduledFetchTask?.cancel()
            scheduledFetchTask = nil
            contributors = []
            isLoading = false
            return
        }

        guard !isLoading else { return }
        if !forceRefresh, !contributors.isEmpty { return }

        if let nextAllowedDate = nextAllowedFetchDate(), nextAllowedDate > Date() {
            if let cached = loadCache() {
                contributors = cached
            }
            scheduleFetch(at: nextAllowedDate)
            return
        }

        if !forceRefresh, let cached = loadCache() {
            contributors = cached
            return
        }

        isLoading = true
        Task { [weak self] in
            guard let self else { return }

            let fetched = await self.fetchContributors()
            guard self.contributorFetchEnabled else {
                self.isLoading = false
                return
            }

            if !fetched.isEmpty {
                self.contributors = fetched
                self.saveCache(fetched)
            } else if let cached = self.loadCache() {
                self.contributors = cached
            }

            self.isLoading = false
        }
    }

    private func fetchContributors() async -> [CreditItem] {
        if isFetchDeferred(), let cached = loadCache() {
            return cached
        }

        var rolesByLogin: [String: Set<ContributorRole>] = [:]
        var loginOrder: [String] = []

        let repoContributors = await fetchRepoContributors()
        for user in repoContributors.users {
            if rolesByLogin[user.login] == nil {
                loginOrder.append(user.login)
            }
            rolesByLogin[user.login, default: []].insert(.repo)
        }

        let prContributors = await fetchPRContributors()
        for user in prContributors.users {
            if rolesByLogin[user.login] == nil {
                loginOrder.append(user.login)
            }
            rolesByLogin[user.login, default: []].insert(.pr)
        }

        if (repoContributors.status == .cacheFallback || prContributors.status == .cacheFallback),
           let cached = loadCache() {
            return cached
        }

        var results: [CreditItem] = []
        for login in loginOrder.prefix(Self.maxContributors) {
            guard let roles = rolesByLogin[login], let profileURL = Self.githubProfileURL(for: login) else {
                continue
            }

            let role: ContributorRole
            if roles.contains(.repo), roles.contains(.pr) {
                role = .repoAndPR
            } else if roles.contains(.repo) {
                role = .repo
            } else {
                role = .pr
            }

            results.append(CreditItem(name: login, license: role.rawValue, url: profileURL))
        }

        if repoContributors.status == .fresh,
           prContributors.status == .fresh,
           !results.isEmpty {
            clearBackoffState()
        }

        return results
    }

    private struct GitHubUser {
        let login: String
    }

    private func fetchRepoContributors() async -> EndpointFetchResult {
        let urlString = "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/contributors?per_page=50"
        return await fetchEndpointLogins(from: urlString, endpointCacheKey: Self.repoEndpointCacheKey) { data in
            await self.decodeRepoLogins(from: data)
        }
    }

    private func fetchPRContributors() async -> EndpointFetchResult {
        let urlString = "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/pulls?state=all&per_page=100"
        return await fetchEndpointLogins(from: urlString, endpointCacheKey: Self.prEndpointCacheKey) { data in
            await self.decodePRLogins(from: data)
        }
    }

    private func fetchEndpointLogins(
        from urlString: String,
        endpointCacheKey: String,
        decodeLogins: @escaping @Sendable (Data) async -> [String]?
    ) async -> EndpointFetchResult {
        let endpointCache = loadEndpointCache(forKey: endpointCacheKey)
        guard let url = URL(string: urlString) else {
            return fallbackResult(from: endpointCache)
        }

        guard NetworkPrivacyPolicy.isRequestAllowed(url: url) else {
            return fallbackResult(from: endpointCache)
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.setValue("Sorty/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            if let etag = endpointCache?.etag, !etag.isEmpty {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await NetworkPrivacyPolicy.sharedSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return fallbackResult(from: endpointCache)
            }

            let rateLimit = parseRateLimit(from: httpResponse)
            if rateLimit.remaining == 0 {
                if let resetDate = rateLimit.resetDate {
                    deferFetch(until: resetDate)
                }
                if let endpointCache {
                    return cachedResult(from: endpointCache)
                }
            }

            switch httpResponse.statusCode {
            case 304:
                if let endpointCache {
                    return EndpointFetchResult(users: users(from: endpointCache.users), status: .fresh)
                }
                return .failed

            case 200:
                guard data.count <= 2_000_000 else {
                    return fallbackResult(from: endpointCache)
                }

                guard let decodedLogins = await decodeLogins(data) else {
                    return fallbackResult(from: endpointCache)
                }

                let sanitizedLogins = sanitizedUniqueLogins(from: decodedLogins)
                if !sanitizedLogins.isEmpty {
                    let endpointPayload = CachedEndpointRecord(
                        users: sanitizedLogins,
                        etag: httpResponse.value(forHTTPHeaderField: "ETag") ?? endpointCache?.etag,
                        timestamp: Date().timeIntervalSince1970
                    )
                    saveEndpointCache(endpointPayload, forKey: endpointCacheKey)
                }

                return EndpointFetchResult(users: users(from: sanitizedLogins), status: .fresh)

            case 403, 429:
                scheduleExponentialBackoff(response: httpResponse, responseData: data)
                return fallbackResult(from: endpointCache)

            default:
                if isAbuseResponse(data) {
                    scheduleExponentialBackoff(response: httpResponse, responseData: data)
                }
                return fallbackResult(from: endpointCache)
            }
        } catch {
            return fallbackResult(from: endpointCache)
        }
    }

    private func fallbackResult(from cache: CachedEndpointRecord?) -> EndpointFetchResult {
        guard let cache else {
            return .failed
        }
        return cachedResult(from: cache)
    }

    private func cachedResult(from cache: CachedEndpointRecord) -> EndpointFetchResult {
        EndpointFetchResult(users: users(from: cache.users), status: .cacheFallback)
    }

    private func users(from logins: [String]) -> [GitHubUser] {
        logins.compactMap { login in
            guard let sanitized = Self.sanitizeLogin(login) else { return nil }
            return GitHubUser(login: sanitized)
        }
    }

    private func sanitizedUniqueLogins(from logins: [String]) -> [String] {
        var seen = Set<String>()
        var sanitizedLogins: [String] = []

        for login in logins {
            guard let sanitized = Self.sanitizeLogin(login) else { continue }
            let key = sanitized.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            sanitizedLogins.append(sanitized)
        }

        return sanitizedLogins
    }

    private func decodeRepoLogins(from data: Data) async -> [String]? {
        do {
            let contributors = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode([GitHubContributorPayload].self, from: data)
            }.value
            return contributors.map(\.login)
        } catch {
            return nil
        }
    }

    private func decodePRLogins(from data: Data) async -> [String]? {
        do {
            let pulls = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode([GitHubPullRequestPayload].self, from: data)
            }.value
            return pulls.compactMap { $0.user?.login }
        } catch {
            return nil
        }
    }

    private func parseRateLimit(from response: HTTPURLResponse) -> RateLimitState {
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let resetTimestamp = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        let resetDate = resetTimestamp.map(Date.init(timeIntervalSince1970:))
        return RateLimitState(remaining: remaining, resetDate: resetDate)
    }

    private func retryAfterInterval(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = TimeInterval(value) else {
            return nil
        }
        return max(0, seconds)
    }

    private func scheduleExponentialBackoff(response: HTTPURLResponse, responseData: Data) {
        let nextAttempt = UserDefaults.standard.integer(forKey: Self.retryAttemptKey) + 1
        UserDefaults.standard.set(nextAttempt, forKey: Self.retryAttemptKey)

        let exponent = Double(max(0, nextAttempt - 1))
        let exponentialDelay = min(Self.maxBackoffDelay, Self.initialBackoffDelay * pow(2.0, exponent))
        let retryAfter = retryAfterInterval(from: response) ?? 0
        let abusePenalty: TimeInterval = isAbuseResponse(responseData) ? 30 : 0

        var targetDate = Date().addingTimeInterval(max(exponentialDelay + abusePenalty, retryAfter))
        if let resetDate = parseRateLimit(from: response).resetDate, resetDate > targetDate {
            targetDate = resetDate
        }

        deferFetch(until: targetDate)
    }

    private func isAbuseResponse(_ data: Data) -> Bool {
        if let payload = try? JSONDecoder().decode(GitHubErrorPayload.self, from: data),
           payload.message?.localizedCaseInsensitiveContains("abuse") == true {
            return true
        }

        guard let body = String(data: data, encoding: .utf8) else { return false }
        return body.localizedCaseInsensitiveContains("abuse")
    }

    private func nextAllowedFetchDate() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: Self.nextAllowedFetchKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func isFetchDeferred() -> Bool {
        guard let nextAllowedDate = nextAllowedFetchDate() else { return false }

        if nextAllowedDate > Date() {
            return true
        }

        UserDefaults.standard.removeObject(forKey: Self.nextAllowedFetchKey)
        return false
    }

    private func deferFetch(until date: Date) {
        let clampedDate = max(date, Date().addingTimeInterval(1))

        if let existingDate = nextAllowedFetchDate(), existingDate > clampedDate {
            scheduleFetch(at: existingDate)
            return
        }

        UserDefaults.standard.set(clampedDate.timeIntervalSince1970, forKey: Self.nextAllowedFetchKey)
        scheduleFetch(at: clampedDate)
    }

    private func clearBackoffState() {
        UserDefaults.standard.removeObject(forKey: Self.retryAttemptKey)
        UserDefaults.standard.removeObject(forKey: Self.nextAllowedFetchKey)
        scheduledFetchTask?.cancel()
        scheduledFetchTask = nil
    }

    private func scheduleFetch(at date: Date) {
        guard contributorFetchEnabled else { return }

        scheduledFetchTask?.cancel()

        let delay = max(1, date.timeIntervalSinceNow)

        scheduledFetchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }

            await MainActor.run {
                self.fetchIfNeeded(enabled: self.contributorFetchEnabled, forceRefresh: true)
            }
        }
    }

    private static func sanitizeLogin(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let limited = String(trimmed.prefix(39))
        let filtered = String(limited.unicodeScalars.filter { loginAllowedCharacters.contains($0) })

        guard !filtered.isEmpty else { return nil }
        return filtered
    }

    private static func githubProfileURL(for login: String) -> URL? {
        URL(string: "https://github.com/\(login)")
    }

    // MARK: - Cache

    private func saveCache(_ items: [CreditItem]) {
        guard !items.isEmpty else { return }

        let payload = items.map {
            CachedContributorRecord(name: $0.name, role: $0.license, profileURL: $0.url.absoluteString)
        }
        guard let encoded = try? JSONEncoder().encode(payload) else { return }

        UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheTimestampKey)
    }

    private func loadCache() -> [CreditItem]? {
        let timestamp = UserDefaults.standard.double(forKey: Self.cacheTimestampKey)
        guard timestamp > 0, Date().timeIntervalSince1970 - timestamp < Self.cacheTTL else { return nil }

        guard let raw = UserDefaults.standard.data(forKey: Self.cacheKey),
              let decoded = try? JSONDecoder().decode([CachedContributorRecord].self, from: raw) else {
            return nil
        }

        let items = decoded.compactMap { dto -> CreditItem? in
            guard let login = Self.sanitizeLogin(dto.name),
                  let url = Self.githubProfileURL(for: login) else {
                return nil
            }

            let role = ContributorRole(rawValue: dto.role)?.rawValue ?? ContributorRole.pr.rawValue
            return CreditItem(name: login, license: role, url: url)
        }

        return items.isEmpty ? nil : items
    }

    private func saveEndpointCache(_ payload: CachedEndpointRecord, forKey key: String) {
        guard let encoded = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(encoded, forKey: key)
    }

    private func loadEndpointCache(forKey key: String) -> CachedEndpointRecord? {
        guard let raw = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CachedEndpointRecord.self, from: raw) else {
            return nil
        }
        return decoded
    }
}

// MARK: - Rolling Credits View

struct RollingCreditsView: View {
    @SortyHotReload private var hotReload
    let title: String
    let items: [CreditItem]
    let rowHeight: CGFloat
    let viewportHeight: CGFloat

    @State private var hoveredRowKey: String?
    @State private var scrollStartDate: Date = .now
    @State private var pausedAt: Date?
    @State private var accumulatedPauseDuration: TimeInterval = 0
    @State private var isWindowVisible = true

    private let pointsPerSecond: CGFloat = 14

    private struct VisibleRow: Identifiable {
        let id: String
        let item: CreditItem
        let y: CGFloat
    }

    init(
        title: String = "Open Source Credits",
        items: [CreditItem] = OpenSourceCredits.all,
        rowHeight: CGFloat = 30,
        viewportHeight: CGFloat = 96
    ) {
        self.title = title
        self.items = items
        self.rowHeight = rowHeight
        self.viewportHeight = viewportHeight
    }

    private var contentHeight: CGFloat {
        rowHeight * CGFloat(items.count)
    }

    private var cycleHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        return contentHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("RollingCreditsTitle")

            GeometryReader { _ in
                Group {
                    if isScrollingSuspended {
                        creditRows(at: pausedAt ?? .now)
                    } else {
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { context in
                            creditRows(at: context.date)
                        }
                    }
                }
            }
            .frame(height: viewportHeight)
            .clipped()
            .onAppear {
                resetScrollClock()
            }
            .onChange(of: items.count) { _, _ in
                resetScrollClock()
            }
            .onChange(of: hoveredRowKey) { oldValue, newValue in
                updateSuspension(
                    wasSuspended: oldValue != nil || !isWindowVisible,
                    isSuspended: newValue != nil || !isWindowVisible
                )
                if oldValue == nil, newValue != nil {
                    HapticFeedbackManager.shared.selection()
                }
            }
            .onChange(of: isWindowVisible) { oldValue, newValue in
                updateSuspension(
                    wasSuspended: hoveredRowKey != nil || !oldValue,
                    isSuspended: hoveredRowKey != nil || !newValue
                )
            }
            .background(WindowVisibilityReader(isVisible: $isWindowVisible))
            .accessibilityIdentifier("RollingCreditsViewport")
        }
        .accessibilityIdentifier("RollingCreditsView")
    }

    private var isScrollingSuspended: Bool {
        hoveredRowKey != nil || !isWindowVisible
    }

    private func creditRows(at date: Date) -> some View {
        let phase = scrollPhase(at: date)
        return ZStack(alignment: .topLeading) {
            ForEach(visibleRows(for: phase)) { row in
                creditRow(item: row.item, rowKey: row.id)
                    .offset(y: row.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func creditRow(item: CreditItem, rowKey: String) -> some View {
        Button {
            HapticFeedbackManager.shared.tap()
            NSWorkspace.shared.open(item.url)
        } label: {
            HStack {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                Text(item.license)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((hoveredRowKey == rowKey ? Color.white.opacity(0.16) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier("RollingCreditRow_\(rowKey)")
        .trackHoveredURL(item.url)
        .onHover { hovering in
            if hovering {
                hoveredRowKey = rowKey
            } else if hoveredRowKey == rowKey {
                hoveredRowKey = nil
            }
        }
    }

    private func visibleRows(for phase: CGFloat) -> [VisibleRow] {
        guard !items.isEmpty, cycleHeight > 0 else { return [] }

        let lowerBound = -rowHeight
        let upperBound = viewportHeight
        let firstIndex = max(0, Int(ceil((phase + lowerBound) / rowHeight)))
        let lastIndex = min(
            items.count * 2 - 1,
            Int(floor((phase + upperBound) / rowHeight))
        )
        guard firstIndex <= lastIndex else { return [] }

        return (firstIndex...lastIndex).map { repeatedIndex in
            let cycle = repeatedIndex / items.count
            let itemIndex = repeatedIndex % items.count
            return VisibleRow(
                id: "\(cycle)-\(itemIndex)",
                item: items[itemIndex],
                y: CGFloat(repeatedIndex) * rowHeight - phase
            )
        }
    }

    private func scrollPhase(at date: Date) -> CGFloat {
        guard cycleHeight > 0 else { return 0 }

        let activeDate = pausedAt ?? date
        let elapsed = max(0, activeDate.timeIntervalSince(scrollStartDate) - accumulatedPauseDuration)
        let traveled = CGFloat(elapsed) * pointsPerSecond
        let wrapped = traveled.truncatingRemainder(dividingBy: cycleHeight)

        return wrapped
    }

    private func resetScrollClock() {
        let remainsPaused = isScrollingSuspended
        scrollStartDate = .now
        pausedAt = remainsPaused ? .now : nil
        accumulatedPauseDuration = 0
    }

    private func updateSuspension(wasSuspended: Bool, isSuspended: Bool) {
        if !wasSuspended, isSuspended {
            pausedAt = .now
        } else if wasSuspended, !isSuspended, let pausedAt {
            accumulatedPauseDuration += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
    }
}
