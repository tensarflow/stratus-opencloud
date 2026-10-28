import FileProvider
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import StratusKit

@Suite struct FPItemTests {
    let rootId = "s$p!root"

    func file(_ perms: String, name: String = "a.pdf", parent: String = "s$p!docs") -> RemoteItem {
        RemoteItem(id: "s$p!a", parentId: parent, name: name, isFolder: false, etag: "e1", size: 42,
                   modified: Date(timeIntervalSince1970: 1_700_000_000), permissions: ItemPermissions(ocString: perms))
    }

    @Test func testRootMapsToRootContainer() {
        #expect(FPMapping.identifier(for: rootId, rootId: rootId) == .rootContainer)
        #expect(FPMapping.identifier(for: "s$p!a", rootId: rootId).rawValue == "s$p!a")
        #expect(FPMapping.remoteId(for: .rootContainer, rootId: rootId) == rootId)
        #expect(FPMapping.remoteId(for: NSFileProviderItemIdentifier("s$p!a"), rootId: rootId) == "s$p!a")

        let root = FPItem(RemoteItem(id: rootId, name: "Personal", isFolder: true, etag: "r"), rootId: rootId)
        #expect(root.itemIdentifier == .rootContainer)
        #expect(root.parentItemIdentifier == .rootContainer)
        #expect(FPItem(file("R", parent: rootId), rootId: rootId).parentItemIdentifier == .rootContainer)
        #expect(FPItem(file("R"), rootId: rootId).parentItemIdentifier.rawValue == "s$p!docs")
    }

    @Test func testCapabilitiesFromPermissions() {
        let evict = FPItem.allowsEvicting
        #expect(FPItem(file("RDNVW"), rootId: rootId).capabilities
            == [.allowsReading, .allowsDeleting, .allowsRenaming, .allowsReparenting, .allowsWriting, evict])
        #expect(FPItem(file("R"), rootId: rootId).capabilities == [.allowsReading, evict])

