import Foundation

/// The shared App Group, named by the `StratusAppGroup` Info.plist key (set from `Config/Signing.xcconfig`).
/// Throwing accessors, so a bundle without the key (unit tests) does not trap.
public enum AppGroup {
    public static func id(bundle: Bundle = .main) throws -> String {
        guard let id = bundle.object(forInfoDictionaryKey: "StratusAppGroup") as? String, !id.isEmpty
        else { throw AuthError.missingAppGroup }
        return id
    }

    public static func containerURL(bundle: Bundle = .main) throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: try id(bundle: bundle))
        else { throw AuthError.missingAppGroup }
        return url
    }

    /// `<group container>/auth.lock`, the `FileLock` all processes use around token refresh.
    public static func authLockURL(bundle: Bundle = .main) throws -> URL {
        try containerURL(bundle: bundle).appending(path: "auth.lock")
    }

    /// The keychain access group both processes share, from the `StratusKeychainGroup` Info.plist key.
    public static func keychainGroup(bundle: Bundle = .main) throws -> String {
        guard let group = bundle.object(forInfoDictionaryKey: "StratusKeychainGroup") as? String, !group.isEmpty
        else { throw AuthError.missingAppGroup }
        return group
    }

    /// `<group container>/<driveId as a file name>/items.sqlite`, the per-domain item cache.
    public static func cacheURL(driveId: String, bundle: Bundle = .main) throws -> URL {
        try containerURL(bundle: bundle).appending(path: directoryName(for: driveId)).appending(path: "items.sqlite")
    }

    /// Every character outside `[A-Za-z0-9._-]` becomes `_` (`storage$space!node` → `storage_space_node`).
    /// A name of only dots (or nothing) gets a leading `_`, so it never means `.` or `..`.
    public static func directoryName(for driveId: String) -> String {
        let name = String(driveId.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" })
        return name.allSatisfy { $0 == "." } ? "_" + name : name
    }
}
