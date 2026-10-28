import Foundation

/// One folder's fresh listing against its cached children: which children are new or changed
/// (etag, name or parent differ) and which cached children are gone from the listing. A missing
/// child may have moved elsewhere; the caller decides. A cached etag's local stamp is kept while
/// the server etag is the same (`ETag.keepingStamp`).
public enum FolderDiff {
    public static func compare(cached: [RemoteItem], fresh: [RemoteItem]) -> (changed: [RemoteItem], missing: [String]) {
        let old = Dictionary(cached.map { ($0.id, $0) }) { a, _ in a }
        let freshIds = Set(fresh.map(\.id))
        let changed = fresh.map { item in
            var item = item
            item.etag = ETag.keepingStamp(item.etag, from: old[item.id]?.etag)
            return item
        }.filter { item in
            guard let was = old[item.id] else { return true }
            return was.etag != item.etag || was.name != item.name || was.parentId != item.parentId
        }
        return (changed, cached.map(\.id).filter { !freshIds.contains($0) })
    }
}