        func folder(_ perms: String) -> FPItem {
            FPItem(RemoteItem(id: "f", parentId: rootId, name: "f", isFolder: true, etag: "e",
                              permissions: ItemPermissions(ocString: perms)), rootId: rootId)
        }
        #expect(folder("RDNVCK").capabilities
            == [.allowsContentEnumerating, .allowsDeleting, .allowsRenaming, .allowsReparenting, .allowsAddingSubItems,
                evict])
        #expect(folder("C").capabilities == [.allowsContentEnumerating, .allowsAddingSubItems, evict])
        // W alone does not let anything be added to a folder (.allowsAddingSubItems == .allowsWriting).
        #expect(folder("RW").capabilities == [.allowsContentEnumerating, evict])
    }

    /// "Remove Download" and disk-pressure eviction: every file and folder is evictable. The bit is
    /// the one the SDK names `.allowsEvicting` (deprecated since macOS 13, hence the raw value).
    @Test func filesAndFoldersAreEvictable() {
        #expect(FPItem.allowsEvicting.rawValue == 1 << 6)
        #expect(FPItem(file(""), rootId: rootId).capabilities.contains(FPItem.allowsEvicting))
        let folder = RemoteItem(id: "f", parentId: rootId, name: "f", isFolder: true, etag: "e")
        #expect(FPItem(folder, rootId: rootId).capabilities.contains(FPItem.allowsEvicting))
    }

    @Test func testVersionChangesOnRename() {
        let before = FPItem(file("R", name: "a.pdf"), rootId: rootId).itemVersion
        let after = FPItem(file("R", name: "b.pdf"), rootId: rootId).itemVersion
        #expect(before.contentVersion == Data("e1".utf8))
        #expect(before.contentVersion == after.contentVersion)
        #expect(before.metadataVersion == Data("e1|a.pdf|s$p!docs".utf8))
        #expect(before.metadataVersion != after.metadataVersion)
    }

    @Test func fileAndFolderAttributes() {
        let item = FPItem(file("R"), rootId: rootId)
        #expect(item.filename == "a.pdf")
        #expect(item.contentType == .pdf)
        #expect(item.documentSize == 42)
        #expect(item.contentModificationDate == Date(timeIntervalSince1970: 1_700_000_000))
        let folder = FPItem(RemoteItem(id: "f", name: "f.pdf", isFolder: true, etag: "e", size: 9), rootId: rootId)
        #expect(folder.contentType == .folder)
        #expect(folder.documentSize == nil)
    }

    /// WebDAV has no creation date. Left empty, Finder shows 1 January 1970, so the modification
    /// date stands in for it (nil only when that is unknown too).
    @Test func creationDateFallsBackToModified() {
        #expect(FPItem(file("R"), rootId: rootId).creationDate == Date(timeIntervalSince1970: 1_700_000_000))
        let folder = FPItem(RemoteItem(id: "f", name: "f", isFolder: true, etag: "e",
                                       modified: Date(timeIntervalSince1970: 1_600_000_000)), rootId: rootId)
        #expect(folder.creationDate == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(FPItem(RemoteItem(id: "f", name: "f", isFolder: true, etag: "e"), rootId: rootId).creationDate == nil)
    }

    @Test func testAnchorRoundTrip() throws {
        let anchor = SyncAnchor(generation: 3, revision: 9, rootEtag: "abc\"1")
        #expect(SyncAnchor(data: anchor.data) == anchor)
        #expect(SyncAnchor(data: Data("garbage".utf8)) == nil)
        #expect(SyncAnchor(data: Data()) == nil)
        // Anchors from before the revision existed no longer decode: the system re-enumerates once.
        #expect(SyncAnchor(data: Data(#"{"generation":3,"rootEtag":"x"}"#.utf8)) == nil)
    }

    @Test func staleAnchorDetection() {
        let anchor = SyncAnchor(generation: 3, revision: 9, rootEtag: "r")
        #expect(anchor.isCurrent(generation: 3, revision: 9))
        #expect(!anchor.isCurrent(generation: 3, revision: 10))   // the cache moved on without the system
        #expect(!anchor.isCurrent(generation: 4, revision: 9))    // a different (rebuilt) cache
    }
}

@Suite struct FPErrorsTests {
    func code(_ error: Error) -> NSFileProviderError.Code? {
        let mapped = FPErrors.map(error)
        guard (mapped as NSError).domain == NSFileProviderErrorDomain else { return nil }
        return (mapped as? NSFileProviderError)?.code
    }

    @Test func testOfflineMapsToServerUnreachable() {
        #expect(code(URLError(.notConnectedToInternet)) == .serverUnreachable)
        #expect(code(OpenCloudError.server(503)) == .serverUnreachable)
        for c: URLError.Code in [.timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost] {
            #expect(code(URLError(c)) == .serverUnreachable)
        }
        #expect(code(OpenCloudError.server(500)) == .serverUnreachable)
        #expect(code(OpenCloudError.server(599)) == .serverUnreachable)
        #expect(code(OpenCloudError.server(400)) == nil)
        #expect(code(URLError(.badURL)) == nil)
    }

    @Test func testNotFoundMapsNoSuchItem() {
        #expect(code(OpenCloudError.notFound) == .noSuchItem)
    }

    @Test func authQuotaAndPassThrough() {
        #expect(code(OpenCloudError.unauthorized) == .notAuthenticated)
        #expect(code(AuthError.signInRequired) == .notAuthenticated)
        #expect(code(OpenCloudError.insufficientStorage) == .insufficientQuota)
        #expect(FPErrors.map(OpenCloudError.forbidden) as? OpenCloudError == .forbidden)
        #expect(FPErrors.map(CancellationError()) is CancellationError)
        #expect(FPErrors.map(AuthError.timedOut) as? AuthError == .timedOut)
    }
}
