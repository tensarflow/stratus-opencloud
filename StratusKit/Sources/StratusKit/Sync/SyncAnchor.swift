import Foundation

/// The working-set sync anchor, serialized as JSON. Anything that does not decode is unknown and
/// makes the caller throw `.syncAnchorExpired`.
///
/// `generation` names the cache file, `revision` the cache's walk revision (`ItemCache.revision`)
/// when the anchor was handed out. A walk that applied changes the system never acknowledged (the
/// extension died before `finishEnumeratingChanges`) leaves the cache ahead of the anchor; the next
/// walk would find nothing, so such an anchor is stale and the system must re-enumerate.
public struct SyncAnchor: Codable, Sendable, Equatable {
    public var generation: Int
    public var revision: Int
    public var rootEtag: String

    public init(generation: Int, revision: Int, rootEtag: String) {
        self.generation = generation
        self.revision = revision
        self.rootEtag = rootEtag
    }

    /// Whether the system was told everything the cache holds as of this anchor.
    public func isCurrent(generation: Int, revision: Int) -> Bool {
        self.generation == generation && self.revision == revision
    }

    public init?(data: Data) {
        guard let anchor = try? JSONDecoder().decode(SyncAnchor.self, from: data) else { return nil }
        self = anchor
    }

    public var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }
}
