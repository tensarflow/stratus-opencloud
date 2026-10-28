import Foundation
import Testing
@testable import StratusKit

private let base = URL(string: "https://h")!
private let fileId = "S$P!new"

private func propfindBody(id: String = fileId, name: String = "new.txt") -> String {
    """
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:response>\
    <d:href>/dav/spaces/S$P/fp-test/\(name)</d:href><d:propstat><d:prop><d:resourcetype/>\
    <d:getetag>"e1"</d:getetag><oc:fileid>\(id)</oc:fileid><oc:file-parent>S$P!root</oc:file-parent>\
    <oc:permissions>RDNVWZP</oc:permissions><d:getcontentlength>5</d:getcontentlength>\
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
    """
}

private actor CountingAuth: AuthProvider {
    var refreshes = 0
    func authorizationHeader() async throws -> String { "Bearer t\(refreshes)" }
    func refreshAfterUnauthorized() async throws { refreshes += 1 }
}

private func makeClient(
    auth: AuthProvider = BasicAuthProvider(user: "u", token: "p"),
    limit: Int64 = OpenCloudClient.singlePutLimit, chunk: Int = OpenCloudClient.tusChunk
) -> OpenCloudClient {
    OpenCloudClient(baseURL: base, auth: auth, session: StubURLProtocol.session(),
                    singlePutLimit: limit, tusChunk: chunk)
}

/// A create (`replacing: nil`) opens with a PROPFIND on the child path (OpenCloud ignores `If-None-Match: *`).
/// This answers that first request "free" (404) and hands everything else to `inner`.
private func creating(_ inner: @escaping @Sendable (RecordedRequest) -> StubReply)
    -> @Sendable (RecordedRequest) -> StubReply {
    { r in r.method == "PROPFIND" && StubURLProtocol.requests.count == 1 ? StubReply(404) : inner(r) }
}

private func tempFile(_ bytes: Int, fill: UInt8 = 0x41) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: fill, count: bytes).write(to: url)
    return url
}

extension StubbedSuites {
@Suite struct OpenCloudClientTests {
    @Test func smallCreateUsesPutWithIfNoneMatch() async throws {
        StubURLProtocol.install(creating { r in
            r.method == "PUT" ? StubReply(201, headers: ["OC-FileId": fileId, "ETag": "\"e1\""])
                              : StubReply(207, body: propfindBody())
        })
        let file = try tempFile(5)
        let progress = Progress()
        let item = try await makeClient().upload(
            file, parentId: "S$P", name: "new.txt", replacing: nil,
            modified: Date(timeIntervalSince1970: 1_700_000_000), progress: progress)
        #expect(item.id == fileId)
        let reqs = StubURLProtocol.requests
        #expect(reqs.map(\.method) == ["PROPFIND", "PUT", "PROPFIND"])
        #expect(reqs[0].path == "/dav/spaces/S$P/new.txt")   // existence check
        #expect(reqs[0].header("Depth") == "0")
        let put = reqs[1]
        #expect(put.method == "PUT")
        #expect(put.path == "/dav/spaces/S$P/new.txt")
        #expect(put.header("If-None-Match") == "*")
        #expect(put.header("If-Match") == nil)
        #expect(put.header("Content-Length") == "5")
        #expect(put.header("X-OC-Mtime") == "1700000000")
        #expect(put.header("Authorization")?.hasPrefix("Basic ") == true)
        #expect(put.body?.count == 5)
        #expect(reqs[2].path == "/dav/spaces/S$P!new")
        #expect(reqs[2].header("Depth") == "0")
        #expect(progress.totalUnitCount == 5)
        #expect(progress.completedUnitCount == 5)
    }

    // OpenCloud answers a zero-length PUT with 400 (verified live), so empty files use TUS creation only.
    @Test func emptyFileUploadsViaTUSCreationOnly() async throws {
        StubURLProtocol.install(creating { r in
            r.method == "POST" ? StubReply(201, headers: ["Location": ""]) : StubReply(207, body: propfindBody())
        })
        let item = try await makeClient().upload(
            try tempFile(0), parentId: "S$P", name: "empty", replacing: nil, modified: nil, progress: nil)
        #expect(item.id == fileId)
        let reqs = StubURLProtocol.requests
        #expect(reqs.map(\.method) == ["PROPFIND", "POST", "PROPFIND"])
        #expect(reqs[1].path == "/dav/spaces/S$P")
        #expect(reqs[1].header("Upload-Length") == "0")
        #expect(reqs[1].header("X-OC-Mtime") != nil)
        #expect(reqs[2].path == "/dav/spaces/S$P/empty")   // no OC-FileId on creation -> child PROPFIND
    }

