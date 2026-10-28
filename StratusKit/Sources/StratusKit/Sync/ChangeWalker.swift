import Foundation

public struct ChangeSet: Sendable, Equatable {
    public var updated: [RemoteItem]
    public var deleted: [String]

    public init(updated: [RemoteItem] = [], deleted: [String] = []) {
        self.updated = updated
        self.deleted = deleted
    }
}

/// Finds what changed on the server since the cache was last brought up to date (spec "Change
/// detection"). The walk only reads the cache and compares against its state from before the walk;
/// everything found is applied in one transaction at the end. A walk that throws (offline,
/// cancelled) leaves the cache untouched, so the next run still sees the old etags and finds the
/// same changes again.
///
/// An item counts as changed when its etag, name or parent differs (not mtime: the server does
/// not always keep it, and a size change always comes with a new etag). A cached etag's local stamp
/// is kept while the server etag is the same (`ETag.keepingStamp`). The root is an ordinary
/// row: whenever its etag changed it is in `updated` (FP maps it to `.rootContainer`); it is
/// never reported as deleted. A root without a cache row has never been synced and counts as changed.
public struct ChangeWalker: Sendable {
    let cache: ItemCache
    let remote: any RemoteLister
    let rootId: String

    public init(cache: ItemCache, remote: any RemoteLister, rootId: String) {
        self.cache = cache
        self.remote = remote
        self.rootId = rootId
    }

    public func run() async throws -> ChangeSet {
        let root = try await remote.item(rootId)
        guard root.etag != cache.item(rootId)?.etag else { return ChangeSet() }

        var updated: [RemoteItem] = []
        var position: [String: Int] = [:]          // id → index in `updated`; a later version wins
        func update(_ item: RemoteItem) {
            if let i = position[item.id] { updated[i] = item } else {
                position[item.id] = updated.count
                updated.append(item)
            }
        }
        var seen: Set<String> = [rootId]
        var candidates: [String] = []             // cached children missing from their re-listed parent
        update(root)

        var queue = cache.isListed(rootId) ? [rootId] : []
        while !queue.isEmpty {
            try Task.checkCancellation()
            let folderId = queue.removeFirst()
            // Read the cached children BEFORE listing: every cached row then describes a server state
            // older than this listing. Read after, a concurrent enumerator that listed the folder later
            // could have cached a new child this listing lacks, which would be reported deleted.
            let cachedKids = Dictionary(cache.children(of: folderId).map { ($0.id, $0) }) { a, _ in a }
            let (folder, children) = try await remote.children(of: folderId)
            update(folder)
            let remoteIds = Set(children.map(\.id))
            candidates += cachedKids.keys.filter { !remoteIds.contains($0) }.sorted()
            for var child in children {
                seen.insert(child.id)
                let cached = cachedKids[child.id] ?? cache.item(child.id)
                child.etag = ETag.keepingStamp(child.etag, from: cached?.etag)
                guard cached?.etag != child.etag || cached?.name != child.name
                    || cached?.parentId != child.parentId else { continue }
                update(child)
                if child.isFolder, cached?.etag != child.etag, cache.isListed(child.id) {
                    queue.append(child.id)
                }
            }
        }

        // A candidate seen anywhere in the walk was moved; its update already carries the new parent.
        // The others are looked up by id: gone means deleted; moved into a listed folder (during a
        // bulk move, after that folder was listed or without its etag reaching the walk) is an
        // update; moved where the system never looked is a deletion from its point of view.
        var deleted: [String] = []
        for id in candidates where !seen.contains(id) {
            try Task.checkCancellation()
            do {
                var item = try await remote.item(id)
                item.etag = ETag.keepingStamp(item.etag, from: cache.item(id)?.etag)
                if let parent = item.parentId, cache.isListed(parent) { update(item) } else { deleted.append(id) }
            } catch OpenCloudError.notFound {
                deleted.append(id)
            }
        }
        let removed = try cache.apply(updated: updated, deleted: deleted, bumpRevision: true)
        return ChangeSet(updated: updated, deleted: removed)
    }
}
