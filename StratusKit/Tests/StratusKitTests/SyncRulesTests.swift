import Foundation
import Testing
@testable import StratusKit

@Suite struct SyncRulesTests {
    @Test func excluded() {
        for name in [".DS_Store", "._foo", ".~lock.a.odt#", "~$doc.docx", "Icon\r", ".localized"] {
            #expect(SyncRules.isExcluded(name), "\(name.debugDescription) should be excluded")
        }
        for name in ["a.txt", ".env", "~notes.txt"] {
            #expect(!SyncRules.isExcluded(name), "\(name) should not be excluded")
        }
    }

    @Test func conflictName() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_793_201_400)  // 2026-10-28 15:30:00 UTC
        #expect(SyncRules.conflictName(for: "report.pdf", date: date, timeZone: utc) == "report (conflict 2026-10-28 1530).pdf")
        #expect(SyncRules.conflictName(for: "Makefile", date: date, timeZone: utc) == "Makefile (conflict 2026-10-28 1530)")
        #expect(SyncRules.conflictName(for: "archive.tar.gz", date: date, timeZone: utc) == "archive.tar (conflict 2026-10-28 1530).gz")
    }

    @Test func conflictNameUsesTimeZone() throws {
        let istanbul = try #require(TimeZone(identifier: "Europe/Istanbul"))  // UTC+3
        let date = Date(timeIntervalSince1970: 1_793_201_400)
        #expect(SyncRules.conflictName(for: "a.txt", date: date, timeZone: istanbul) == "a (conflict 2026-10-28 1830).txt")
    }

    @Test func replaceOutcome() {
        let old = RemoteItem(id: "s$p!a", parentId: "s$p!d", name: "a.txt", isFolder: false, etag: "e1")
        var edited = old; edited.etag = "e2"
        var elsewhere = edited; elsewhere.id = "s$p!b"
        for confirmed in [true, false] {
            #expect(SyncRules.replaceOutcome(id: old.id, baseEtag: "e1", uploaded: edited, confirmed: confirmed) == .replaced)
            #expect(SyncRules.replaceOutcome(id: old.id, baseEtag: "e1", uploaded: elsewhere, confirmed: confirmed) == .newItem)
            // Without a base etag there is nothing to compare.
            #expect(SyncRules.replaceOutcome(id: old.id, baseEtag: "", uploaded: old, confirmed: confirmed) == .replaced)
        }
        // The fallback re-read (no OC-FileId) found the old version: the bytes did not land on this item.
        #expect(SyncRules.replaceOutcome(id: old.id, baseEtag: "e1", uploaded: old, confirmed: false) == .unconfirmed)
        #expect(SyncRules.replaceOutcome(id: old.id, baseEtag: "W/\"e1\"", uploaded: old, confirmed: false) == .unconfirmed)
        #expect(SyncRules.replaceOutcome(id: old.id, baseEtag: ETag.stamped("e1", "s"), uploaded: old, confirmed: false) == .unconfirmed)
        // The response named this item: the bytes are on it, even though OpenCloud kept the etag
        // (it derives from the whole-second mtime, so saves within one second share it).
        #expect(SyncRules.replaceOutcome(id: old.id, baseEtag: "e1", uploaded: old, confirmed: true) == .replaced)
    }

    @Test func replacedItemAlwaysHasANewContentVersion() {
        let same = RemoteItem(id: "s$p!a", parentId: "s$p!d", name: "a.txt", isFolder: false, etag: "e1")
        var changed = same; changed.etag = "e2"
        // The etag moved: it is the new version as it is.
        #expect(SyncRules.replacedItem(changed, baseEtag: "e1", stamp: "s1") == changed)
        #expect(SyncRules.replacedItem(changed, baseEtag: ETag.stamped("e1", "s0"), stamp: "s1") == changed)
        // Same etag as the base: a local stamp makes the version differ, and the server etag stays readable.
        let stamped = SyncRules.replacedItem(same, baseEtag: "e1", stamp: "s1")
        #expect(stamped.etag != "e1")
        #expect(ETag.normalize(stamped.etag) == "e1")
        // A base that already carries a stamp gets a different one.
        let again = SyncRules.replacedItem(same, baseEtag: stamped.etag, stamp: "s2")
        #expect(again.etag != stamped.etag && ETag.normalize(again.etag) == "e1")
        // Unknown base: nothing to compare against.
        #expect(SyncRules.replacedItem(same, baseEtag: "", stamp: "s1") == same)
    }
}