    @Test func emptyReplaceCarriesIfMatch() async throws {
        StubURLProtocol.install { r in
            r.method == "POST" ? StubReply(201) : StubReply(207, body: propfindBody())
        }
        _ = try await makeClient().upload(
            try tempFile(0), parentId: "S$P", name: "empty", replacing: (id: fileId, etag: "e1"),
            modified: nil, progress: nil)
        let reqs = StubURLProtocol.requests
        #expect(reqs.map(\.method) == ["POST", "PROPFIND"])
        #expect(reqs[0].header("If-Match") == "\"e1\"")
        #expect(reqs[1].path == "/dav/spaces/\(fileId)")   // replace: PROPFIND the existing id
    }

    @Test func replaceSendsIfMatchAndMaps412() async throws {
        StubURLProtocol.install { _ in StubReply(412) }
        await #expect(throws: OpenCloudError.preconditionFailed) {
            try await makeClient().upload(
                try tempFile(3), parentId: "S$P", name: "a.txt", replacing: (id: "S$P!old", etag: "abc"),
                modified: nil, progress: nil)
        }
        let put = StubURLProtocol.requests[0]
        #expect(put.method == "PUT")
        #expect(put.path == "/dav/spaces/S$P!old")
        #expect(put.header("If-Match") == "\"abc\"")
        #expect(put.header("If-None-Match") == nil)
    }

