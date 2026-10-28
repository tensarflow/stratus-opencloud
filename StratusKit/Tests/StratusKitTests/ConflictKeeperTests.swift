import FileProvider
import Foundation
import Testing
@testable import StratusKit

/// Records every upload attempt (folder, name) and answers from `outcome`.
private actor Uploads {
    var calls: [String] = []
    func record(_ parent: String, _ name: String) { calls.append("\(parent)/\(name)") }
}

private let date = Date(timeIntervalSince1970: 1_793_201_400)
private let copy = SyncRules.conflictName(for: "a.txt", date: date)

private func keep(_ uploads: Uploads, parent: String = "S$P!dir",
                  _ outcome: @escaping @Sendable (String) throws -> RemoteItem) async throws -> RemoteItem {
    try await ConflictKeeper.keep(name: "a.txt", parentId: parent, rootId: "S$P!root", date: date) { folder, name in
        await uploads.record(folder, name)
        return try outcome(folder)
    }
}

private func item(in folder: String) -> RemoteItem {
    RemoteItem(id: "S$P!copy", parentId: folder, name: copy, isFolder: false, etag: "e")
}

private func isRetryable(_ error: Error) -> Bool {
    let ns = error as NSError
    return ns.domain == NSFileProviderErrorDomain && ns.code == NSFileProviderError.Code.serverUnreachable.rawValue
}

@Suite struct ConflictKeeperTests {
    @Test func copyGoesNextToTheItem() async throws {
        let uploads = Uploads()
        let saved = try await keep(uploads) { item(in: $0) }
        #expect(saved.parentId == "S$P!dir")
        #expect(await uploads.calls == ["S$P!dir/\(copy)"])
    }

    @Test func parentGoneFallsBackToTheSpaceRoot() async throws {
        let uploads = Uploads()
        let saved = try await keep(uploads) { folder in
            if folder == "S$P!dir" { throw OpenCloudError.notFound }
            return item(in: folder)
        }
        #expect(saved.parentId == "S$P!root")
        #expect(await uploads.calls == ["S$P!dir/\(copy)", "S$P!root/\(copy)"])
    }

    @Test func nameTakenNextToTheItemFallsBackToTheSpaceRoot() async throws {
        let uploads = Uploads()
        let saved = try await keep(uploads) { folder in
            if folder == "S$P!dir" { throw OpenCloudError.preconditionFailed }
            return item(in: folder)
        }
        #expect(saved.parentId == "S$P!root")
    }

    /// The bytes are saved nowhere: the error must make the system retry, never `.noSuchItem`
    /// (which would delete the local edit).
    @Test func rootNotFoundOrTakenIsRetryable() async throws {
        for failure in [OpenCloudError.notFound, .preconditionFailed] {
            let uploads = Uploads()
            do {
                _ = try await keep(uploads) { folder in
                    throw folder == "S$P!dir" ? OpenCloudError.notFound : failure
                }
                Issue.record("expected an error for \(failure)")
            } catch {
                #expect(isRetryable(error), "\(failure) gave \(error)")
                #expect(isRetryable(FPErrors.map(error)))
            }
            #expect(await uploads.calls.count == 2)
        }
    }

    /// Any other failure of the root attempt keeps its meaning, so `FPErrors` can map it.
    @Test func otherRootErrorsPassThrough() async throws {
        let expected: [(OpenCloudError, NSFileProviderError.Code?)] = [
            (.unauthorized, .notAuthenticated), (.insufficientStorage, .insufficientQuota),
            (.server(503), .serverUnreachable), (.forbidden, nil),
        ]
        for (failure, code) in expected {
            let uploads = Uploads()
            await #expect(throws: failure) {
                _ = try await keep(uploads) { folder in
                    throw folder == "S$P!dir" ? OpenCloudError.notFound : failure
                }
            }
            if let code {
                #expect((FPErrors.map(failure) as NSError).code == code.rawValue)
            }
            #expect(await uploads.calls.count == 2)
        }
    }

    /// 409 is how a missing parent can answer too.
    @Test func conflictStatusMeansParentGone() async throws {
        let uploads = Uploads()
        let saved = try await keep(uploads) { folder in
            if folder == "S$P!dir" { throw OpenCloudError.server(409) }
            return item(in: folder)
        }
        #expect(saved.parentId == "S$P!root")
    }

    @Test func itemInTheRootTriesOnce() async throws {
        let uploads = Uploads()
        await #expect(throws: (any Error).self) {
            _ = try await keep(uploads, parent: "S$P!root") { _ in throw OpenCloudError.notFound }
        }
        #expect(await uploads.calls == ["S$P!root/\(copy)"])
    }

    /// Other failures next to the item (offline, server error) are passed on as they are; the system
    /// retries the whole modification.
    @Test func otherParentErrorsPassThrough() async throws {
        let uploads = Uploads()
        await #expect(throws: OpenCloudError.server(503)) {
            _ = try await keep(uploads) { _ in throw OpenCloudError.server(503) }
        }
        #expect(await uploads.calls.count == 1)
    }
}

// MARK: Creating something new

private func made(_ name: String, in folder: String) -> RemoteItem {
    RemoteItem(id: "S$P!new", parentId: folder, name: name, isFolder: false, etag: "e")
}

