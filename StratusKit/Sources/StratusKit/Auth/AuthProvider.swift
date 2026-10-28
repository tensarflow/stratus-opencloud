import Foundation

public protocol AuthProvider: Sendable {
    /// `Bearer …` or `Basic …`.
    func authorizationHeader() async throws -> String
    /// Called once after a 401. OIDC forces a token refresh; Basic throws `.unauthorized`.
    func refreshAfterUnauthorized() async throws
}

public struct BasicAuthProvider: AuthProvider {
    private let header: String

    public init(user: String, token: String) {
        header = "Basic " + Data("\(user):\(token)".utf8).base64EncodedString()
    }

    public func authorizationHeader() async throws -> String { header }
    public func refreshAfterUnauthorized() async throws { throw OpenCloudError.unauthorized }
}