    // OpenCloud ignores `If-None-Match: *` (verified live), so a create looks before it uploads.
    @Test func createChecksExistenceFirst() async throws {
        StubURLProtocol.install { _ in StubReply(207, body: propfindBody()) }
        for size in [0, 3] {
            await #expect(throws: OpenCloudError.preconditionFailed) {
                try await makeClient().upload(
                    try tempFile(size), parentId: "S$P", name: "a.txt", replacing: nil, modified: nil, progress: nil)
            }
        }
        await #expect(throws: OpenCloudError.preconditionFailed) {      // TUS route
            try await makeClient(limit: 2, chunk: 4).upload(
                try tempFile(3), parentId: "S$P", name: "a.txt", replacing: nil, modified: nil, progress: nil)
        }
        // Three attempts, one existence check each, and nothing was uploaded.
        #expect(StubURLProtocol.requests.map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND"])
    }

    @Test func createProceedsWhen404() async throws {
        StubURLProtocol.install(creating { r in
            r.method == "PUT" ? StubReply(201, headers: ["OC-FileId": fileId]) : StubReply(207, body: propfindBody())
        })
        _ = try await makeClient().upload(
            try tempFile(3), parentId: "S$P", name: "a.txt", replacing: nil, modified: nil, progress: nil)
        #expect(StubURLProtocol.requests.map(\.method) == ["PROPFIND", "PUT", "PROPFIND"])
    }

    @Test func replaceSkipsExistenceCheck() async throws {
        StubURLProtocol.install { r in
            r.method == "PUT" ? StubReply(204, headers: ["OC-FileId": fileId]) : StubReply(207, body: propfindBody())
        }
        _ = try await makeClient().upload(
            try tempFile(3), parentId: "S$P", name: "a.txt", replacing: (id: fileId, etag: "e1"),
            modified: nil, progress: nil)
        #expect(StubURLProtocol.requests.map(\.method) == ["PUT", "PROPFIND"])
    }

    /// `confirmed`: the response named the uploaded item (`OC-FileId`), so the item that comes back is
    /// where the bytes went, not a fallback re-read.
    @Test func uploadReportsWhetherTheServerNamedTheItem() async throws {
        func put(fileIdHeader: Bool, size: Int = 3, limit: Int64 = OpenCloudClient.singlePutLimit) async throws -> Bool {
            StubURLProtocol.install { r in
                switch r.method {
                case "PUT", "PATCH":
                    var h = ["Upload-Offset": "\(size)"]
                    if fileIdHeader { h["OC-FileId"] = fileId }
                    return StubReply(204, headers: h)
                case "POST": return StubReply(201, headers: ["Location": "https://h/data/x"])
                default: return StubReply(207, body: propfindBody())
                }
            }
            let result = try await makeClient(limit: limit, chunk: 16).uploadConfirming(
                try tempFile(size), parentId: "S$P", name: "a.txt", replacing: (id: fileId, etag: "e1"),
                modified: nil, progress: nil)
            #expect(result.item.id == fileId)
            return result.confirmed
        }
        #expect(try await put(fileIdHeader: true))
        #expect(try await put(fileIdHeader: false) == false)
        #expect(try await put(fileIdHeader: true, size: 10, limit: 9))            // TUS: final PATCH
        #expect(try await put(fileIdHeader: false, size: 10, limit: 9) == false)
        #expect(try await put(fileIdHeader: false, size: 0) == false)              // TUS creation only
    }

    @Test func createPutWith412IsPreconditionFailed() async throws {
        // A future server that does honor If-None-Match: * still maps its 412.
        StubURLProtocol.install(creating { _ in StubReply(412) })
        await #expect(throws: OpenCloudError.preconditionFailed) {
            try await makeClient().upload(
                try tempFile(3), parentId: "S$P", name: "a.txt", replacing: nil, modified: nil, progress: nil)
        }
    }

    @Test func largeUploadUsesTUS() async throws {
        let location = "https://drive.example/data/jwt.abc"
        StubURLProtocol.install(creating { r in
            switch r.method {
            case "POST": return StubReply(201, headers: ["Location": location])
            case "PATCH":
                let off = Int(r.header("Upload-Offset")!)!
                let len = Int(r.header("Content-Length")!)!
                var h = ["Upload-Offset": "\(off + len)"]
                if off + len == 10 { h["OC-FileId"] = fileId }
                return StubReply(204, headers: h)
            default: return StubReply(207, body: propfindBody())
            }
        })
        let file = try tempFile(10)
        let progress = Progress()
        let item = try await makeClient(limit: 9, chunk: 4).upload(
            file, parentId: "S$P", name: "Ödev Çağlayan.bin", replacing: nil,
            modified: Date(timeIntervalSince1970: 1_700_000_000), progress: progress)
        #expect(item.id == fileId)
        let reqs = StubURLProtocol.requests
        #expect(reqs.map(\.method) == ["PROPFIND", "POST", "PATCH", "PATCH", "PATCH", "PROPFIND"])
        let post = reqs[1]
        #expect(post.path == "/dav/spaces/S$P")
        #expect(post.header("Tus-Resumable") == "1.0.0")
        #expect(post.header("Upload-Length") == "10")
        #expect(post.header("If-Match") == nil)
        #expect(post.header("X-OC-Mtime") == "1700000000")
        let meta = try #require(post.header("Upload-Metadata"))
        let nameB64 = Data("Ödev Çağlayan.bin".precomposedStringWithCanonicalMapping.utf8).base64EncodedString()
        let mtimeB64 = Data("1700000000".utf8).base64EncodedString()
        #expect(meta == "filename \(nameB64),mtime \(mtimeB64)")
        let patches = Array(reqs[2...4])
        #expect(patches.map { $0.header("Upload-Offset") } == ["0", "4", "8"])
        #expect(patches.map { $0.header("Content-Length") } == ["4", "4", "2"])
        for p in patches {
            #expect(p.url.absoluteString == location)
            #expect(p.header("Content-Type") == "application/offset+octet-stream")
            #expect(p.header("Tus-Resumable") == "1.0.0")
            #expect(p.header("Authorization") == nil)       // another host: the token stays home
        }
        #expect(patches.map { $0.body?.count } == [4, 4, 2])
        #expect(progress.totalUnitCount == 10)
        #expect(progress.completedUnitCount == 10)
    }

    /// The bearer token goes to a TUS `Location` only on the server's own host, over https or the
    /// base URL's own scheme.
    @Test func tusAuthorizationOnlyForTheServerHost() async throws {
        func patchAuth(_ location: String) async throws -> String? {
            StubURLProtocol.install(creating { r in
                switch r.method {
                case "POST": return StubReply(201, headers: ["Location": location])
                case "PATCH": return StubReply(204, headers: ["Upload-Offset": "10", "OC-FileId": fileId])
                default: return StubReply(207, body: propfindBody())
                }
            })
            _ = try await makeClient(limit: 9, chunk: 16).upload(
                try tempFile(10), parentId: "S$P", name: "a.bin", replacing: nil, modified: nil, progress: nil)
            return try #require(StubURLProtocol.requests.first { $0.method == "PATCH" }).header("Authorization")
        }
        #expect(try await patchAuth("https://h/data/x")?.hasPrefix("Basic ") == true)
        #expect(try await patchAuth("/data/x")?.hasPrefix("Basic ") == true)      // relative: resolved against base
        #expect(try await patchAuth("https://elsewhere.example/data/x") == nil)
        #expect(try await patchAuth("https://h.evil.example/data/x") == nil)
        #expect(try await patchAuth("http://h/data/x") == nil)                     // downgrade to plain http
    }

    @Test func tusFallsBackToChildPropfindWithoutFileId() async throws {
        StubURLProtocol.install(creating { r in
            switch r.method {
            case "POST": return StubReply(201, headers: ["Location": "https://drive.example/data/x"])
            case "PATCH": return StubReply(204, headers: ["Upload-Offset": "10"])
            default: return StubReply(207, body: propfindBody())
            }
        })
        _ = try await makeClient(limit: 9, chunk: 16).upload(
            try tempFile(10), parentId: "S$P", name: "b c.bin", replacing: nil, modified: nil, progress: nil)
        let last = try #require(StubURLProtocol.requests.last)
        #expect(last.method == "PROPFIND")
        #expect(last.path == "/dav/spaces/S$P/b%20c.bin")
    }

    @Test func tusReplaceCarriesIfMatch() async throws {
        StubURLProtocol.install { r in
            switch r.method {
            case "POST": return StubReply(201, headers: ["Location": "https://drive.example/data/x"])
            case "PATCH": return StubReply(204, headers: ["Upload-Offset": "10", "OC-FileId": fileId])
            default: return StubReply(207, body: propfindBody())
            }
        }
        _ = try await makeClient(limit: 9, chunk: 16).upload(
            try tempFile(10), parentId: "S$P", name: "a.bin", replacing: (id: "S$P!old", etag: "zzz"),
            modified: nil, progress: nil)
        #expect(StubURLProtocol.requests[0].method == "POST")
        #expect(StubURLProtocol.requests[0].header("If-Match") == "\"zzz\"")
    }

    @Test func unauthorizedRefreshesOnceAndRetries() async throws {
        StubURLProtocol.install(sequence: [StubReply(401), StubReply(207, body: propfindBody())])
        let auth = CountingAuth()
        let item = try await makeClient(auth: auth).item(fileId)
        #expect(item.id == fileId)
        #expect(await auth.refreshes == 1)
        let reqs = StubURLProtocol.requests
        #expect(reqs.count == 2)
        #expect(reqs[0].header("Authorization") == "Bearer t0")
        #expect(reqs[1].header("Authorization") == "Bearer t1")
    }

    @Test func second401Throws() async throws {
        StubURLProtocol.install { _ in StubReply(401) }
        let auth = CountingAuth()
        await #expect(throws: OpenCloudError.unauthorized) { try await makeClient(auth: auth).item(fileId) }
        #expect(StubURLProtocol.requests.count == 2)
        #expect(await auth.refreshes == 1)
    }

    @Test func unauthorizedRetryResendsFileBody() async throws {
        StubURLProtocol.install(creating { r in
            if r.method == "PUT" { return StubReply(StubURLProtocol.requests.filter { $0.method == "PUT" }.count == 1 ? 401 : 201,
                                                    headers: ["OC-FileId": fileId]) }
            return StubReply(207, body: propfindBody())
        })
        let auth = CountingAuth()
        _ = try await makeClient(auth: auth).upload(
            try tempFile(5), parentId: "S$P", name: "new.txt", replacing: nil, modified: nil, progress: nil)
        let puts = StubURLProtocol.requests.filter { $0.method == "PUT" }
        #expect(puts.count == 2)
        #expect(puts.allSatisfy { $0.header("Content-Length") == "5" })
        #expect(puts.map { $0.body?.count } == [5, 5])
    }

    @Test func moveDestinationHeader() async throws {
        StubURLProtocol.install { r in
            r.method == "MOVE" ? StubReply(201, headers: ["OC-FileId": fileId]) : StubReply(207, body: propfindBody())
        }
        _ = try await makeClient().move("S$P!x", toParent: "NEWP", name: "b c.txt")
        let mv = StubURLProtocol.requests[0]
        #expect(mv.method == "MOVE")
        #expect(mv.path == "/dav/spaces/S$P!x")
        #expect(mv.header("Destination") == "https://h/dav/spaces/NEWP/b%20c.txt")
        #expect(mv.header("Overwrite") == "F")
    }

    @Test func move412MapsAlreadyExists() async throws {
        StubURLProtocol.install { _ in StubReply(412) }
        await #expect(throws: OpenCloudError.alreadyExists) {
            try await makeClient().move("S$P!x", toParent: "NEWP", name: "b")
        }
    }

    @Test func moveWithoutFileIdHeaderPropfindsChild() async throws {
        StubURLProtocol.install { r in r.method == "MOVE" ? StubReply(201) : StubReply(207, body: propfindBody()) }
        _ = try await makeClient().move("S$P!x", toParent: "NEWP", name: "b")
        let last = try #require(StubURLProtocol.requests.last)
        #expect(last.method == "PROPFIND")
        #expect(last.path == "/dav/spaces/NEWP/b")
    }

    @Test func mkcol405MapsAlreadyExists() async throws {
        StubURLProtocol.install { _ in StubReply(405) }
        await #expect(throws: OpenCloudError.alreadyExists) {
            try await makeClient().createFolder(in: "S$P", name: "dir")
        }
        #expect(StubURLProtocol.requests[0].method == "MKCOL")
        #expect(StubURLProtocol.requests[0].path == "/dav/spaces/S$P/dir")
    }

    @Test func createFolderReturnsItem() async throws {
        StubURLProtocol.install { r in
            r.method == "MKCOL" ? StubReply(201, headers: ["OC-FileId": fileId]) : StubReply(207, body: propfindBody())
        }
        let item = try await makeClient().createFolder(in: "S$P", name: "dir")
        #expect(item.id == fileId)
    }

    @Test func namesAreNormalizedToNFC() async throws {
        StubURLProtocol.install { r in r.method == "MKCOL" ? StubReply(201) : StubReply(207, body: propfindBody()) }
        let nfd = "Ozkaya\u{0308}"   // u + combining diaeresis
        _ = try await makeClient().createFolder(in: "S$P", name: nfd)
        #expect(StubURLProtocol.requests[0].path == "/dav/spaces/S$P/Ozkay%C3%A4")
    }

    @Test func drivesParsesGraph() async throws {
        StubURLProtocol.install { _ in
            StubReply(200, body: #"{"value":[{"id":"S$P","name":"Personal","driveType":"personal","root":{"eTag":"\"abc\""}},{"id":"S$Q","name":"Proj","driveType":"project"}]}"#)
        }
        let drives = try await makeClient().drives()
        #expect(drives == [Drive(id: "S$P", name: "Personal", type: "personal", rootEtag: "abc"),
                           Drive(id: "S$Q", name: "Proj", type: "project", rootEtag: "")])
        #expect(StubURLProtocol.requests[0].path == "/graph/v1.0/me/drives")
        #expect(StubURLProtocol.requests[0].method == "GET")
    }

    @Test func driveExistsAsksGraph() async throws {
        StubURLProtocol.install { r in r.path.hasSuffix("gone") ? StubReply(404) : StubReply(200, body: #"{"id":"S$Q"}"#) }
        #expect(try await makeClient().driveExists("S$Q"))
        #expect(StubURLProtocol.requests[0].path == "/graph/v1.0/drives/S$Q")
        #expect(StubURLProtocol.requests[0].method == "GET")
        #expect(try await makeClient().driveExists("S$gone") == false)
        // Anything but a 404 is not proof the space is gone.
        StubURLProtocol.install { _ in StubReply(503) }
        await #expect(throws: OpenCloudError.server(503)) { try await makeClient().driveExists("S$Q") }
        StubURLProtocol.install { _ in StubReply(403) }
        await #expect(throws: OpenCloudError.forbidden) { try await makeClient().driveExists("S$Q") }
    }

    @Test func meReadsSamAccountName() async throws {
        StubURLProtocol.install { _ in StubReply(200, body: #"{"onPremisesSamAccountName":"alice","id":"1"}"#) }
        #expect(try await makeClient().me() == "alice")
        #expect(StubURLProtocol.requests[0].path == "/graph/v1.0/me")
    }

    @Test func propfindRequestsOcName() async throws {
        StubURLProtocol.install { _ in StubReply(207, body: propfindBody()) }
        _ = try await makeClient().item(fileId)
        let body = String(decoding: try #require(StubURLProtocol.requests.first?.body), as: UTF8.self)
        #expect(body.contains("<oc:name/>"))
    }

    @Test func childrenSplitsFolderFromChildren() async throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "propfind-depth1", withExtension: "xml", subdirectory: "Fixtures"))
        let xml = try Data(contentsOf: fixture)
        StubURLProtocol.install { _ in StubReply(207, body: String(decoding: xml, as: UTF8.self)) }
        let result = try await makeClient().children(of: "S$P!x")
        #expect(result.folder.name == "fp-test")
        #expect(result.children.count == 5)
        let req = StubURLProtocol.requests[0]
        #expect(req.method == "PROPFIND")
        #expect(req.header("Depth") == "1")
        #expect(req.header("Content-Type") == "application/xml")
        let body = String(decoding: req.body ?? Data(), as: UTF8.self)
        #expect(body.contains("fileid") && body.contains("file-parent") && body.contains("getetag"))
    }

    @Test func deleteSendsDelete() async throws {
        StubURLProtocol.install { _ in StubReply(204) }
        try await makeClient().delete("S$P!x")
        #expect(StubURLProtocol.requests[0].method == "DELETE")
        #expect(StubURLProtocol.requests[0].path == "/dav/spaces/S$P!x")
    }

    @Test func downloadWritesFileAndReturnsEtag() async throws {
        StubURLProtocol.install { _ in StubReply(200, headers: ["ETag": "\"e9\""], body: "hello") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("old".utf8).write(to: dest)
        let etag = try await makeClient().download("S$P!x", to: dest, progress: nil)
        #expect(etag == "e9")
        #expect(try String(contentsOf: dest, encoding: .utf8) == "hello")
    }

    @Test func downloadNormalizesWeakEtag() async throws {
        StubURLProtocol.install { _ in StubReply(200, headers: ["ETag": "W/\"x\""], body: "hi") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try await makeClient().download("S$P!x", to: dest, progress: nil) == "x")
    }

    @Test func download404MapsNotFound() async throws {
        StubURLProtocol.install { _ in StubReply(404) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: OpenCloudError.notFound) {
            try await makeClient().download("S$P!x", to: dest, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: Thumbnails

    @Test func thumbnailReturnsImageData() async throws {
        StubURLProtocol.install { _ in StubReply(200, headers: ["Content-Type": "image/jpeg"], body: "JPEG") }
        let data = try await makeClient().thumbnail("S$P!x y", width: 256, height: 128)
        #expect(data == Data("JPEG".utf8))
        let req = try #require(StubURLProtocol.requests.first)
        #expect(StubURLProtocol.requests.count == 1)
        #expect(req.method == "GET")
        #expect(req.url.absoluteString == "https://h/dav/spaces/S$P!x%20y?preview=1&x=256&y=128&a=1")
        #expect(req.header("Authorization")?.hasPrefix("Basic ") == true)
    }

    /// No preview for the type is not an error: the system shows the generic icon.
    @Test func thumbnailWithoutPreviewIsNil() async throws {
        for status in [404, 415, 501] {
            StubURLProtocol.install { _ in StubReply(status) }
            #expect(try await makeClient().thumbnail("S$P!x", width: 64, height: 64) == nil)
        }
    }

    @Test func thumbnailOtherErrorsThrow() async throws {
        StubURLProtocol.install { _ in StubReply(500) }
        await #expect(throws: OpenCloudError.server(500)) {
            try await makeClient().thumbnail("S$P!x", width: 64, height: 64)
        }
        StubURLProtocol.install { _ in StubReply(403) }
        await #expect(throws: OpenCloudError.forbidden) {
            try await makeClient().thumbnail("S$P!x", width: 64, height: 64)
        }
    }

    @Test func statusMapping() {
        #expect(OpenCloudError(status: 200) == nil)
        #expect(OpenCloudError(status: 403) == .forbidden)
        #expect(OpenCloudError(status: 413) == .tooLarge)
        #expect(OpenCloudError(status: 507) == .insufficientStorage)
        #expect(OpenCloudError(status: 503) == .server(503))
    }
}
}
