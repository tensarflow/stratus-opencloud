import Foundation

/// Which local names never sync, and how conflict copies are named.
public enum SyncRules {
    /// Finder metadata and editor lock files that must not reach the server.
    public static func isExcluded(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".localized" || name == "Icon\r"
            || name.hasPrefix("._") || name.hasPrefix(".~lock.") || name.hasPrefix("~$")
    }

    /// `report.pdf` becomes `report (conflict 2026-10-28 1530).pdf`. Only the last extension is kept
    /// apart, and a leading dot (`.env`) is not an extension.
    public static func conflictName(for name: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let suffix = " (conflict \(formatter.string(from: date)))"

        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name + suffix }
        return name[..<dot] + suffix + name[dot...]
    }

    /// What an upload meant to replace item `id` (sent with `If-Match: baseEtag`) actually did.
    public enum ReplaceOutcome: Sendable, Equatable {
        case replaced
        /// The server answered with another item: the bytes became a new file (e.g. a TUS upload by
        /// name after the original moved away).
        case newItem
        /// The `OC-FileId` header was missing and the re-read found the item still at the base etag,
        /// so it is not known where the bytes went.
        case unconfirmed
    }

    /// `confirmed`: the upload response named the item (`OC-FileId`). Then an unchanged etag proves
    /// nothing: OpenCloud derives it from the whole-second mtime, so saves within one second keep it.
    public static func replaceOutcome(id: String, baseEtag: String, uploaded: RemoteItem,
                                      confirmed: Bool) -> ReplaceOutcome {
        if uploaded.id != id { return .newItem }
        if confirmed { return .replaced }
        let base = ETag.normalize(baseEtag)
        return !base.isEmpty && base == ETag.normalize(uploaded.etag) ? .unconfirmed : .replaced
    }

    /// The item to hand back after a `.replaced` upload. Its content version must differ from the
    /// base even when the server kept the etag (see `replaceOutcome`): the system caches thumbnails
    /// and decides on fetches by it. Then the etag gets a local `stamp`, which `ETag.normalize` drops.
    public static func replacedItem(_ uploaded: RemoteItem, baseEtag: String,
                                    stamp: String = UUID().uuidString) -> RemoteItem {
        let base = ETag.normalize(baseEtag)
        guard !base.isEmpty, base == ETag.normalize(uploaded.etag) else { return uploaded }
        var item = uploaded
        item.etag = ETag.stamped(uploaded.etag, stamp)
        return item
    }
}
