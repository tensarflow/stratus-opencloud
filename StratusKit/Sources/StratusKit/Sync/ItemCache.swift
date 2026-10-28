import Foundation
import os
import SQLite3

public enum ItemCacheError: Error, Equatable {
    case sqlite(Int32, String)
}

/// Every item the system has seen in one domain (space), in SQLite. One connection; every call
/// holds `lock`. Read and write helpers that cannot throw log failures and return empty results.
public final class ItemCache: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()
    private static let log = Logger(subsystem: "com.arteq.stratus", category: "cache")
    private static let select = "SELECT id, parent_id, name, is_folder, etag, size, modified, content_type, perms FROM items"

    private enum Value {
        case text(String?), int(Int64), real(Double?)
    }

    /// Opens or creates the database, creating its parent directory. A last path component of
    /// `:memory:` opens a private in-memory database.
    public init(url: URL) throws {
        var path = ":memory:"
        if url.lastPathComponent != path {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            path = url.path
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw ItemCacheError.sqlite(rc, message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)        // wait for another connection's write instead of SQLITE_BUSY
        do {
            try exec("PRAGMA journal_mode=WAL")
            try exec("""
                CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, parent_id TEXT, name TEXT NOT NULL,
                  is_folder INTEGER NOT NULL, etag TEXT NOT NULL, size INTEGER NOT NULL, modified REAL,
                  content_type TEXT, perms TEXT NOT NULL, listed INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS items_parent ON items(parent_id);
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: Public API

    /// Inserts or replaces the rows; an existing row keeps its `listed` flag.
    public func upsert(_ items: [RemoteItem]) {
        locked(()) { try transaction { try upsertRows(items) } }
    }

    public func item(_ id: String) -> RemoteItem? {
        locked(nil) { try query("\(Self.select) WHERE id = ?", [.text(id)]).first }
    }

    public func children(of id: String) -> [RemoteItem] {
        locked([]) { try query("\(Self.select) WHERE parent_id = ? ORDER BY name", [.text(id)]) }
    }

    public func allItems() -> [RemoteItem] {
        locked([]) { try query("\(Self.select) ORDER BY id", []) }
    }

    /// Marks a folder as enumerated by the system. No-op for an id without a row.
    public func setListed(_ id: String) {
        locked(()) { try run("UPDATE items SET listed = 1 WHERE id = ?", [[.text(id)]]) }
    }

    public func isListed(_ id: String) -> Bool {
        locked(false) {
            var listed = false
            try run("SELECT listed FROM items WHERE id = ?", [[.text(id)]]) { listed = sqlite3_column_int($0, 0) != 0 }
            return listed
        }
    }

    /// Removes `id` and everything cached below it; returns the removed ids (empty if `id` is unknown).
    public func removeSubtree(_ id: String) -> [String] {
        locked([]) { try transaction { try removeSubtreeRows(id) } }
    }

    /// Applies changes in one transaction: upserts first (so items moved out of a deleted folder
    /// survive), then removes each deleted id's subtree. Returns every removed id. On error nothing
    /// is changed. A walk's result passes `bumpRevision`, which advances `revision` in the same
    /// transaction; the extension's own writes (already known to the system) do not.
    public func apply(updated: [RemoteItem], deleted: [String], bumpRevision: Bool = false) throws -> [String] {
        try lock.withLock {
            try transaction {
                try upsertRows(updated)
                var removed: [String] = []
                for id in deleted { removed += try removeSubtreeRows(id) }
                if bumpRevision {
                    try run("""
                        INSERT INTO meta(key, value) VALUES('revision', '1')
                        ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1
                        """, [[]])
                }
                return removed
            }
        }
    }

    /// How many walks have changed the cache (see `SyncAnchor`).
    public var revision: Int { meta("revision").flatMap(Int.init) ?? 0 }

    public func meta(_ key: String) -> String? {
        locked(nil) {
            var value: String?
            try run("SELECT value FROM meta WHERE key = ?", [[.text(key)]]) { value = Self.text($0, 0) }
            return value
        }
    }

    /// `nil` removes the key.
    public func setMeta(_ key: String, _ value: String?) {
        locked(()) {
            if let value {
                try run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        [[.text(key), .text(value)]])
            } else {
                try run("DELETE FROM meta WHERE key = ?", [[.text(key)]])
            }
        }
    }

    // MARK: Internals (caller holds `lock`)

    private func upsertRows(_ items: [RemoteItem]) throws {
        // `modified` is stored as seconds since the reference date so a Date round-trips exactly.
        try run("""
            INSERT INTO items(id, parent_id, name, is_folder, etag, size, modified, content_type, perms)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET parent_id = excluded.parent_id, name = excluded.name,
              is_folder = excluded.is_folder, etag = excluded.etag, size = excluded.size,
              modified = excluded.modified, content_type = excluded.content_type, perms = excluded.perms
            """, items.map { item in
                [.text(item.id), .text(item.parentId), .text(item.name), .int(item.isFolder ? 1 : 0),
                 .text(item.etag), .int(item.size), .real(item.modified?.timeIntervalSinceReferenceDate),
                 .text(item.contentType), .text(item.permissions.ocString)]
            })
    }

    private func removeSubtreeRows(_ id: String) throws -> [String] {
        var ids: [String] = []
        try run("""
            WITH RECURSIVE sub(id) AS (SELECT id FROM items WHERE id = ?
              UNION SELECT items.id FROM items JOIN sub ON items.parent_id = sub.id)
            SELECT id FROM sub
            """, [[.text(id)]]) { ids.append(Self.text($0, 0) ?? "") }
        try run("DELETE FROM items WHERE id = ?", ids.map { [.text($0)] })
        return ids
    }

    private func query(_ sql: String, _ args: [Value]) throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        try run(sql, [args]) { s in
            items.append(RemoteItem(
                id: Self.text(s, 0) ?? "", parentId: Self.text(s, 1), name: Self.text(s, 2) ?? "",
                isFolder: sqlite3_column_int(s, 3) != 0, etag: Self.text(s, 4) ?? "",
                size: sqlite3_column_int64(s, 5),
                modified: sqlite3_column_type(s, 6) == SQLITE_NULL
                    ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, 6)),
                contentType: Self.text(s, 7), permissions: ItemPermissions(ocString: Self.text(s, 8) ?? "")))
        }
        return items
    }

    /// Prepares `sql` once and runs it for each row of bound arguments, calling `row` per result row.
    private func run(_ sql: String, _ argRows: [[Value]], row: ((OpaquePointer) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for args in argRows {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (index, arg) in args.enumerated() {
                let i = Int32(index + 1)
                let rc: Int32
                switch arg {
                case .text(let s?): rc = sqlite3_bind_text(stmt, i, s, -1, transient)
                case .int(let n): rc = sqlite3_bind_int64(stmt, i, n)
                case .real(let d?): rc = sqlite3_bind_double(stmt, i, d)
                case .text(nil), .real(nil): rc = sqlite3_bind_null(stmt, i)
                }
                guard rc == SQLITE_OK else { throw lastError() }
            }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw lastError() }
                row?(stmt)
            }
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func lastError() -> ItemCacheError {
        .sqlite(sqlite3_extended_errcode(db), String(cString: sqlite3_errmsg(db)))
    }

    private func locked<T>(_ fallback: T, _ body: () throws -> T) -> T {
        lock.withLock {
            do {
                return try body()
            } catch {
                Self.log.error("item cache: \(ErrorLog.code(error), privacy: .public) \(String(describing: error), privacy: .private)")
                return fallback
            }
        }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }
}
