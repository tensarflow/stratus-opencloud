import FileProvider
import os
import StratusKit
import UniformTypeIdentifiers

let log = Logger(subsystem: "com.arteq.stratus", category: "extension")

/// Everything one domain (space) needs, built on first use: the client, the item cache and the
/// space root's id. A failed build (no account yet, offline) is retried on the next call.
actor DomainSession {
    struct Context: Sendable {
        let client: OpenCloudClient
        let cache: ItemCache
        let rootId: String
        let generation: Int
    }

    let driveId: String
    private var pending: Task<Context, Error>?

    init(driveId: String) { self.driveId = driveId }

    func context() async throws -> Context {
        let task = pending ?? Task { [driveId] in try await Self.build(driveId) }
        pending = task
        do {
            return try await task.value
        } catch {
            if pending == task { pending = nil }
            throw error
        }
    }

    private static func build(_ driveId: String) async throws -> Context {
        let store = AccountStore(accessGroup: try AppGroup.keychainGroup())
        guard let account = try store.load() else { throw NSFileProviderError(.notAuthenticated) }
        let auth = OIDCAuthProvider(store: store, lockURL: try AppGroup.authLockURL(),
                                    refresher: OIDCAuthProvider.oidcRefresher())
        let client = OpenCloudClient(baseURL: account.serverURL, auth: auth)
        let cache = try ItemCache(url: AppGroup.cacheURL(driveId: driveId))
        let rootId: String
        if let stored = cache.meta("rootId") {
            rootId = stored
        } else {
            rootId = try await client.item(driveId).id
            cache.setMeta("rootId", rootId)
        }
        // A new cache gets a new generation, so anchors handed out for an older cache expire.
        let generation: Int
        if let stored = cache.meta("generation").flatMap(Int.init) {
            generation = stored
        } else {
            generation = Int.random(in: 1...Int(Int32.max))
            cache.setMeta("generation", String(generation))
        }
        return Context(client: client, cache: cache, rootId: rootId, generation: generation)
    }
}

