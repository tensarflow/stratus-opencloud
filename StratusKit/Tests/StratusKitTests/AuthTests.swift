import Foundation
import Security
import Testing
@testable import StratusKit

private let server = URL(string: "https://drive.example")!
private let config = OIDCConfig(
    authorizationEndpoint: URL(string: "https://drive.example/signin/v1/identifier/_/authorize")!,
    tokenEndpoint: URL(string: "https://drive.example/konnect/v1/token")!)

private func tokenJSON(access: String = "a2", refresh: String? = "r2", expiresIn: Int = 300) -> String {
    var fields = ["\"access_token\":\"\(access)\"", "\"token_type\":\"Bearer\"", "\"expires_in\":\(expiresIn)"]
    if let refresh { fields.append("\"refresh_token\":\"\(refresh)\"") }
    return "{" + fields.joined(separator: ",") + "}"
}

private func formFields(_ body: Data?) -> [String: String] {
    var c = URLComponents()
    c.percentEncodedQuery = String(decoding: body ?? Data(), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

private final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
}

/// The data-protection keychain needs an entitlement that `swift test` binaries lack
/// (errSecMissingEntitlement, -34018). Tests use it when available and fall back to the
/// file-based keychain otherwise; production always passes an access group and uses the former.
private func makeStore() -> AccountStore {
    let service = "com.arteq.stratus.tests.\(UUID().uuidString)"
    let primary = AccountStore(service: service, accessGroup: nil)
    do { _ = try primary.load(); try primary.save(account(expiringIn: 600)); try primary.delete(); return primary }
    catch { return AccountStore(service: service, accessGroup: nil, useDataProtectionKeychain: false) }
}

private func account(expiringIn seconds: TimeInterval, access: String = "a1", refresh: String = "r1") -> Account {
    Account(serverURL: server, username: "alice", clientId: "OpenCloudDesktop",
            tokens: Tokens(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(seconds)))
}

private func lockURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("stratus-\(UUID().uuidString).lock")
}

extension StubbedSuites {
@Suite struct AuthTests {
    @Test func pkceVector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let p = PKCE()
        #expect(p.verifier.count >= 43)
        #expect(p.challenge == PKCE.challenge(for: p.verifier))
        #expect(PKCE().verifier != p.verifier)
    }

