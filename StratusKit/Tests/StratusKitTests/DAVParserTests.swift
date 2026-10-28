import Foundation
import Testing
@testable import StratusKit

private let space = "11111111-1111-4111-8111-111111111111$22222222-2222-4222-8222-222222222222"

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct DAVParserTests {
    @Test func parsesFolderAndChildren() throws {
        let items = try DAVParser.parse(fixture("propfind-depth1"))
        let folder = items[0]
        #expect(folder.isFolder)
        #expect(folder.name == "fp-test")
        #expect(folder.id == "\(space)!33333333-3333-4333-8333-333333333333")

        let file = try #require(items.first { $0.name == "a.txt" })
        #expect(file.id == "\(space)!44444444-4444-4444-8444-444444444444")
        #expect(file.parentId == folder.id)
        #expect(!file.isFolder)
        #expect(file.etag == "4232480bf2c6fe704dd76472ee8dce22")
        #expect(file.size == 5)
        #expect(file.contentType == "text/plain")
        #expect(file.permissions.contains(.delete))
        #expect(file.modified == Date(timeIntervalSince1970: 1_793_187_916))  // Wed, 28 Oct 2026 11:45:16 GMT

        let sub = try #require(items.first { $0.name == "sub" })
        #expect(sub.isFolder)
        #expect(sub.contentType == nil)  // 404 propstat is ignored
    }

    @Test func hrefPercentDecodingIsNotUsedForNames() throws {
        let items = try DAVParser.parse(fixture("propfind-depth1"))
        let names = Set(items.map(\.name))
        #expect(names.contains("Ö ş #1 100% a+b?.txt"))
        #expect(names.contains("wow!.txt"))
    }

    @Test func ocNameWinsOverHref() throws {
        // PROPFIND addressed by file id: the href's last segment is the id, not the name.
        let xml = #"""
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:response>
            <d:href>/dav/spaces/s$x%21abc</d:href><d:propstat><d:prop><oc:name>Ödev Çağlayan #1.txt</oc:name>
            <oc:fileid>s$x!abc</oc:fileid><d:getetag>"e"</d:getetag></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
            """#
        let item = try #require(try DAVParser.parse(Data(xml.utf8)).first)
        #expect(item.id == "s$x!abc")
        #expect(item.name == "Ödev Çağlayan #1.txt")
    }

    @Test func weakEtagIsNormalized() throws {
        let xml = #"""
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:response>
            <d:href>/dav/spaces/s$x%21abc</d:href><d:propstat><d:prop><oc:name>a.txt</oc:name>
            <oc:fileid>s$x!abc</oc:fileid><d:getetag>W/"x"</d:getetag></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
            """#
        #expect(try DAVParser.parse(Data(xml.utf8)).first?.etag == "x")
    }

    @Test func etagNormalize() {
        #expect(ETag.normalize("\"abc\"") == "abc")
        #expect(ETag.normalize("W/\"abc\"") == "abc")
        #expect(ETag.normalize("abc") == "abc")
        #expect(ETag.normalize(" W/\"a\" ") == "a")
        #expect(ETag.normalize("") == "")
    }

    @Test func etagStaleness() {
        #expect(!ETag.isStale(base: Data("abc".utf8), current: "abc"))
        #expect(!ETag.isStale(base: Data("abc".utf8), current: "W/\"abc\""))
        #expect(ETag.isStale(base: Data("abc".utf8), current: "abd"))
        #expect(!ETag.isStale(base: Data(), current: "abc"))       // unknown base: never stale
        #expect(!ETag.isStale(base: Data(ETag.stamped("abc", "s").utf8), current: "abc"))
        #expect(ETag.isStale(base: Data(ETag.stamped("abc", "s").utf8), current: "abd"))
    }

    /// A local content stamp rides on a stored etag but never reaches the server or a comparison.
    @Test func etagStamp() {
        let stamped = ETag.stamped("W/\"abc\"", "s1")
        #expect(stamped != "abc")
        #expect(ETag.normalize(stamped) == "abc")
        #expect(ETag.stamped("abc", "s1") != ETag.stamped("abc", "s2"))
        // A fresh server etag keeps the cached stamp only while the server etag is the same.
        #expect(ETag.keepingStamp("abc", from: stamped) == stamped)
        #expect(ETag.keepingStamp("abd", from: stamped) == "abd")
        #expect(ETag.keepingStamp("abc", from: "abc") == "abc")
        #expect(ETag.keepingStamp("abc", from: nil) == "abc")
    }

    @Test func parseLargeListingFast() throws {
        var xml = #"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">"#
        for i in 0..<5000 {
            xml += """
            <d:response><d:href>/dav/spaces/s$x!p/f\(i).txt</d:href><d:propstat><d:prop>\
            <d:resourcetype/><d:getetag>"e\(i)"</d:getetag><oc:fileid>s$x!\(i)</oc:fileid>\
            <oc:file-parent>s$x!p</oc:file-parent><oc:permissions>RDNVW</oc:permissions>\
            <oc:size>\(i)</oc:size><d:getlastmodified>Wed, 28 Oct 2026 11:45:16 GMT</d:getlastmodified>\
            <d:getcontenttype>text/plain</d:getcontenttype></d:prop><d:status>HTTP/1.1 200 OK</d:status>\
            </d:propstat></d:response>
            """
        }
        xml += "</d:multistatus>"
        let data = Data(xml.utf8)
        let start = ContinuousClock.now
        let items = try DAVParser.parse(data)
        let elapsed = ContinuousClock.now - start
        #expect(items.count == 5000)
        #expect(items[4999].size == 4999)
        #expect(elapsed < .seconds(1))
    }

    @Test func permissionsLetters() {
        // A folder's letters carry no W (that one is the file-update right); a file's carry no C/K.
        let folder = ItemPermissions(ocString: "RDNVCKZP")
        for p: ItemPermissions in [.share, .delete, .rename, .move, .createFile, .createFolder] {
            #expect(folder.contains(p))
        }
        #expect(!folder.contains(.write))
        let file = ItemPermissions(ocString: "RDNVWZP")
        #expect(file.contains(.write))
        #expect(!file.contains(.createFile))
        #expect(ItemPermissions(ocString: "R") == .share)  // Z, P and unknown letters are ignored
        #expect(ItemPermissions(ocString: "") == [])
    }

    @Test func childURLEncoding() {
        let url = DAVPaths.child("s$x!y", name: "a b#%?.txt", base: URL(string: "https://h")!)
        #expect(url.absoluteString == "https://h/dav/spaces/s$x!y/a%20b%23%25%3F.txt")
    }

    @Test func itemURLAndPlusAndUnicode() {
        let base = URL(string: "https://h")!
        #expect(DAVPaths.item("s$x!y", base: base).absoluteString == "https://h/dav/spaces/s$x!y")
        #expect(DAVPaths.child("p", name: "a+b Ö.txt", base: base).absoluteString == "https://h/dav/spaces/p/a%2Bb%20%C3%96.txt")
    }
}
