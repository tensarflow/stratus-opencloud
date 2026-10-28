import FileProvider
import StratusKit

/// Cache model: the item cache holds what the system has been told. Remote changes enter it only
/// through the `ChangeWalker` (working set), which diffs the server against it and reports what it
/// applies. Listing a folder only adds rows the cache does not have yet, and the extension's own
/// writes upsert what the server returned, so neither hides a change from the walker.

let pageSize = 500

/// Runs enumeration work in tasks that `invalidate()` cancels.
class TaskEnumerator: NSObject, @unchecked Sendable {
    let session: DomainSession
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(session: DomainSession) { self.session = session }

    func spawn(_ work: @escaping @Sendable (DomainSession.Context) async throws -> Void,
               failed: @escaping @Sendable (Error) -> Void) {
        let key = UUID(), session = session
        let task = Task { [weak self] in
            do {
                try await work(try await session.context())
            } catch {
                log.error("enumeration failed: \(ErrorLog.code(error), privacy: .public) \(String(describing: error), privacy: .private)")
                failed(fpError(error))
            }
            self?.lock.withLock { _ = self?.tasks.removeValue(forKey: key) }
        }
        lock.withLock { tasks[key] = task }
    }

    @objc func invalidate() {
        lock.withLock { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
    }

    static func offset(_ page: NSFileProviderPage) -> Int {
        if page == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage
            || page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage { return 0 }
        return Int(String(decoding: page.rawValue, as: UTF8.self)) ?? 0
    }

    /// Hands out `items[offset...]` in one page and the page after it, or `nil` at the end.
    static func deliver(_ items: [RemoteItem], from offset: Int, rootId: String,
                        to observer: NSFileProviderEnumerationObserver) {
        let slice = items.dropFirst(offset).prefix(pageSize)
        observer.didEnumerate(slice.map { FPItem($0, rootId: rootId) })
        let next = offset + slice.count
        observer.finishEnumerating(upTo: next < items.count ? NSFileProviderPage(Data(String(next).utf8)) : nil)
    }
}

final class FolderEnumerator: TaskEnumerator, NSFileProviderEnumerator, @unchecked Sendable {
    let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier, session: DomainSession) {
        self.container = container
        super.init(session: session)
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Unchecked(observer), container = container, offset = Self.offset(page)
        spawn { ctx in
            let id = FPMapping.remoteId(for: container, rootId: ctx.rootId)
            if offset == 0 {
                let (folder, children) = try await ctx.client.children(of: id)
                let unknown = ([folder] + children).filter { ctx.cache.item($0.id) == nil }
                _ = try ctx.cache.apply(updated: unknown, deleted: [])
                ctx.cache.setListed(id)
            }
            Self.deliver(ctx.cache.children(of: id), from: offset, rootId: ctx.rootId, to: observer.value)
        } failed: { observer.value.finishEnumeratingWithError($0) }
    }

    /// Re-lists the folder and reports how it differs from the cache. A child gone from the listing
    /// is looked up by id: still there means it moved (an update), 404 means deleted. The cache
    /// itself is left to the working set.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let observer = Unchecked(observer), container = container
        spawn { ctx in
            let id = FPMapping.remoteId(for: container, rootId: ctx.rootId)
            let (folder, children) = try await ctx.client.children(of: id)
            let diff = FolderDiff.compare(cached: ctx.cache.children(of: id), fresh: children)
            var updated = diff.changed
            var deleted: [NSFileProviderItemIdentifier] = []
            for missingId in diff.missing {
                do {
                    updated.append(try await ctx.client.item(missingId))
                } catch OpenCloudError.notFound {
                    deleted.append(FPMapping.identifier(for: missingId, rootId: ctx.rootId))
                }
            }
            if !deleted.isEmpty { observer.value.didDeleteItems(withIdentifiers: deleted) }
            if !updated.isEmpty { observer.value.didUpdate(updated.map { FPItem($0, rootId: ctx.rootId) }) }
            observer.value.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data(folder.etag.utf8)),
                                                    moreComing: false)
        } failed: { observer.value.finishEnumeratingWithError($0) }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let completion = Unchecked(completionHandler), container = container
        spawn { ctx in
            let id = FPMapping.remoteId(for: container, rootId: ctx.rootId)
            let etag = if let row = ctx.cache.item(id) { row.etag } else { try await ctx.client.item(id).etag }
            completion.value(NSFileProviderSyncAnchor(Data(etag.utf8)))
        } failed: { _ in completion.value(nil) }
    }
}

final class WorkingSetEnumerator: TaskEnumerator, NSFileProviderEnumerator, @unchecked Sendable {
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Unchecked(observer), offset = Self.offset(page)
        spawn { ctx in
            Self.deliver(ctx.cache.allItems(), from: offset, rootId: ctx.rootId, to: observer.value)
        } failed: { observer.value.finishEnumeratingWithError($0) }
    }

    /// An anchor the cache has moved past (a walk whose result never reached the system) expires,
    /// so the system re-enumerates instead of missing those changes for good.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let observer = Unchecked(observer)
        spawn { ctx in
            guard let old = SyncAnchor(data: anchor.rawValue),
                  old.isCurrent(generation: ctx.generation, revision: ctx.cache.revision) else {
                throw NSFileProviderError(.syncAnchorExpired)
            }
            let changes = try await ChangeWalker(cache: ctx.cache, remote: ctx.client, rootId: ctx.rootId).run()
            if !changes.deleted.isEmpty {
                observer.value.didDeleteItems(withIdentifiers: changes.deleted.map {
                    FPMapping.identifier(for: $0, rootId: ctx.rootId)
                })
            }
            for start in stride(from: 0, to: changes.updated.count, by: pageSize) {
                let batch = changes.updated[start..<min(start + pageSize, changes.updated.count)]
                observer.value.didUpdate(batch.map { FPItem($0, rootId: ctx.rootId) })
            }
            observer.value.finishEnumeratingChanges(upTo: Self.anchor(ctx), moreComing: false)
        } failed: { observer.value.finishEnumeratingWithError($0) }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let completion = Unchecked(completionHandler)
        spawn { ctx in
            completion.value(Self.anchor(ctx))
        } failed: { _ in completion.value(nil) }
    }

    private static func anchor(_ ctx: DomainSession.Context) -> NSFileProviderSyncAnchor {
        let anchor = SyncAnchor(generation: ctx.generation, revision: ctx.cache.revision,
                                rootEtag: ctx.cache.item(ctx.rootId)?.etag ?? "")
        return NSFileProviderSyncAnchor(anchor.data)
    }
}

/// The trash is not exposed: always empty, never changes.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }
}
