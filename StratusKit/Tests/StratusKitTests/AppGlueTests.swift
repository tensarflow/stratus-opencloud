import FileProvider
import Foundation
import Testing
@testable import StratusKit

@Suite struct AppGlueTests {
    @Test func cacheDirectoryName() {
        #expect(AppGroup.directoryName(for: "storage$space!node") == "storage_space_node")
        #expect(AppGroup.directoryName(for: "a.B-c_9") == "a.B-c_9")
        #expect(AppGroup.directoryName(for: "ö/x y") == "__x_y")
        #expect(AppGroup.directoryName(for: "..") == "_..")
        #expect(AppGroup.directoryName(for: "") == "_")
    }

    @Test func groupsNeedInfoPlistKeys() {
        #expect(throws: AuthError.missingAppGroup) { try AppGroup.keychainGroup() }
        #expect(throws: AuthError.missingAppGroup) { try AppGroup.cacheURL(driveId: "x") }
    }

    @Test func folderDiff() {
        let a = RemoteItem(id: "a", parentId: "p", name: "a.txt", isFolder: false, etag: "1")
        let b = RemoteItem(id: "b", parentId: "p", name: "b.txt", isFolder: false, etag: "1")
        let c = RemoteItem(id: "c", parentId: "p", name: "c", isFolder: true, etag: "1")
        var a2 = a; a2.etag = "2"
        var b2 = b; b2.name = "B.txt"
        let d = RemoteItem(id: "d", parentId: "p", name: "d.txt", isFolder: false, etag: "1")

        let same = FolderDiff.compare(cached: [a, b, c], fresh: [a, b, c])
        #expect(same.changed.isEmpty && same.missing.isEmpty)

        let diff = FolderDiff.compare(cached: [a, b, c], fresh: [a2, b2, d])
        #expect(diff.changed.map(\.id) == ["a", "b", "d"])
        #expect(diff.missing == ["c"])

        // A stamped cached etag (see `SyncRules.replacedItem`) matches the plain server etag, and a
        // reported change keeps the stamp, so the content version does not flip back.
        var stampedA = a; stampedA.etag = ETag.stamped("1", "s")
        #expect(FolderDiff.compare(cached: [stampedA], fresh: [a]).changed.isEmpty)
        var renamedA = a; renamedA.name = "z.txt"
        #expect(FolderDiff.compare(cached: [stampedA], fresh: [renamedA]).changed.map(\.etag) == [stampedA.etag])
        #expect(FolderDiff.compare(cached: [stampedA], fresh: [a2]).changed.map(\.etag) == ["2"])
    }

    @Test func domainRemovalNeedsProofTheSpaceIsGone() async {
        let asked = CallLog()
        let removable = await DomainPolicy.removable(
            domains: ["personal", "listed", "gone", "flaky", "exists"], listed: ["listed"], keep: ["personal"]
        ) { id in
            asked.record(id)
            switch id {
            case "gone": return false
            case "flaky": throw URLError(.timedOut)
            default: return true
            }
        }
        #expect(removable == ["gone"])
        #expect(asked.ids == ["gone", "flaky", "exists"])      // listed and kept spaces are never in question
    }

    @Test func domainDisabledError() {
        #expect(FPErrors.isDomainDisabled(NSFileProviderError(.domainDisabled)))
        #expect(FPErrors.isDomainDisabled(NSError(domain: NSFileProviderErrorDomain, code: -2011)))
        #expect(!FPErrors.isDomainDisabled(NSFileProviderError(.serverUnreachable)))
        #expect(!FPErrors.isDomainDisabled(URLError(.timedOut)))
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var ids: [String] { lock.withLock { log } }
    func record(_ id: String) { lock.withLock { log.append(id) } }
}
