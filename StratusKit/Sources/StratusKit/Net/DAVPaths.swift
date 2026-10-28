import Foundation

/// WebDAV URLs addressed by resource id: `<base>/dav/spaces/<id>[/<name>]`.
public enum DAVPaths {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let idAllowed = unreserved.union(CharacterSet(charactersIn: "$!"))

    public static func item(_ id: String, base: URL) -> URL {
        url(base: base, path: encode(id, allowed: idAllowed))
    }

    public static func child(_ parentId: String, name: String, base: URL) -> URL {
        url(base: base, path: encode(parentId, allowed: idAllowed) + "/" + encode(name, allowed: unreserved))
    }

    /// An id as one URL path segment (`$` and `!` stay readable).
    static func escapedId(_ id: String) -> String { encode(id, allowed: idAllowed) }

    private static func encode(_ s: String, allowed: CharacterSet) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func url(base: URL, path: String) -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: root + "/dav/spaces/" + path)!
    }
}
