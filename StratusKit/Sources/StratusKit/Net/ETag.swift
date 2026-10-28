import Foundation

/// One spelling for every ETag the app stores or compares: no weak prefix, no quotes.
/// A proxy may turn `"abc"` into `W/"abc"`; both must compare equal, and `If-Match` re-adds quotes.
///
/// A stored etag may carry a local content stamp after a separator (see `SyncRules.replacedItem`).
/// `normalize` drops it, so it never reaches the server or a comparison with a server etag.
public enum ETag {
    /// A control character: never part of an HTTP header value, so never of a real etag.
    static let stampSeparator: Character = "\u{1F}"

    public static func normalize(_ raw: String) -> String {
        var s = Substring(raw)
        if let stamp = s.firstIndex(of: stampSeparator) { s = s[..<stamp] }
        s = Substring(s.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("W/") { s = s.dropFirst(2) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// `etag` (normalized) with a local stamp, for a content version the server etag alone does not tell apart.
    public static func stamped(_ etag: String, _ stamp: String) -> String {
        normalize(etag) + String(stampSeparator) + stamp
    }

    /// A fresh server etag, or the `cached` one with its stamp while the server etag is still the same.
    public static func keepingStamp(_ fresh: String, from cached: String?) -> String {
        guard let cached, normalize(cached) == normalize(fresh) else { return fresh }
        return cached
    }
}

extension ETag {
    /// Whether the server's `current` etag differs from the version the system based an operation on
    /// (`NSFileProviderItemVersion.contentVersion`, the etag's UTF-8 bytes). An empty base is unknown,
    /// so it never counts as stale.
    public static func isStale(base: Data, current: String) -> Bool {
        let base = normalize(String(decoding: base, as: UTF8.self))
        return !base.isEmpty && base != normalize(current)
    }
}
