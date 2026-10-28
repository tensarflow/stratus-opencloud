import FileProvider
import Foundation
import UniformTypeIdentifiers

/// Item identifier = `oc:fileid`; the space root is `.rootContainer`.
public enum FPMapping {
    public static func identifier(for id: String, rootId: String) -> NSFileProviderItemIdentifier {
        id == rootId ? .rootContainer : NSFileProviderItemIdentifier(id)
    }

    /// `.workingSet` and `.trashContainer` are not server items; they come back as their raw value.
    public static func remoteId(for identifier: NSFileProviderItemIdentifier, rootId: String) -> String {
        identifier == .rootContainer ? rootId : identifier.rawValue
    }
}

public final class FPItem: NSObject, NSFileProviderItem {
    public let item: RemoteItem
    public let rootId: String

    public init(_ item: RemoteItem, rootId: String) {
        self.item = item
        self.rootId = rootId
    }

    public var itemIdentifier: NSFileProviderItemIdentifier {
        FPMapping.identifier(for: item.id, rootId: rootId)
    }

    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard item.id != rootId, let parent = item.parentId else { return .rootContainer }
        return FPMapping.identifier(for: parent, rootId: rootId)
    }

    public var filename: String { item.name }

    public var contentType: UTType {
        item.isFolder ? .folder : UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
    }

    /// The SDK's `.allowsEvicting` (deprecated since macOS 13 in favour of content policies, so the
    /// name would warn). The system still reads the bit; it enables "Remove Download" and eviction
    /// under disk pressure.
    public static let allowsEvicting = NSFileProviderItemCapabilities(rawValue: 1 << 6)

    /// Reading and evicting always; D/N/V for every item; W only for files; C or K only for folders.
    /// (`.allowsAddingSubItems` is the same bit as `.allowsWriting`, `.allowsContentEnumerating`
    /// the same as `.allowsReading`.)
    public var capabilities: NSFileProviderItemCapabilities {
        let perms = item.permissions
        var caps: NSFileProviderItemCapabilities = item.isFolder ? .allowsContentEnumerating : .allowsReading
        caps.insert(Self.allowsEvicting)
        if perms.contains(.delete) { caps.insert(.allowsDeleting) }
        if perms.contains(.rename) { caps.insert(.allowsRenaming) }
        if perms.contains(.move) { caps.insert(.allowsReparenting) }
        if item.isFolder {
            if !perms.isDisjoint(with: [.createFile, .createFolder]) { caps.insert(.allowsAddingSubItems) }
        } else if perms.contains(.write) {
            caps.insert(.allowsWriting)
        }
        return caps
    }

    public var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data(item.etag.utf8),
            metadataVersion: Data("\(item.etag)|\(item.name)|\(item.parentId ?? "")".utf8))
    }

    public var documentSize: NSNumber? { item.isFolder ? nil : NSNumber(value: item.size) }
    public var contentModificationDate: Date? { item.modified }
    /// WebDAV has no creation date, and an empty one shows as 1 January 1970 in Finder.
    public var creationDate: Date? { item.modified }
}
