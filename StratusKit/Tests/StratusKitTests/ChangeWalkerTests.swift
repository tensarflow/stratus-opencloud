import Foundation
import Testing
@testable import StratusKit

/// In-memory server tree. Like OpenCloud, every change gives all ancestor folders a new etag.
/// A rename or move keeps the item's own etag; only content edits change it.
final class FakeRemote: RemoteLister, @unchecked Sendable {
    let rootId = "root"
    private let lock = NSLock()
    private var items: [String: RemoteItem] = [:]
    private var counter = 0
    private var childrenCallsUntilFailure: Int?
    private var afterChildren: (@Sendable (String) -> Void)?
    private var failingItems: Set<String> = []

    init() {
        items[rootId] = RemoteItem(id: rootId, name: "Personal", isFolder: true, etag: "r0")
    }

    func item(_ id: String) throws -> RemoteItem {
        try lock.withLock {
            if failingItems.contains(id) { throw URLError(.timedOut) }
            guard let item = items[id] else { throw OpenCloudError.notFound }
            return item
        }
    }

    func children(of id: String) throws -> (folder: RemoteItem, children: [RemoteItem]) {
        let result = try listing(of: id)
        lock.withLock { afterChildren }?(id)
        return result
    }

    /// Runs after each `children(of:)` has built its answer (outside the lock), e.g. to simulate
    /// a concurrent enumerator writing to the cache.
    func afterChildren(_ hook: (@Sendable (String) -> Void)?) { lock.withLock { afterChildren = hook } }

    private func listing(of id: String) throws -> (folder: RemoteItem, children: [RemoteItem]) {
        try lock.withLock {
            if let left = childrenCallsUntilFailure {
                childrenCallsUntilFailure = left - 1
                if left == 1 { throw URLError(.networkConnectionLost) }
            }
            guard let folder = items[id], folder.isFolder else { throw OpenCloudError.notFound }
            let kids = items.values.filter { $0.parentId == id }.sorted { $0.name < $1.name }
            return (folder, kids)
        }
    }

    /// `item(id)` throws a network error for these ids.
    func failItem(_ ids: Set<String>) { lock.withLock { failingItems = ids } }

    /// The `n`-th `children(of:)` call from now throws; `nil` disables.
    func failChildren(onCall n: Int?) { lock.withLock { childrenCallsUntilFailure = n } }

    func add(_ id: String, in parent: String, folder: Bool = false) {
        lock.withLock {
            items[id] = RemoteItem(id: id, parentId: parent, name: id, isFolder: folder, etag: nextEtag())
            bumpAncestors(of: id)
        }
    }

    func edit(_ id: String) {
        lock.withLock {
            items[id]?.etag = nextEtag()
            items[id]?.size += 1
            bumpAncestors(of: id)
        }
    }

    func rename(_ id: String, to name: String) {
        lock.withLock {
            items[id]?.name = name
            bumpAncestors(of: id)
        }
    }

    func move(_ id: String, to parent: String) {
        lock.withLock {
            bumpAncestors(of: id)
            items[id]?.parentId = parent
            bumpAncestors(of: id)
        }
    }

    func delete(_ id: String) {
        lock.withLock {
            bumpAncestors(of: id)
            var doomed = [id]
            while let next = doomed.popLast() {
                items[next] = nil
                doomed += items.values.filter { $0.parentId == next }.map(\.id)
            }
        }
    }

    private func nextEtag() -> String {
        counter += 1
        return "e\(counter)"
    }

    private func bumpAncestors(of id: String) {
        var parent = items[id]?.parentId
        while let p = parent {
            items[p]?.etag = nextEtag()
            parent = items[p]?.parentId
        }
    }
}

/// Tree: root{ A{a1, a2, sub{s1}}, B{b1}, U{u1}, top }. Listed: root, A, sub, B (U never opened).
private func makeFixture() async throws -> (FakeRemote, ItemCache, ChangeWalker) {
    let remote = FakeRemote()
    for folder in ["A", "B", "U"] { remote.add(folder, in: "root", folder: true) }
    remote.add("top", in: "root")
    remote.add("a1", in: "A")
    remote.add("a2", in: "A")
    remote.add("sub", in: "A", folder: true)
    remote.add("s1", in: "sub")
    remote.add("b1", in: "B")
    remote.add("u1", in: "U")
    let cache = try memoryCache()
    for id in ["root", "A", "sub", "B"] {
        let (folder, kids) = try remote.children(of: id)
        cache.upsert([folder] + kids)
        cache.setListed(id)
    }
    return (remote, cache, ChangeWalker(cache: cache, remote: remote, rootId: "root"))
}

private func ids(_ items: [RemoteItem]) -> Set<String> { Set(items.map(\.id)) }

private func snapshot(_ cache: ItemCache) -> [RemoteItem] {
    cache.allItems().sorted { $0.id < $1.id }
}

@Suite struct ChangeWalkerTests {
    @Test func testNoChangeWhenRootEtagSame() async throws {
        let (_, _, walker) = try await makeFixture()
        #expect(try await walker.run() == ChangeSet(updated: [], deleted: []))
    }

