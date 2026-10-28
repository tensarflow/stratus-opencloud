import Foundation

public enum AuthError: Error, Equatable {
    case stateMismatch
    case missingCode
    case signInRequired               // no account, or the refresh token was rejected (`invalid_grant`)
    case authorizationFailed(String)  // `error=` on the loopback callback
    case timedOut
    case missingAppGroup
    case keychain(Int32)
    case insecureEndpoint             // discovery named a non-https endpoint (http is allowed on loopback only)
    case accountMismatch              // "Sign in again" signed in as a different user
}

public struct OIDCConfig: Codable, Sendable, Equatable {
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL

    public init(authorizationEndpoint: URL, tokenEndpoint: URL) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
    }
}

public struct Tokens: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Tokens never reach a log or an error message.
    public var description: String { "Tokens(<redacted>, expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
}

public struct Account: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var serverURL: URL
    public var username: String
    public var clientId: String
    public var tokens: Tokens

    public init(serverURL: URL, username: String, clientId: String, tokens: Tokens) {
        self.serverURL = serverURL
        self.username = username
        self.clientId = clientId
        self.tokens = tokens
    }

    public var description: String { "Account(\(username)@\(serverURL.host() ?? "?"), tokens: <redacted>)" }
    public var debugDescription: String { description }

    /// The same account with the tokens of a new browser sign-in ("Sign in again"). A sign-in as
    /// someone else throws `.accountMismatch`, so the existing account (and its spaces) stay.
    public func reauthenticated(username: String, tokens: Tokens) throws -> Account {
        guard username == self.username else { throw AuthError.accountMismatch }
        var account = self
        account.tokens = tokens
        return account
    }
}

/// Public-client OIDC (authorization code + PKCE) against OpenCloud's built-in IdP.
public struct OIDCClient: Sendable {
    public static let scope = "openid offline_access profile email"

    let serverURL: URL
    let clientId: String
    let session: URLSession

    public init(serverURL: URL, clientId: String = "OpenCloudDesktop", session: URLSession = .shared) {
        self.serverURL = serverURL
        self.clientId = clientId
        self.session = session
    }

    public func discover() async throws -> OIDCConfig {
        let url = serverURL.appending(path: ".well-known/openid-configuration")
        let (data, response) = try await session.data(from: url)
        try Self.check(response)
        let config = try JSONDecoder().decode(OIDCConfig.self, from: data)
        guard Self.isSecure(config.authorizationEndpoint), Self.isSecure(config.tokenEndpoint) else {
            throw AuthError.insecureEndpoint
        }
        return config
    }

    /// https, or plain http to a loopback host (a local test server).
    static func isSecure(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": ["127.0.0.1", "localhost", "::1"].contains(url.host(percentEncoded: false)?.lowercased() ?? "")
        default: false
        }
    }

    public func authorizeURL(config: OIDCConfig, redirectURI: URL, pkce: PKCE, state: String) -> URL {
        let query = Self.encode([
            ("response_type", "code"), ("client_id", clientId), ("redirect_uri", redirectURI.absoluteString),
            ("scope", Self.scope), ("state", state),
            ("code_challenge", pkce.challenge), ("code_challenge_method", "S256"),
        ])
        var comps = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        comps.percentEncodedQuery = query
        return comps.url!
    }

    public func exchange(code: String, redirectURI: URL, pkce: PKCE, config: OIDCConfig) async throws -> Tokens {
        try await tokenRequest(config: config, fallbackRefreshToken: nil, [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI.absoluteString),
            ("client_id", clientId), ("code_verifier", pkce.verifier),
        ])
    }

    /// Keeps `refreshToken` when the server rotates nothing.
    public func refresh(_ refreshToken: String, config: OIDCConfig) async throws -> Tokens {
        try await tokenRequest(config: config, fallbackRefreshToken: refreshToken, [
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientId),
        ])
    }

    // MARK: -

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
    }

    private struct ErrorResponse: Decodable { var error: String }

    private func tokenRequest(config: OIDCConfig, fallbackRefreshToken: String?,
                              _ fields: [(String, String)]) async throws -> Tokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.encode(fields).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data), err.error == "invalid_grant" {
                throw AuthError.signInRequired
            }
            throw OpenCloudError(status: status) ?? .invalidResponse
        }
        let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refresh = parsed.refresh_token ?? fallbackRefreshToken else { throw OpenCloudError.invalidResponse }
        return Tokens(accessToken: parsed.access_token, refreshToken: refresh,
                      expiresAt: Date().addingTimeInterval(parsed.expires_in ?? 300))
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = OpenCloudError(status: status) { throw error }
        if status == 0 { throw OpenCloudError.invalidResponse }
    }

    /// `application/x-www-form-urlencoded` / query encoding: everything but unreserved is percent-encoded.
    private static func encode(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return fields.map { "\(esc($0.0))=\(esc($0.1))" }.joined(separator: "&")
    }
}
