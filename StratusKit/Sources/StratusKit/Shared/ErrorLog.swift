import Foundation

/// Log-safe error summaries. Descriptions can carry URLs, file names or server messages, so logs
/// print this code publicly and the description only with `privacy: .private`.
public enum ErrorLog {
    /// `<domain> <code>`, e.g. `NSURLErrorDomain -1001` or `StratusKit.OpenCloudError 2`.
    public static func code(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
