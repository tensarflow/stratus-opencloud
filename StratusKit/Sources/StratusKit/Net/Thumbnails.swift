import CoreGraphics
import Foundation

/// Server-rendered previews, so Finder can show thumbnails without downloading the file.
public enum Thumbnails {
    public struct Size: Sendable, Equatable {
        public var width: Int, height: Int
    }

    /// The system asks in pixels; each side is rounded and kept within 16…1024.
    public static func pixelSize(_ size: CGSize) -> Size {
        func side(_ v: CGFloat) -> Int { v.isNaN ? 16 : Int(min(max(v.rounded(), 16), 1024)) }
        return Size(width: side(size.width), height: side(size.height))
    }

    /// Runs `work` once for every element, at most `limit` at a time. Cancellation is left to `work`
    /// (it still runs for every element, so each one gets an answer).
    public static func forEach<T: Sendable>(_ items: [T], limit: Int,
                                            _ work: @escaping @Sendable (T) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var next = items.makeIterator()
            for _ in 0..<max(1, limit) {
                guard let item = next.next() else { break }
                group.addTask { await work(item) }
            }
            while await group.next() != nil {
                if let item = next.next() { group.addTask { await work(item) } }
            }
        }
    }
}

extension OpenCloudClient {
    /// A preview image (JPEG) of at most `width`×`height`, aspect kept; `nil` when the server cannot
    /// preview this type (404, 415, 501). Never touches the file's contents on disk.
    public func thumbnail(_ id: String, width: Int, height: Int) async throws -> Data? {
        let item = DAVPaths.item(id, base: baseURL).absoluteString
        guard let url = URL(string: item + "?preview=1&x=\(width)&y=\(height)&a=1") else {
            throw OpenCloudError.invalidResponse
        }
        do {
            return try await send(request("GET", url)).0
        } catch OpenCloudError.notFound, OpenCloudError.server(415), OpenCloudError.server(501) {
            return nil
        }
    }
}
