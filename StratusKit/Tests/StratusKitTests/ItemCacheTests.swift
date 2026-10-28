import Foundation
import Testing
@testable import StratusKit

func memoryCache() throws -> ItemCache {
    try ItemCache(url: URL(fileURLWithPath: ":memory:"))
}

@Suite struct ItemCacheTests {
    let root = RemoteItem(id: "s$p!root", name: "Personal", isFolder: true, etag: "e0",
                          permissions: ItemPermissions(ocString: "RCK"))
    let docs = RemoteItem(id: "s$p!docs", parentId: "s$p!root", name: "Ödev Çağlayan şğ #1 100%", isFolder: true, etag: "e1")
    let file = RemoteItem(id: "s$p!a", parentId: "s$p!docs", name: "a+b?.txt", isFolder: false, etag: "e2",
                          size: 42, modified: Date(timeIntervalSince1970: 1_700_000_000.5),
                          contentType: "text/plain", permissions: ItemPermissions(ocString: "RDNVW"))

    @Test func testUpsertChildrenListed() throws {
        let cache = try memoryCache()
        cache.upsert([root, docs, file])
        #expect(cache.item(file.id) == file)
        #expect(cache.item(root.id) == root)
        #expect(cache.item("missing") == nil)
        #expect(cache.children(of: docs.id) == [file])
        #expect(cache.children(of: root.id).map(\.id) == [docs.id])
        #expect(cache.allItems().count == 3)

        #expect(!cache.isListed(docs.id))
        cache.setListed(docs.id)
        #expect(cache.isListed(docs.id))
        var renamed = docs
        renamed.name = "Docs"
        renamed.etag = "e9"
        cache.upsert([renamed])                     // an upsert keeps the listed flag
        #expect(cache.isListed(docs.id))
        #expect(cache.item(docs.id)?.name == "Docs")
    }

    @Test func testRemoveSubtreeReturnsDescendants() throws {
        let cache = try memoryCache()
        let sub = RemoteItem(id: "s$p!sub", parentId: docs.id, name: "sub", isFolder: true, etag: "e3")
        let deep = RemoteItem(id: "s$p!deep", parentId: sub.id, name: "deep.txt", isFolder: false, etag: "e4")
        cache.upsert([root, docs, file, sub, deep])
        let removed = cache.removeSubtree(docs.id)
        #expect(Set(removed) == [docs.id, file.id, sub.id, deep.id])
        #expect(cache.allItems().map(\.id) == [root.id])
        #expect(cache.removeSubtree("missing").isEmpty)
    }

    @Test func testMetaRoundTrip() throws {
        let cache = try memoryCache()
        #expect(cache.meta("generation") == nil)
        cache.setMeta("generation", "7")
        #expect(cache.meta("generation") == "7")
        cache.setMeta("generation", "8")
        #expect(cache.meta("generation") == "8")
        cache.setMeta("generation", nil)
        #expect(cache.meta("generation") == nil)
    }

    @Test func persistsAcrossReopenAndCreatesParentDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stratus-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/items.sqlite")
        do {
            let cache = try ItemCache(url: url)
            cache.upsert([root, docs])
            cache.setListed(root.id)
            cache.setMeta("k", "v")
        }
        let reopened = try ItemCache(url: url)
        #expect(reopened.item(docs.id) == docs)
        #expect(reopened.isListed(root.id))
        #expect(reopened.meta("k") == "v")
    }

    @Test func applyIsOneTransaction() throws {
        let cache = try memoryCache()
        cache.upsert([root, docs, file])
        var moved = file
        moved.parentId = root.id
        let removed = try cache.apply(updated: [moved], deleted: [docs.id])
        #expect(removed == [docs.id])               // file moved out first, so it survives
        #expect(cache.item(file.id)?.parentId == root.id)
        #expect(cache.item(docs.id) == nil)
    }

    @Test func onlyWalkAppliesBumpTheRevision() throws {
        let cache = try memoryCache()
        #expect(cache.revision == 0)
        _ = try cache.apply(updated: [root, docs], deleted: [])                     // the extension's own write
        #expect(cache.revision == 0)
        _ = try cache.apply(updated: [file], deleted: [], bumpRevision: true)       // a walk's result
        #expect(cache.revision == 1)
        _ = try cache.apply(updated: [], deleted: [file.id], bumpRevision: true)
        #expect(cache.revision == 2)
        #expect(cache.item(file.id) == nil)
    }

    @Test func permissionsOCStringRoundTrip() {
        for letters in ["", "R", "RDNVW", "RDNVCK", "DNVWCK"] {
            let perms = ItemPermissions(ocString: letters)
            #expect(ItemPermissions(ocString: perms.ocString) == perms)
        }
        #expect(ItemPermissions(ocString: "KCWVNDR").ocString == "RDNVWCK")
        #expect(ItemPermissions(ocString: "RZP").ocString == "R")
    }
}