/// Lets a non-Sendable system object (observer, completion handler) cross into a `Task`. Each one
/// is used by a single task only.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Errors as the system wants them: cancellations as user-cancelled, name clashes as collisions,
/// the rest through `FPErrors`.
func fpError(_ error: Error) -> Error {
    switch error {
    case is CancellationError: return CocoaError(.userCancelled)
    case let e as URLError where e.code == .cancelled: return CocoaError(.userCancelled)
    case OpenCloudError.alreadyExists: return NSFileProviderError(.filenameCollision)
    default: return FPErrors.map(error)
    }
}

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    private let domain: NSFileProviderDomain
    private let session: DomainSession

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.session = DomainSession(driveId: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() {}

    /// Runs `work` in a task that the returned progress can cancel; `done` gets the outcome once.
    private func run<T: Sendable>(_ op: StaticString, progress: Progress = Progress(totalUnitCount: 1),
                                  _ work: @escaping @Sendable (DomainSession.Context, Progress) async throws -> T,
                                  done: @escaping @Sendable (Result<T, Error>) -> Void) -> Progress {
        let session = session, box = Unchecked(progress)
        let task = Task {
            do {
                let result = try await work(try await session.context(), box.value)
                done(.success(result))
            } catch {
                log.error("\(op, privacy: .public) failed: \(ErrorLog.code(error), privacy: .public) \(String(describing: error), privacy: .private)")
                done(.failure(fpError(error)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private static func remoteId(_ identifier: NSFileProviderItemIdentifier, _ ctx: DomainSession.Context) throws -> String {
        guard identifier != .trashContainer, identifier != .workingSet else { throw NSFileProviderError(.noSuchItem) }
        return FPMapping.remoteId(for: identifier, rootId: ctx.rootId)
    }

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let completion = Unchecked(completionHandler)
        return run("item") { ctx, _ in
            let id = try Self.remoteId(identifier, ctx)
            if let cached = ctx.cache.item(id) { return (cached, ctx.rootId) }
            let item = try await ctx.client.item(id)
            ctx.cache.upsert([item])
            return (item, ctx.rootId)
        } done: { result in
            switch result {
            case .success(let (item, rootId)): completion.value(FPItem(item, rootId: rootId), nil)
            case .failure(let error): completion.value(nil, error)
            }
        }
    }

    func fetchContents(for identifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let completion = Unchecked(completionHandler), domain = Unchecked(domain)
        return run("fetchContents", progress: Progress(totalUnitCount: 100)) { ctx, progress in
            let id = try Self.remoteId(identifier, ctx)
            let cached = ctx.cache.item(id)
            if let size = cached?.size, size > 0 { progress.totalUnitCount = size }
            guard let manager = NSFileProviderManager(for: domain.value) else { throw NSFileProviderError(.providerNotFound) }
            let dest = try manager.temporaryDirectoryURL().appending(path: UUID().uuidString)
            let etag = try await ctx.client.download(id, to: dest, progress: progress)
            var item: RemoteItem
            do {
                item = if let cached { cached } else { try await ctx.client.item(id) }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
            if !etag.isEmpty { item.etag = ETag.keepingStamp(etag, from: item.etag) }
            if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber {
                item.size = size.int64Value
            }
            log.debug("fetched \(item.name)")
            return (dest, item, ctx.rootId)
        } done: { result in
            switch result {
            case .success(let (url, item, rootId)): completion.value(url, FPItem(item, rootId: rootId), nil)
            case .failure(let error): completion.value(nil, nil, error)
            }
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void)
        -> Progress {
        let completion = Unchecked(completionHandler), template = Unchecked(itemTemplate), domain = Unchecked(domain)
        return run("createItem", progress: Progress(totalUnitCount: 100)) { ctx, progress in
            let name = template.value.filename
            let type = template.value.contentType ?? .data
            if SyncRules.isExcluded(name) || type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) {
                throw NSFileProviderError(.excludedFromSync)
            }
            let parentId = try Self.remoteId(template.value.parentItemIdentifier, ctx)
            log.debug("create \(name)")
            // Packages (.rtfd, .app, bundles) are directories but not `.folder`.
            if type.conforms(to: .directory) {
                let (item, signal) = try await Self.createFolder(ctx, parentId: parentId, name: name)
                return (item, ctx.rootId, signal)
            }
            var empty: URL?
            if url == nil { empty = try Self.emptyFile(domain.value) }
            defer { if let empty { try? FileManager.default.removeItem(at: empty) } }
            guard let file = url ?? empty else { throw NSFileProviderError(.noSuchItem) }
            let modified = template.value.contentModificationDate ?? nil
            // The name taken on the server meanwhile: keep both, ours as a conflict copy. The folder
            // gone on the server: the file goes to the space root (the system re-parents the local
            // item), never `.noSuchItem` while the bytes are on no server. The result is what the system
            // gets back (so it is cached); anything else on the server is left for the walker to report.
            let (item, signal) = try await ConflictKeeper.create(name: name, parentId: parentId, rootId: ctx.rootId) {
                try await ctx.client.upload(file, parentId: $0, name: $1, replacing: nil, modified: modified,
                                            progress: progress)
            }
            if signal, item.parentId == ctx.rootId, parentId != ctx.rootId { log.info("create: folder gone, kept the file in the space root") }
            _ = try ctx.cache.apply(updated: [item], deleted: [])
            return (item, ctx.rootId, signal)
        } done: { result in
            switch result {
            case .success(let (item, rootId, signal)):
                completion.value(FPItem(item, rootId: rootId), [], false, nil)
                if signal { Self.signalLater(domain.value) }
            case .failure(let error): completion.value(nil, [], false, error)
            }
        }
    }

    /// MKCOL; the new folder is known to be empty, so it is marked listed and the walker follows
    /// it from now on. A folder that already exists by that name is adopted (merge): it is cached
    /// with an empty etag and marked listed, so the next walk lists it and reports what the server
    /// already holds in it. A file in the way makes the folder a conflict copy. Returns whether the
    /// working set needs a signal (for the adopted contents or the file in the way).
    private static func createFolder(_ ctx: DomainSession.Context, parentId: String,
                                     name: String) async throws -> (RemoteItem, Bool) {
        do {
            return try await createFolderIn(ctx, parentId: parentId, name: name)
        } catch where ConflictKeeper.isParentGone(error) {
            // The parent is gone on the server: the folder goes to the space root (the system
            // re-parents the local one and its children). A name taken there makes a conflict copy.
            // Adoption (above) applies to the original parent only.
            let placed = try await ConflictKeeper.createInRoot(
                name: name, rootId: ctx.rootId, isNameTaken: { ($0 as? OpenCloudError) == .alreadyExists }
            ) { try await ctx.client.createFolder(in: $0, name: $1) }
            _ = try ctx.cache.apply(updated: [placed.item], deleted: [])
            ctx.cache.setListed(placed.item.id)
            log.info("create: folder's parent gone, created it in the space root")
            return (placed.item, true)
        }
    }

    private static func createFolderIn(_ ctx: DomainSession.Context, parentId: String,
                                       name: String) async throws -> (RemoteItem, Bool) {
        let created: RemoteItem
        do {
            created = try await ctx.client.createFolder(in: parentId, name: name)
        } catch OpenCloudError.alreadyExists {
            let wanted = name.precomposedStringWithCanonicalMapping
            let existing = try await ctx.client.children(of: parentId).children.first {
                $0.name.precomposedStringWithCanonicalMapping == wanted
            }
            if let existing, existing.isFolder {
                var stale = existing
                stale.etag = ""
                _ = try ctx.cache.apply(updated: [stale], deleted: [])
                ctx.cache.setListed(existing.id)
                return (existing, true)
            }
            let copy = try await ctx.client.createFolder(in: parentId, name: SyncRules.conflictName(for: name, date: Date()))
            _ = try ctx.cache.apply(updated: [copy], deleted: [])
            ctx.cache.setListed(copy.id)
            return (copy, true)
        }
        _ = try ctx.cache.apply(updated: [created], deleted: [])
        ctx.cache.setListed(created.id)
        return (created, false)
    }

    private static func emptyFile(_ domain: NSFileProviderDomain) throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
        let url = try manager.temporaryDirectoryURL().appending(path: UUID().uuidString)
        try Data().write(to: url)
        return url
    }

    /// Asks the system to enumerate the working set, for server changes the extension made but did
    /// not hand back (a conflict copy, an adopted folder's contents). Called after the cache holds
    /// what the operation returned, so the walk does not report that item as new.
    private static func signalWorkingSet(_ domain: NSFileProviderDomain) async {
        do {
            try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
        } catch {
            log.error("signal working set failed: \(ErrorLog.code(error), privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    /// `signalWorkingSet` once the completion handler has run.
    private static func signalLater(_ domain: NSFileProviderDomain) {
        let domain = Unchecked(domain)
        Task { await signalWorkingSet(domain.value) }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void)
        -> Progress {
        let completion = Unchecked(completionHandler), template = Unchecked(item), domain = Unchecked(domain)
        let baseEtag = String(decoding: version.contentVersion, as: UTF8.self)
        return run("modifyItem", progress: Progress(totalUnitCount: 100)) { ctx, progress in
            let id = try Self.remoteId(template.value.itemIdentifier, ctx)
            let name = template.value.filename
            let parentId = try Self.remoteId(template.value.parentItemIdentifier, ctx)
            let file = changedFields.contains(.contents) ? newContents : nil
            let modified = template.value.contentModificationDate ?? nil
            log.debug("modify \(name)")
            var current = ctx.cache.item(id)

            /// The local bytes go next to the item as a conflict copy (in the space root if that folder
            /// is gone too; a retryable error if neither worked). The copy stays out of the cache: the
            /// system has not been told about it, so the walker must find it as new and report it.
            func keepCopy(_ file: URL) async throws {
                let copy = try await ConflictKeeper.keep(name: name, parentId: parentId, rootId: ctx.rootId) {
                    try await ctx.client.upload(file, parentId: $0, name: $1, replacing: nil,
                                                modified: modified, progress: progress)
                }
                log.info("conflict: kept local edit as a copy\(copy.parentId == ctx.rootId && parentId != ctx.rootId ? " in the space root" : "", privacy: .public)")
            }
            /// The item is gone on the server: an edit is kept as a copy (unless it already is) before
            /// the system hears so. `.noSuchItem` (the system then deletes the local item) is thrown only
            /// once the copy is saved.
            func gone(copied: Bool = false) async throws -> Never {
                if let file, !copied { try await keepCopy(file) }
                await Self.signalWorkingSet(domain.value)
                throw NSFileProviderError(.noSuchItem)
            }
            /// After a conflict (the copy exists by now) the item is refreshed to the server version, to
            /// be fetched again.
            func conflict() async throws -> (RemoteItem, Bool, String, Bool) {
                let server: RemoteItem
                do { server = try await ctx.client.item(id) } catch OpenCloudError.notFound { try await gone(copied: true) }
                _ = try ctx.cache.apply(updated: [server], deleted: [])
                return (server, true, ctx.rootId, true)
            }

            // A retry after "moved, then the upload failed" finds the item already in place; moving
            // it onto its own path would fail with a collision forever.
            let inPlace = current.map {
                $0.parentId == parentId
                    && $0.name.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping
            } ?? false
            if !changedFields.isDisjoint(with: [.filename, .parentItemIdentifier]), !inPlace {
                var moved: RemoteItem
                do { moved = try await ctx.client.move(id, toParent: parentId, name: name) } catch OpenCloudError.notFound {
                    try await gone()
                }
                moved.etag = ETag.keepingStamp(moved.etag, from: current?.etag)
                _ = try ctx.cache.apply(updated: [moved], deleted: [])
                current = moved
            }

            if let file {
                // If-Match uses the version the local edit is based on, so a server change the
                // system has not fetched yet still comes back as 412 instead of being overwritten.
                // (A stored etag may carry a local stamp; the server only ever sees the etag itself.)
                let etag = ETag.normalize(baseEtag.isEmpty ? (current?.etag ?? "") : baseEtag)
                let uploaded: RemoteItem, confirmed: Bool
                do {
                    (uploaded, confirmed) = try await ctx.client.uploadConfirming(
                        file, parentId: parentId, name: name, replacing: (id, etag), modified: modified,
                        progress: progress)
                } catch OpenCloudError.preconditionFailed {
                    try await keepCopy(file)
                    return try await conflict()
                } catch OpenCloudError.notFound {
                    try await gone()
                }
                switch SyncRules.replaceOutcome(id: id, baseEtag: etag, uploaded: uploaded, confirmed: confirmed) {
                case .replaced:
                    let replaced = SyncRules.replacedItem(uploaded, baseEtag: etag)
                    _ = try ctx.cache.apply(updated: [replaced], deleted: [])
                    return (replaced, false, ctx.rootId, false)
                case .newItem:
                    // The bytes became another file in the item's place (the original was moved or
                    // replaced on the server). That file is the conflict copy: give it the copy's name.
                    _ = try await ctx.client.move(uploaded.id, toParent: uploaded.parentId ?? parentId,
                                                  name: SyncRules.conflictName(for: name, date: Date()))
                    log.info("conflict: upload landed on a new item, kept it as a copy")
                    return try await conflict()
                case .unconfirmed:
                    // The item still has the base version, so where the bytes went is unknown: upload
                    // them once more as a copy rather than trust a stray file.
                    try await keepCopy(file)
                    return try await conflict()
                }
            }

            let result = if let current { current } else { try await ctx.client.item(id) }
            return (result, false, ctx.rootId, false)
        } done: { result in
            switch result {
            case .success(let (item, fetch, rootId, signal)):
                completion.value(FPItem(item, rootId: rootId), [], fetch, nil)
                if signal { Self.signalLater(domain.value) }
            case .failure(let error): completion.value(nil, [], false, error)
            }
        }
    }

    /// Files are deleted only if the server still has the version the system based the delete on;
    /// otherwise the deletion is rejected and the system fetches the newer version. Folders are not
    /// checked: the server moves them to its trash, which can be restored.
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let completion = Unchecked(completionHandler)
        let base = version.contentVersion
        return run("deleteItem") { ctx, _ in
            let id = try Self.remoteId(identifier, ctx)
            do {
                let current = try await ctx.client.item(id)
                if current.isFolder {
                    if !options.contains(.recursive), try await !ctx.client.children(of: id).children.isEmpty {
                        throw NSFileProviderError(.directoryNotEmpty)
                    }
                } else if ETag.isStale(base: base, current: current.etag) {
                    _ = try ctx.cache.apply(updated: [current], deleted: [])
                    throw NSError.fileProviderErrorForRejectedDeletion(of: FPItem(current, rootId: ctx.rootId))
                }
                try await ctx.client.delete(id)
            } catch OpenCloudError.notFound {
                // Already gone on the server: the delete succeeded as far as the system cares.
            }
            _ = try ctx.cache.apply(updated: [], deleted: [id])
        } done: { result in
            switch result {
            case .success: completion.value(nil)
            case .failure(let error): completion.value(error)
            }
        }
    }

    // MARK: Thumbnails

    /// Server previews, so Finder's gallery and preview column never download a dataless file. No
    /// preview (folders, types the server cannot render) is not an error: nil data, nil error. Real
    /// failures (network, auth) go to that item only; cancelling answers every open item and the
    /// batch with "user cancelled".
    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        let perItem = Unchecked(perThumbnailCompletionHandler), completion = Unchecked(completionHandler)
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count)), box = Unchecked(progress)
        let session = session, px = Thumbnails.pixelSize(size), lock = NSLock()
        let task = Task {
            let ctx: DomainSession.Context
            do { ctx = try await session.context() } catch {
                completion.value(fpError(error))
                return
            }
            await Thumbnails.forEach(itemIdentifiers, limit: 4) { identifier in
                defer { lock.withLock { box.value.completedUnitCount += 1 } }
                let id = FPMapping.remoteId(for: identifier, rootId: ctx.rootId)
                if identifier == .rootContainer || identifier == .trashContainer || identifier == .workingSet
                    || ctx.cache.item(id)?.isFolder == true {
                    perItem.value(identifier, nil, nil)
                    return
                }
                do {
                    try Task.checkCancellation()
                    perItem.value(identifier, try await ctx.client.thumbnail(id, width: px.width, height: px.height), nil)
                } catch {
                    perItem.value(identifier, nil, fpError(error))
                }
            }
            completion.value(Task.isCancelled ? CocoaError(.userCancelled) : nil)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .workingSet: WorkingSetEnumerator(session: session)
        case .trashContainer: EmptyEnumerator()
        default: FolderEnumerator(container: containerItemIdentifier, session: session)
        }
    }
}
