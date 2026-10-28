import FileProvider
import Foundation

/// Saves local bytes the server would not take where they belong: as a conflict copy, `name
/// (conflict …)`, or in the space root when the folder they were meant for is gone.
public enum ConflictKeeper {
    /// The folder an upload or MKCOL targeted no longer exists (404; 409 is how some servers say it).
    public static func isParentGone(_ error: Error) -> Bool {
        switch error {
        case OpenCloudError.notFound, OpenCloudError.server(409): true
        default: false
        }
    }

    private static func isTaken(_ error: Error) -> Bool {
        if case OpenCloudError.preconditionFailed = error { return true }
        return false
    }

    /// Uploads the copy next to the item (`parentId`). If that folder is gone or the copy's name is
    /// taken there, the copy goes to the space root instead. If the root says not found or taken, the
    /// bytes are saved nowhere, so the error is a retryable one: never `.noSuchItem`, which would make
    /// the system delete the local edit. Any other failure (auth, quota, offline) passes through
    /// unchanged, for `FPErrors` to map; so do failures next to the item.
    public static func keep(name: String, parentId: String, rootId: String, date: Date = Date(),
                            upload: (_ parentId: String, _ name: String) async throws -> RemoteItem)
        async throws -> RemoteItem {
        let copy = SyncRules.conflictName(for: name, date: date)
        if parentId != rootId {
            do {
                return try await upload(parentId, copy)
            } catch where isParentGone(error) || isTaken(error) {
                // fall through to the root
            }
        }
        return try await inRoot { try await upload(rootId, copy) }
    }

    /// A new file for `parentId`: under its own name; if that is taken, as a conflict copy there; if
    /// the folder is gone, in the space root (see `createInRoot`). `signal`: the result is not simply
    /// the item asked for (renamed, or moved to the root), so the working set needs a walk.
    public static func create(name: String, parentId: String, rootId: String, date: Date = Date(),
                              upload: (_ parentId: String, _ name: String) async throws -> RemoteItem)
        async throws -> (item: RemoteItem, signal: Bool) {
        if parentId != rootId {
            do {
                do {
                    return (try await upload(parentId, name), false)
                } catch where isTaken(error) {
                    return (try await upload(parentId, SyncRules.conflictName(for: name, date: date)), true)
                }
            } catch where isParentGone(error) {
                let placed = try await createInRoot(name: name, rootId: rootId, date: date, isNameTaken: isTaken,
                                                    create: upload)
                return (placed.item, true)
            }
        }
        let placed = try await createInRoot(name: name, rootId: rootId, date: date, isNameTaken: isTaken,
                                            create: upload)
        return (placed.item, placed.renamed)
    }

    /// Creates the item in the space root, under its own name, or as a conflict copy if `isNameTaken`
    /// says the name is in use. Not found / precondition failed there leave the data on no server, so
    /// they become a retryable error; anything else passes through.
    public static func createInRoot(name: String, rootId: String, date: Date = Date(),
                                    isNameTaken: (Error) -> Bool,
                                    create: (_ parentId: String, _ name: String) async throws -> RemoteItem)
        async throws -> (item: RemoteItem, renamed: Bool) {
        let renamed = SyncRules.conflictName(for: name, date: date)
        return try await inRoot {
            do {
                return (try await create(rootId, name), false)
            } catch where isNameTaken(error) {
                return (try await create(rootId, renamed), true)
            }
        }
    }

    private static func inRoot<T>(_ attempt: () async throws -> T) async throws -> T {
        do {
            return try await attempt()
        } catch OpenCloudError.notFound, OpenCloudError.preconditionFailed {
            throw NSFileProviderError(.serverUnreachable)
        }
    }
}
