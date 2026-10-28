import FileProvider
import Foundation

/// Maps client errors to the `NSFileProviderError`s the system knows how to handle. Unreachable
/// servers become `.serverUnreachable` so the system retries later. Everything else (including
/// `CancellationError`) passes through unchanged.
public enum FPErrors {
    public static func map(_ error: Error) -> Error {
        switch error {
        case OpenCloudError.notFound:
            return NSFileProviderError(.noSuchItem)
        case OpenCloudError.unauthorized, AuthError.signInRequired:
            return NSFileProviderError(.notAuthenticated)
        case OpenCloudError.insufficientStorage:
            return NSFileProviderError(.insufficientQuota)
        case OpenCloudError.server(500...599):
            return NSFileProviderError(.serverUnreachable)
        case let urlError as URLError where [
            .notConnectedToInternet, .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost,
        ].contains(urlError.code):
            return NSFileProviderError(.serverUnreachable)
        default:
            return error
        }
    }

    /// The user switched the domain off (or never switched it on): File Provider error -2011.
    public static func isDomainDisabled(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSFileProviderErrorDomain && ns.code == NSFileProviderError.Code.domainDisabled.rawValue
    }
}