private func create(_ uploads: Uploads, parent: String = "S$P!dir",
                    _ outcome: @escaping @Sendable (String, String) throws -> RemoteItem)
    async throws -> (item: RemoteItem, signal: Bool) {
    try await ConflictKeeper.create(name: "a.txt", parentId: parent, rootId: "S$P!root", date: date) { folder, name in
        await uploads.record(folder, name)
        return try outcome(folder, name)
    }
}

@Suite struct ConflictKeeperCreateTests {
    @Test func parentOkUploadsOnceUnderTheOriginalName() async throws {
        let uploads = Uploads()
        let result = try await create(uploads) { made($1, in: $0) }
        #expect(result.item.parentId == "S$P!dir" && result.item.name == "a.txt")
        #expect(result.signal == false)
        #expect(await uploads.calls == ["S$P!dir/a.txt"])
    }

    @Test func parentGoneUploadsToTheRootUnderTheOriginalName() async throws {
        for gone in [OpenCloudError.notFound, .server(409)] {
            let uploads = Uploads()
            let result = try await create(uploads) { folder, name in
                if folder == "S$P!dir" { throw gone }
                return made(name, in: folder)
            }
            #expect(result.item.parentId == "S$P!root" && result.item.name == "a.txt")
            #expect(result.signal)
            #expect(await uploads.calls == ["S$P!dir/a.txt", "S$P!root/a.txt"])
        }
    }

    @Test func nameTakenInTheRootGetsTheConflictName() async throws {
        let uploads = Uploads()
        let result = try await create(uploads) { folder, name in
            if folder == "S$P!dir" { throw OpenCloudError.notFound }
            if name == "a.txt" { throw OpenCloudError.preconditionFailed }
            return made(name, in: folder)
        }
        #expect(result.item.parentId == "S$P!root" && result.item.name == copy)
        #expect(result.signal)
        #expect(await uploads.calls == ["S$P!dir/a.txt", "S$P!root/a.txt", "S$P!root/\(copy)"])
    }

    @Test func nameTakenInTheParentGetsTheConflictNameThere() async throws {
        let uploads = Uploads()
        let result = try await create(uploads) { folder, name in
            if name == "a.txt" { throw OpenCloudError.preconditionFailed }
            return made(name, in: folder)
        }
        #expect(result.item.parentId == "S$P!dir" && result.item.name == copy)
        #expect(result.signal)
    }

    /// The new data is on no server: retry, never `.noSuchItem` (the system would delete it).
    @Test func rootFailingIsRetryable() async throws {
        for failure in [OpenCloudError.notFound, .preconditionFailed] {
            let uploads = Uploads()
            do {
                _ = try await create(uploads) { folder, _ in
                    throw folder == "S$P!dir" ? OpenCloudError.notFound : failure
                }
                Issue.record("expected an error for \(failure)")
            } catch {
                #expect(isRetryable(error), "\(failure) gave \(error)")
            }
        }
    }

    @Test func otherRootErrorsPassThrough() async throws {
        let uploads = Uploads()
        await #expect(throws: OpenCloudError.insufficientStorage) {
            _ = try await create(uploads) { folder, _ in
                throw folder == "S$P!dir" ? OpenCloudError.notFound : OpenCloudError.insufficientStorage
            }
        }
    }

    /// Errors that are not about the parent are not retried elsewhere.
    @Test func otherParentErrorsPassThrough() async throws {
        let uploads = Uploads()
        await #expect(throws: OpenCloudError.server(503)) {
            _ = try await create(uploads) { _, _ in throw OpenCloudError.server(503) }
        }
        #expect(await uploads.calls.count == 1)
    }

    @Test func itemInTheRootNeverMeansNoSuchItem() async throws {
        let uploads = Uploads()
        do {
            _ = try await create(uploads, parent: "S$P!root") { _, _ in throw OpenCloudError.notFound }
            Issue.record("expected an error")
        } catch { #expect(isRetryable(error)) }
        #expect(await uploads.calls == ["S$P!root/a.txt"])
    }

    /// Folders: the same fallback, with "already exists" as the name clash.
    @Test func foldersUseTheirOwnClashError() async throws {
        let uploads = Uploads()
        let result = try await ConflictKeeper.createInRoot(
            name: "dir", rootId: "S$P!root", date: date, isNameTaken: { $0 as? OpenCloudError == .alreadyExists }
        ) { folder, name in
            await uploads.record(folder, name)
            if name == "dir" { throw OpenCloudError.alreadyExists }
            return made(name, in: folder)
        }
        #expect(result.item.name == SyncRules.conflictName(for: "dir", date: date) && result.renamed)
        #expect(await uploads.calls.count == 2)
    }

    @Test func parentGoneErrors() {
        #expect(ConflictKeeper.isParentGone(OpenCloudError.notFound))
        #expect(ConflictKeeper.isParentGone(OpenCloudError.server(409)))
        #expect(!ConflictKeeper.isParentGone(OpenCloudError.preconditionFailed))
        #expect(!ConflictKeeper.isParentGone(OpenCloudError.server(503)))
        #expect(!ConflictKeeper.isParentGone(CancellationError()))
    }
}