    @Test func testAddInListedFolder() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.add("new", in: "sub")
        let changes = try await walker.run()
        #expect(ids(changes.updated) == ["root", "A", "sub", "new"])
        #expect(changes.deleted.isEmpty)
        #expect(cache.item("new") == (try remote.item("new")))
        #expect(try await walker.run() == ChangeSet(updated: [], deleted: []))
    }

    @Test func testEditFile() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.edit("a1")
        let changes = try await walker.run()
        let newEtag = try remote.item("a1").etag
        #expect(ids(changes.updated) == ["root", "A", "a1"])
        #expect(changes.updated.first { $0.id == "a1" }?.etag == newEtag)
        #expect(cache.item("a1")?.etag == newEtag)
        #expect(changes.deleted.isEmpty)
    }

    /// A replace that kept the server etag is cached with a local stamp (`SyncRules.replacedItem`).
    /// The walk must neither report it as changed nor drop the stamp when it reports a rename or move.
    @Test func testStampedEtagIsKept() async throws {
        let (remote, cache, walker) = try await makeFixture()
        var a1 = try #require(cache.item("a1"))
        a1.etag = ETag.stamped(a1.etag, "s")
        cache.upsert([a1])
        remote.add("new", in: "A")
        var changes = try await walker.run()
        #expect(ids(changes.updated) == ["root", "A", "new"])
        #expect(cache.item("a1")?.etag == a1.etag)

        remote.rename("a1", to: "renamed")
        changes = try await walker.run()
        #expect(changes.updated.first { $0.id == "a1" }?.etag == a1.etag)
        #expect(cache.item("a1")?.etag == a1.etag)

        remote.move("a1", to: "B")
        changes = try await walker.run()
        #expect(changes.updated.first { $0.id == "a1" }?.etag == a1.etag)

        remote.edit("a1")
        changes = try await walker.run()
        #expect(changes.updated.first { $0.id == "a1" }?.etag == (try remote.item("a1").etag))
    }

    @Test func testDeleteFile() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.delete("a2")
        let changes = try await walker.run()
        #expect(changes.deleted == ["a2"])
        #expect(ids(changes.updated) == ["root", "A"])
        #expect(cache.item("a2") == nil)
    }

    @Test func testDeleteFolderDeletesSubtree() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.delete("A")
        let changes = try await walker.run()
        #expect(Set(changes.deleted) == ["A", "a1", "a2", "sub", "s1"])
        #expect(changes.deleted.count == 5)
        #expect(ids(changes.updated) == ["root"])
        #expect(ids(cache.allItems()) == ["root", "B", "U", "top", "b1"])
    }

    @Test func testMoveBetweenListedFolders() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.move("a1", to: "B")
        let changes = try await walker.run()
        #expect(changes.deleted.isEmpty)
        #expect(ids(changes.updated) == ["root", "A", "B", "a1"])
        #expect(changes.updated.first { $0.id == "a1" }?.parentId == "B")
        #expect(cache.item("a1")?.parentId == "B")
    }

    @Test func testMoveIntoUnlistedFolder() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.move("a1", to: "U")
        let changes = try await walker.run()
        #expect(changes.deleted == ["a1"])
        #expect(ids(changes.updated) == ["root", "A", "U"])
        #expect(cache.item("U")?.etag == (try remote.item("U").etag))
        #expect(cache.item("a1") == nil)
    }

    @Test func testChangesUnderUnlistedFolderOnlyUpdateFolderRow() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.add("u2", in: "U")
        remote.edit("u1")
        let changes = try await walker.run()
        #expect(ids(changes.updated) == ["root", "U"])
        #expect(changes.deleted.isEmpty)
        #expect(cache.item("u2") == nil)
        #expect(cache.item("u1") == nil)
    }

    @Test func testRenameUpdates() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.rename("b1", to: "b1 renamed.txt")
        let changes = try await walker.run()
        #expect(ids(changes.updated) == ["root", "B", "b1"])
        #expect(changes.updated.first { $0.id == "b1" }?.name == "b1 renamed.txt")
        #expect(cache.item("b1")?.name == "b1 renamed.txt")
    }

    @Test func moveAgainstWalkOrder() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.move("b1", to: "A")              // seen in A before B's listing makes it a candidate
        let changes = try await walker.run()
        #expect(changes.deleted.isEmpty)
        #expect(ids(changes.updated) == ["root", "A", "B", "b1"])
        #expect(cache.item("b1")?.parentId == "A")
    }

    @Test func listedFolderMovedIntoUnlistedFolderDeletesItsSubtree() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.move("sub", to: "U")
        let changes = try await walker.run()
        #expect(Set(changes.deleted) == ["sub", "s1"])
        #expect(changes.deleted.count == 2)
        #expect(ids(changes.updated) == ["root", "A", "U"])
        #expect(cache.item("sub") == nil && cache.item("s1") == nil)
    }

    @Test func renameAndMoveIsOneUpdate() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.rename("a1", to: "a1 moved.txt")
        remote.move("a1", to: "B")
        let changes = try await walker.run()
        let a1 = changes.updated.filter { $0.id == "a1" }
        #expect(a1.count == 1)
        #expect(a1.first?.name == "a1 moved.txt" && a1.first?.parentId == "B")
        #expect(changes.deleted.isEmpty)
        #expect(cache.item("a1")?.name == "a1 moved.txt")
    }

    /// An enumerator lists A after the walker did and caches a child the walker's listing lacks.
    /// That child must not be reported deleted.
    @Test func concurrentEnumerationDoesNotDeleteNewChild() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.edit("a1")
        remote.afterChildren { id in
            guard id == "A" else { return }
            remote.afterChildren(nil)
            remote.add("y", in: "A")
            if let y = try? remote.item("y") { cache.upsert([y]) }
        }
        let changes = try await walker.run()
        #expect(!changes.deleted.contains("y"))
        #expect(cache.item("y") != nil)
        #expect(ids(changes.updated) == ["root", "A", "a1"])
        // The next run sees the newer root etag and finds y already cached: nothing to report for it.
        let next = try await walker.run()
        #expect(ids(next.updated) == ["root", "A"])
        #expect(next.deleted.isEmpty)
    }

    @Test func movedOutOfDeletedFolderSurvives() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.move("s1", to: "B")
        remote.delete("A")
        let changes = try await walker.run()
        #expect(Set(changes.deleted) == ["A", "a1", "a2", "sub"])
        #expect(changes.updated.first { $0.id == "s1" }?.parentId == "B")
        #expect(cache.item("s1")?.parentId == "B")
    }

    @Test func neverSyncedRootReportsOnlyTheRootRow() async throws {
        let remote = FakeRemote()
        remote.add("x", in: "root")
        let cache = try memoryCache()
        let changes = try await ChangeWalker(cache: cache, remote: remote, rootId: "root").run()
        #expect(ids(changes.updated) == ["root"])
        #expect(ids(cache.allItems()) == ["root"])
    }

    @Test func walkerFailureLeavesCacheUntouched() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.add("new", in: "A")
        remote.delete("b1")
        let before = snapshot(cache)
        remote.failChildren(onCall: 2)
        await #expect(throws: URLError.self) { try await walker.run() }
        #expect(snapshot(cache) == before)
        #expect(cache.isListed("A") && cache.isListed("B"))

        remote.failChildren(onCall: nil)
        let changes = try await walker.run()
        #expect(ids(changes.updated) == ["root", "A", "B", "new"])
        #expect(changes.deleted == ["b1"])
    }

    // A cached child missing from its re-listed parent and not seen elsewhere in the walk is looked
    // up by id before it is reported deleted.

    @Test func candidateGoneIsDeleted() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.edit("a2")                                   // A changed, so the walk lists it
        remote.afterChildren { id in
            guard id == "root" else { return }
            remote.afterChildren(nil)
            remote.delete("a1")                             // gone between the root and A listings
        }
        let changes = try await walker.run()
        #expect(changes.deleted == ["a1"])
        #expect(cache.item("a1") == nil)
    }

    @Test func candidateMovedMidWalkIntoListedFolderIsUpdated() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.edit("a2")
        remote.afterChildren { id in
            guard id == "root" else { return }              // root listed: B still looks unchanged
            remote.afterChildren(nil)
            remote.move("a1", to: "B")
        }
        let changes = try await walker.run()
        #expect(changes.deleted.isEmpty)
        #expect(changes.updated.first { $0.id == "a1" }?.parentId == "B")
        #expect(cache.item("a1")?.parentId == "B")
        // The next walk lists B and finds a1 already in place.
        let next = try await walker.run()
        #expect(next.deleted.isEmpty)
        #expect(!ids(next.updated).contains("a1"))
    }

    @Test func candidateMovedIntoUnlistedFolderIsDeleted() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.edit("a2")
        remote.afterChildren { id in
            guard id == "root" else { return }
            remote.afterChildren(nil)
            remote.move("a1", to: "U")                      // U was never opened
        }
        let changes = try await walker.run()
        #expect(changes.deleted == ["a1"])
        #expect(cache.item("a1") == nil)
    }

    @Test func candidateLookupFailureAbortsWalk() async throws {
        let (remote, cache, walker) = try await makeFixture()
        remote.delete("a1")
        remote.failItem(["a1"])
        let before = snapshot(cache)
        let revision = cache.revision
        await #expect(throws: URLError.self) { try await walker.run() }
        #expect(snapshot(cache) == before)
        #expect(cache.revision == revision)
        remote.failItem([])
        #expect(try await walker.run().deleted == ["a1"])
    }

    @Test func walkWithChangesBumpsRevision() async throws {
        let (remote, cache, walker) = try await makeFixture()
        let start = cache.revision
        _ = try await walker.run()                          // nothing changed: no apply
        #expect(cache.revision == start)
        remote.edit("a1")
        _ = try await walker.run()
        #expect(cache.revision == start + 1)
    }
}
