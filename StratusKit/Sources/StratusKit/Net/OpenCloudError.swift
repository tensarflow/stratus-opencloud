import Foundation

public enum OpenCloudError: Error, Equatable {
    case unauthorized
    case forbidden
    case notFound
    case alreadyExists          // 405 on MKCOL; 412 on MOVE with Overwrite: F
    case preconditionFailed     // 412
    case insufficientStorage    // 507
    case tooLarge               // 413
    case server(Int)
    case invalidResponse

    /// Maps an HTTP status to an error; `nil` for statuses below 400.
    public init?(status: Int) {
        switch status {
        case ..<400: return nil
        case 401: self = .unauthorized
        case 403: self = .forbidden
        case 404: self = .notFound
        case 405: self = .alreadyExists
        case 412: self = .preconditionFailed
        case 413: self = .tooLarge
        case 507: self = .insufficientStorage
        default: self = .server(status)
        }
    }
}
