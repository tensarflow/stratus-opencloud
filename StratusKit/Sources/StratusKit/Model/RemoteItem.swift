import Foundation

/// Permissions from the `oc:permissions` property (one letter per capability).
public struct ItemPermissions: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let share = ItemPermissions(rawValue: 1 << 0)        // R
    public static let delete = ItemPermissions(rawValue: 1 << 1)       // D
    public static let rename = ItemPermissions(rawValue: 1 << 2)       // N
    public static let move = ItemPermissions(rawValue: 1 << 3)         // V
    public static let write = ItemPermissions(rawValue: 1 << 4)        // W
    public static let createFile = ItemPermissions(rawValue: 1 << 5)   // C
    public static let createFolder = ItemPermissions(rawValue: 1 << 6) // K

    /// Parses e.g. `RDNVCKZP`. Letters this app does not use are ignored.
    public init(ocString: String) {
        var result: ItemPermissions = []
        for letter in ocString {
            switch letter {
            case "R": result.insert(.share)
            case "D": result.insert(.delete)
            case "N": result.insert(.rename)
            case "V": result.insert(.move)
            case "W": result.insert(.write)
            case "C": result.insert(.createFile)
            case "K": result.insert(.createFolder)
            default: break
            }
        }
        self = result
    }

    /// The letters for the known bits, in `RDNVWCK` order; `init(ocString:)` reads it back.
    public var ocString: String {
        let letters: [(ItemPermissions, Character)] = [
            (.share, "R"), (.delete, "D"), (.rename, "N"), (.move, "V"),
            (.write, "W"), (.createFile, "C"), (.createFolder, "K"),
        ]
        return String(letters.compactMap { contains($0.0) ? $0.1 : nil })
    }
}

/// One file or folder as the server describes it. `id` is the stable `oc:fileid`.
public struct RemoteItem: Sendable, Equatable, Codable {
    public var id: String
    public var parentId: String?
    public var name: String
    public var isFolder: Bool
    public var etag: String          // without quotes
    public var size: Int64
    public var modified: Date?
    public var contentType: String?
    public var permissions: ItemPermissions

    public init(
        id: String, parentId: String? = nil, name: String, isFolder: Bool, etag: String,
        size: Int64 = 0, modified: Date? = nil, contentType: String? = nil,
        permissions: ItemPermissions = []
    ) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.isFolder = isFolder
        self.etag = etag
        self.size = size
        self.modified = modified
        self.contentType = contentType
        self.permissions = permissions
    }
}

/// A space (drive) from `GET /graph/v1.0/me/drives`.
public struct Drive: Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String          // "personal" | "project" | ...
    public var rootEtag: String

    public init(id: String, name: String, type: String, rootEtag: String) {
        self.id = id
        self.name = name
        self.type = type
        self.rootEtag = rootEtag
    }
}
