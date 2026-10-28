import Foundation

/// When the app may remove a space's File Provider domain. Removing one drops its Finder folder, so
/// a space goes only on proof: missing from the listing, not kept (the personal space never is
/// removed automatically), and answered 404 by the server. Any other answer keeps it.
public enum DomainPolicy {
    public static func removable(domains: [String], listed: Set<String>, keep: Set<String>,
                                 exists: @Sendable (String) async throws -> Bool) async -> [String] {
        var gone: [String] = []
        for id in domains where !listed.contains(id) && !keep.contains(id) {
            if let exists = try? await exists(id), !exists { gone.append(id) }
        }
        return gone
    }
}
