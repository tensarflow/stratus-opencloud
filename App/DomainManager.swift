import FileProvider
import os
import StratusKit

/// One File Provider domain per space (drive). Identifier = drive id.
@MainActor enum DomainManager {
    private static let log = Logger(subsystem: "com.arteq.stratus", category: "app")

    static func displayName(_ drive: Drive) -> String {
        drive.type == "personal" ? "Personal" : drive.name
    }

    /// Adds a domain for every drive without one. Removes a domain only on proof its space is gone
    /// (`DomainPolicy`): never one in `keep` (the personal space), and only after `exists` says 404.
    /// Returns where unsynced local files of removed domains were kept.
    static func reconcile(_ drives: [Drive], keep: Set<String>,
                          exists: @Sendable (String) async throws -> Bool) async throws -> [URL] {
        let existing = try await NSFileProviderManager.domains()
        let gone = await DomainPolicy.removable(domains: existing.map(\.identifier.rawValue),
                                                listed: Set(drives.map(\.id)), keep: keep, exists: exists)
        var preserved: [URL] = []
        for domain in existing where gone.contains(domain.identifier.rawValue) {
            if let kept = try await remove(domain) { preserved.append(kept) }
        }
        let have = Set(existing.map(\.identifier.rawValue))
        for drive in drives where !have.contains(drive.id) {
            // A new domain starts switched off until the user enables it; the caller signals it then.
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(drive.id),
                                              displayName: displayName(drive))
            try await NSFileProviderManager.add(domain)
            log.info("added domain for a \(drive.type, privacy: .public) space")
        }
        return preserved
    }

    static func removeAll() async throws -> [URL] {
        var preserved: [URL] = []
        for domain in try await NSFileProviderManager.domains() {
            if let kept = try await remove(domain) { preserved.append(kept) }
        }
        return preserved
    }

    /// Keeps local edits that have not reached the server, then drops the domain's item cache.
    /// Returns where the kept files are, if any.
    private static func remove(_ domain: NSFileProviderDomain) async throws -> URL? {
        let preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
        if let preserved {
            log.notice("unsynced local files of a removed space kept at \(preserved.path, privacy: .private)")
        }
        if let cache = try? AppGroup.cacheURL(driveId: domain.identifier.rawValue) {
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
        log.info("removed a domain")
        return preserved
    }

    /// Ids of domains the user switched off (or never on) in System Settings.
    static func userDisabledIds() async -> Set<String> {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return Set(domains.filter { !$0.userEnabled }.map(\.identifier.rawValue))
    }

    /// Throws File Provider error -2011 (`FPErrors.isDomainDisabled`) for a switched-off domain.
    static func signalWorkingSet(driveId: String) async throws {
        guard let domain = try await NSFileProviderManager.domains().first(where: { $0.identifier.rawValue == driveId })
        else { return }
        try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
    }

    static func signalAll() async {
        for domain in (try? await NSFileProviderManager.domains()) ?? [] {
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
        }
    }

    static func rootURL(driveId: String) async throws -> URL? {
        guard let domain = try await NSFileProviderManager.domains().first(where: { $0.identifier.rawValue == driveId })
        else { return nil }
        return try await NSFileProviderManager(for: domain)?.getUserVisibleURL(for: .rootContainer)
    }
}
