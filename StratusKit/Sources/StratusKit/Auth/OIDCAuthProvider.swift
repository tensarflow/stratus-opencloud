import Foundation

/// Bearer tokens with transparent refresh. Refreshes happen under a cross-process `FileLock` and
/// re-read the Keychain first, so the app and the extension never both spend one refresh token.
public actor OIDCAuthProvider: AuthProvider {
    static let refreshMargin: TimeInterval = 60

    private let store: AccountStore
    private let lockURL: URL
    private let now: @Sendable () -> Date
    private let refresher: @Sendable (Account) async throws -> Tokens
    private var lastIssuedAccessToken: String?
    /// The refresh in flight, shared by every caller that needs one meanwhile. It is an unstructured
    /// task, so a caller's cancellation never cancels a refresh others are waiting for.
    private var inFlight: Task<Account, Error>?

    public init(store: AccountStore, lockURL: URL, now: @escaping @Sendable () -> Date = Date.init,
                refresher: @escaping @Sendable (Account) async throws -> Tokens) {
        self.store = store
        self.lockURL = lockURL
        self.now = now
        self.refresher = refresher
    }

    public func authorizationHeader() async throws -> String {
        guard var account = try store.load() else { throw AuthError.signInRequired }
        if needsRefresh(account) { account = try await refresh(force: false) }
        lastIssuedAccessToken = account.tokens.accessToken
        return "Bearer " + account.tokens.accessToken
    }

    public func refreshAfterUnauthorized() async throws {
        _ = try await refresh(force: true)
    }

    /// The default production refresher: discovers the IdP once (cached in memory), then refreshes.
    public static func oidcRefresher(session: URLSession = .shared) -> @Sendable (Account) async throws -> Tokens {
        let cache = ConfigCache()
        return { account in
            let client = OIDCClient(serverURL: account.serverURL, clientId: account.clientId, session: session)
            let config = try await cache.config(for: client)
            return try await client.refresh(account.tokens.refreshToken, config: config)
        }
    }

    // MARK: -

    private func needsRefresh(_ account: Account) -> Bool {
        account.tokens.expiresAt.timeIntervalSince(now()) < Self.refreshMargin
    }

    private func refresh(force: Bool) async throws -> Account {
        if let inFlight { return try await inFlight.value }
        let task = Task { [store, lockURL, now, refresher, issued = lastIssuedAccessToken] in
            try await Self.refreshLocked(force: force, store: store, lockURL: lockURL, now: now,
                                         refresher: refresher, issued: issued)
        }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        return try await task.value
    }

    private static func refreshLocked(force: Bool, store: AccountStore, lockURL: URL, now: @Sendable () -> Date,
                                      refresher: @Sendable (Account) async throws -> Tokens,
                                      issued: String?) async throws -> Account {
        try await FileLock.withLock(at: lockURL) {
            guard var account = try store.load() else { throw AuthError.signInRequired }
            // Someone else (another process, or an earlier caller here) already refreshed.
            let rotatedByOthers = force && issued != nil && account.tokens.accessToken != issued
            let stillValid = account.tokens.expiresAt.timeIntervalSince(now()) >= refreshMargin
            if force ? rotatedByOthers && stillValid : stillValid { return account }
            account.tokens = try await refresher(account)
            try store.save(account)
            return account
        }
    }
}

private actor ConfigCache {
    private var configs: [URL: OIDCConfig] = [:]

    func config(for client: OIDCClient) async throws -> OIDCConfig {
        if let cached = configs[client.serverURL] { return cached }
        let found = try await client.discover()
        configs[client.serverURL] = found
        return found
    }
}