    @Test func authorizeURLParams() throws {
        let client = OIDCClient(serverURL: server)
        let redirect = URL(string: "http://127.0.0.1:5555")!
        let url = client.authorizeURL(config: config, redirectURI: redirect, pkce: PKCE(verifier: "v"), state: "st")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/signin/v1/identifier/_/authorize")
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["response_type"] == "code")
        #expect(q["client_id"] == "OpenCloudDesktop")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["code_challenge"] == PKCE.challenge(for: "v"))
        #expect(q["redirect_uri"] == "http://127.0.0.1:5555")
        #expect(q["state"] == "st")
        #expect(q["scope"] == "openid offline_access profile email")
    }

    @Test func discoveryReadsEndpoints() async throws {
        StubURLProtocol.install { _ in
            StubReply(200, body: """
            {"issuer":"https://drive.example","authorization_endpoint":"https://drive.example/signin/v1/identifier/_/authorize",\
            "token_endpoint":"https://drive.example/konnect/v1/token"}
            """)
        }
        let found = try await OIDCClient(serverURL: server, session: StubURLProtocol.session()).discover()
        #expect(found.tokenEndpoint == config.tokenEndpoint)
        #expect(found.authorizationEndpoint == config.authorizationEndpoint)
        #expect(StubURLProtocol.requests[0].path == "/.well-known/openid-configuration")
    }

    @Test func discoveryRequiresHttpsEndpoints() async throws {
        func discover(authorize: String, token: String) async throws -> OIDCConfig {
            StubURLProtocol.install { _ in
                StubReply(200, body: #"{"authorization_endpoint":"\#(authorize)","token_endpoint":"\#(token)"}"#)
            }
            return try await OIDCClient(serverURL: server, session: StubURLProtocol.session()).discover()
        }
        await #expect(throws: AuthError.insecureEndpoint) {
            try await discover(authorize: "https://drive.example/a", token: "http://drive.example/t")
        }
        await #expect(throws: AuthError.insecureEndpoint) {
            try await discover(authorize: "http://drive.example/a", token: "https://drive.example/t")
        }
        // Plain http is fine on loopback (a local test server).
        for host in ["127.0.0.1:9000", "localhost", "[::1]:8080"] {
            let found = try await discover(authorize: "http://\(host)/a", token: "http://\(host)/t")
            #expect(found.tokenEndpoint.absoluteString == "http://\(host)/t")
        }
    }

    @Test func exchangeAndRefreshParseTokens() async throws {
        let client = OIDCClient(serverURL: server, session: StubURLProtocol.session())
        StubURLProtocol.install { _ in StubReply(200, body: tokenJSON()) }
        let before = Date()
        let t = try await client.exchange(code: "c", redirectURI: URL(string: "http://127.0.0.1:1")!,
                                          pkce: PKCE(verifier: "ver"), config: config)
        #expect(t.accessToken == "a2" && t.refreshToken == "r2")
        #expect(abs(t.expiresAt.timeIntervalSince(before) - 300) < 5)
        var req = StubURLProtocol.requests[0]
        #expect(req.method == "POST")
        #expect(req.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(formFields(req.body) == [
            "grant_type": "authorization_code", "code": "c", "redirect_uri": "http://127.0.0.1:1",
            "client_id": "OpenCloudDesktop", "code_verifier": "ver"])

        StubURLProtocol.install { _ in StubReply(200, body: tokenJSON(access: "a3", refresh: nil)) }
        let r = try await client.refresh("old", config: config)
        #expect(r.accessToken == "a3" && r.refreshToken == "old")
        req = StubURLProtocol.requests[0]
        #expect(formFields(req.body) == [
            "grant_type": "refresh_token", "refresh_token": "old", "client_id": "OpenCloudDesktop"])
    }

    @Test func invalidGrantMeansSignInRequired() async throws {
        StubURLProtocol.install { _ in StubReply(400, body: #"{"error":"invalid_grant","error_description":"x"}"#) }
        let client = OIDCClient(serverURL: server, session: StubURLProtocol.session())
        await #expect(throws: AuthError.signInRequired) { try await client.refresh("old", config: config) }
        StubURLProtocol.install { _ in StubReply(503) }
        await #expect(throws: OpenCloudError.server(503)) { try await client.refresh("old", config: config) }
    }

    @Test func loopbackReceivesCode() async throws {
        let receiver = LoopbackReceiver(state: "s")
        let redirect = try await receiver.start()
        defer { receiver.stop() }
        #expect(redirect.host() == "127.0.0.1")
        async let result = receiver.callback()
        // A stray favicon request must not complete the callback.
        _ = try? await URLSession.shared.data(from: redirect.appending(path: "favicon.ico"))
        // Neither does a callback carrying another state (a forged or stale redirect).
        let (_, forged) = try await URLSession.shared.data(from: URL(string: redirect.absoluteString + "/?code=evil&state=x")!)
        #expect((forged as? HTTPURLResponse)?.statusCode == 400)
        let (data, response) = try await URLSession.shared.data(from: URL(string: redirect.absoluteString + "/?code=abc&state=s")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("You can close this tab."))
        #expect(try await result == ["code": "abc", "state": "s"])
    }

    @Test func loopbackErrorAndTimeout() async throws {
        let failing = LoopbackReceiver(state: "s")
        let redirect = try await failing.start()
        defer { failing.stop() }
        let result = Task { try await failing.callback() }
        // An error for another state is ignored too.
        _ = try await URLSession.shared.data(from: URL(string: redirect.absoluteString + "/?error=x&state=other")!)
        let (data, _) = try await URLSession.shared.data(
            from: URL(string: redirect.absoluteString + "/?error=access_denied&state=s")!)
        #expect(String(decoding: data, as: UTF8.self).contains("Sign-in failed. You can close this tab."))
        await #expect(throws: AuthError.authorizationFailed("access_denied")) { try await result.value }

        let idle = LoopbackReceiver(state: "s", timeout: .milliseconds(100))
        _ = try await idle.start()
        defer { idle.stop() }
        await #expect(throws: AuthError.timedOut) { try await idle.callback() }
    }

    @Test func accountStoreRoundTrip() throws {
        let store = makeStore()
        defer { try? store.delete() }
        #expect(try store.load() == nil)
        let a = account(expiringIn: 100)
        try store.save(a)
        #expect(try store.load()?.tokens.accessToken == "a1")
        var b = a
        b.tokens.accessToken = "a9"
        try store.save(b)
        #expect(try store.load()?.tokens.accessToken == "a9")
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()   // deleting nothing is not an error
    }

    @Test func accountStoreItemIsThisDeviceOnly() throws {
        // Add and update both write these attributes.
        let wanted = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        #expect(AccountStore.writeAttributes(Data())[kSecAttrAccessible as String] as? String == wanted)

        let store = makeStore()
        defer { try? store.delete() }
        try store.save(account(expiringIn: 100))        // add
        try store.save(account(expiringIn: 200))        // update
        // Only the data-protection keychain reports the attribute; `swift test` usually lacks its entitlement.
        guard store.useDataProtectionKeychain else { return }
        var result: CFTypeRef?
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
            kSecAttrAccount as String: "default", kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #expect(SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess)
        #expect((result as? [String: Any])?[kSecAttrAccessible as String] as? String == wanted)
    }

    @Test func secretsAreRedactedInDescriptions() {
        let a = account(expiringIn: 100, access: "SECRET-A", refresh: "SECRET-R")
        for text in [String(describing: a), String(reflecting: a), "\(a)",
                     String(describing: a.tokens), String(reflecting: a.tokens)] {
            #expect(!text.contains("SECRET"), "\(text)")
            #expect(text.contains("<redacted>"))
        }
        #expect(String(describing: a).contains("alice"))
    }

    @Test func errorLogCodeCarriesNoDetails() {
        #expect(ErrorLog.code(URLError(.timedOut)) == "NSURLErrorDomain -1001")
        let detailed = URLError(.badURL, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://secret.example/a.txt")!])
        #expect(!ErrorLog.code(detailed).contains("secret"))
        #expect(!ErrorLog.code(AuthError.authorizationFailed("token=abc")).contains("abc"))
    }

    @Test func reauthenticationKeepsTheAccount() throws {
        let old = account(expiringIn: 10)
        let fresh = Tokens(accessToken: "a9", refreshToken: "r9", expiresAt: Date().addingTimeInterval(300))
        let renewed = try old.reauthenticated(username: "alice", tokens: fresh)
        #expect(renewed.tokens == fresh)
        #expect(renewed.serverURL == old.serverURL && renewed.username == old.username && renewed.clientId == old.clientId)
        #expect(throws: AuthError.accountMismatch) { try old.reauthenticated(username: "someone-else", tokens: fresh) }
    }

    @Test func providerRefreshesOnlyWhenNearExpiry() async throws {
        let store = makeStore()
        defer { try? store.delete() }
        let calls = CallCounter()
        let provider = OIDCAuthProvider(store: store, lockURL: lockURL()) { _ in
            calls.bump()
            return Tokens(accessToken: "new", refreshToken: "r-new", expiresAt: Date().addingTimeInterval(300))
        }

        try store.save(account(expiringIn: 600))
        #expect(try await provider.authorizationHeader() == "Bearer a1")
        #expect(calls.count == 0)

        try store.save(account(expiringIn: 30))
        #expect(try await provider.authorizationHeader() == "Bearer new")
        #expect(calls.count == 1)
        let saved = try #require(try store.load())
        #expect(saved.tokens.accessToken == "new" && saved.tokens.refreshToken == "r-new")

        // Forced refresh after a 401, even though the token is fresh.
        try await provider.refreshAfterUnauthorized()
        #expect(calls.count == 2)
    }

    @Test func providerWithoutAccountOrWithRevokedGrantNeedsSignIn() async throws {
        let store = makeStore()
        defer { try? store.delete() }
        let provider = OIDCAuthProvider(store: store, lockURL: lockURL()) { _ in throw AuthError.signInRequired }
        await #expect(throws: AuthError.signInRequired) { try await provider.authorizationHeader() }
        try store.save(account(expiringIn: 10))
        await #expect(throws: AuthError.signInRequired) { try await provider.authorizationHeader() }
        #expect(try store.load()?.tokens.refreshToken == "r1")   // nothing is wiped on failure
    }

    @Test func concurrentProvidersRefreshOnce() async throws {
        let store = makeStore()
        defer { try? store.delete() }
        try store.save(account(expiringIn: 30))
        let lock = lockURL()
        let calls = CallCounter()
        let refresher: @Sendable (Account) async throws -> Tokens = { _ in
            calls.bump()
            try await Task.sleep(for: .milliseconds(150))
            return Tokens(accessToken: "new", refreshToken: "r-new", expiresAt: Date().addingTimeInterval(300))
        }
        let p1 = OIDCAuthProvider(store: store, lockURL: lock, refresher: refresher)
        let p2 = OIDCAuthProvider(store: store, lockURL: lock, refresher: refresher)
        async let h1 = p1.authorizationHeader()
        async let h2 = p2.authorizationHeader()
        #expect(try await h1 == "Bearer new")
        #expect(try await h2 == "Bearer new")
        #expect(calls.count == 1)
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let store = makeStore()
        defer { try? store.delete() }
        try store.save(account(expiringIn: 30))
        let calls = CallCounter()
        let provider = OIDCAuthProvider(store: store, lockURL: lockURL()) { _ in
            calls.bump()
            try await Task.sleep(for: .milliseconds(150))
            return Tokens(accessToken: "new", refreshToken: "r-new", expiresAt: Date().addingTimeInterval(300))
        }
        let headers = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await provider.authorizationHeader() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(headers == Array(repeating: "Bearer new", count: 8))
        #expect(calls.count == 1)
    }

    /// Forced refreshes after concurrent 401s join one refresh; the file lock alone would let each
    /// caller that has not seen a token yet refresh again.
    @Test func concurrentForcedRefreshesCoalesce() async throws {
        let store = makeStore()
        defer { try? store.delete() }
        try store.save(account(expiringIn: 600))
        let calls = CallCounter()
        let provider = OIDCAuthProvider(store: store, lockURL: lockURL()) { _ in
            calls.bump()
            try await Task.sleep(for: .milliseconds(100))
            return Tokens(accessToken: "new\(calls.count)", refreshToken: "r", expiresAt: Date().addingTimeInterval(300))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { try await provider.refreshAfterUnauthorized() } }
            try await group.waitForAll()
        }
        #expect(calls.count == 1)
    }

    @Test func refreshSurvivesCallerCancellation() async throws {
        let store = makeStore()
        defer { try? store.delete() }
        try store.save(account(expiringIn: 30))
        let calls = CallCounter()
        let provider = OIDCAuthProvider(store: store, lockURL: lockURL()) { _ in
            calls.bump()
            try await Task.sleep(for: .milliseconds(200))
            return Tokens(accessToken: "new", refreshToken: "r-new", expiresAt: Date().addingTimeInterval(300))
        }
        let first = Task { try await provider.authorizationHeader() }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        #expect(try await provider.authorizationHeader() == "Bearer new")
        #expect(calls.count == 1)
        #expect(try store.load()?.tokens.accessToken == "new")
        _ = try? await first.value
    }

    @Test func fileLockExcludesConcurrentBodies() async throws {
        let lock = lockURL()
        let gauge = Gauge()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await FileLock.withLock(at: lock) {
                        gauge.enter()
                        defer { gauge.leave() }
                        try await Task.sleep(for: .milliseconds(30))
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(gauge.peak == 1)
    }

    @Test func appGroupThrowsWithoutInfoPlistKey() {
        #expect(throws: AuthError.self) { try AppGroup.id() }
    }
}
}
