import Foundation

public protocol RemoteLister: Sendable {
    func item(_ id: String) async throws -> RemoteItem
    func children(of id: String) async throws -> (folder: RemoteItem, children: [RemoteItem])
}

/// Graph + WebDAV client. Everything goes through `perform`, which adds auth and retries once on 401.
public final class OpenCloudClient: RemoteLister, Sendable {
    public static let singlePutLimit: Int64 = 64 << 20
    public static let tusChunk = 32 << 20

    let baseURL: URL
    let auth: AuthProvider
    let session: URLSession
    let putLimit: Int64
    let chunkSize: Int

    public convenience init(baseURL: URL, auth: AuthProvider, session: URLSession = .shared) {
        self.init(baseURL: baseURL, auth: auth, session: session,
                  singlePutLimit: Self.singlePutLimit, tusChunk: Self.tusChunk)
    }

    init(baseURL: URL, auth: AuthProvider, session: URLSession, singlePutLimit: Int64, tusChunk: Int) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
        self.putLimit = singlePutLimit
        self.chunkSize = tusChunk
    }

    // MARK: Graph

    public func drives() async throws -> [Drive] {
        struct Reply: Decodable {
            struct D: Decodable {
                struct Root: Decodable { var eTag: String? }
                var id: String, name: String, driveType: String?
                var root: Root?
            }
            var value: [D]
        }
        let reply = try await graph("me/drives", as: Reply.self)
        return reply.value.map {
            Drive(id: $0.id, name: $0.name, type: $0.driveType ?? "",
                  rootEtag: ETag.normalize($0.root?.eTag ?? ""))
        }
    }

    public func me() async throws -> String {
        struct Reply: Decodable { var onPremisesSamAccountName: String? }
        guard let name = try await graph("me", as: Reply.self).onPremisesSamAccountName else {
            throw OpenCloudError.invalidResponse
        }
        return name
    }

    /// Whether the space still exists: `false` only on a 404. Any other failure throws, because it
    /// proves nothing (callers keep the space).
    public func driveExists(_ id: String) async throws -> Bool {
        do {
            _ = try await send(request("GET", graphURL("drives/" + DAVPaths.escapedId(id))))
            return true
        } catch OpenCloudError.notFound {
            return false
        }
    }

    private func graph<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (data, _) = try await send(request("GET", graphURL(path)))
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw OpenCloudError.invalidResponse }
    }

    private func graphURL(_ path: String) -> URL {
        URL(string: baseURL.absoluteString.trimmingSlashes + "/graph/v1.0/" + path)!
    }

    // MARK: WebDAV reads

    public func item(_ id: String) async throws -> RemoteItem {
        try await propfind(DAVPaths.item(id, base: baseURL), depth: 0).first.orThrow()
    }

    public func children(of id: String) async throws -> (folder: RemoteItem, children: [RemoteItem]) {
        let parsed = try await propfind(DAVPaths.item(id, base: baseURL), depth: 1)
        guard let folder = parsed.first else { throw OpenCloudError.invalidResponse }
        return (folder, Array(parsed.dropFirst()))
    }

    private static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>\
        <d:resourcetype/><d:getetag/><oc:name/><oc:fileid/><oc:file-parent/><oc:permissions/><oc:size/>\
        <d:getcontentlength/><d:getlastmodified/><d:getcontenttype/></d:prop></d:propfind>
        """.utf8)

    func propfind(_ url: URL, depth: Int) async throws -> [RemoteItem] {
        let req = request("PROPFIND", url, ["Depth": "\(depth)", "Content-Type": "application/xml"])
        let (data, _) = try await send(req, .data(Self.propfindBody))
        do { return try DAVParser.parse(data) } catch { throw OpenCloudError.invalidResponse }
    }

    /// Streams the body to `dest` (replacing it) and returns the ETag of those bytes.
    public func download(_ id: String, to dest: URL, progress: Progress?) async throws -> String {
        let req = request("GET", DAVPaths.item(id, base: baseURL))
        let (tmp, http) = try await perform(req) { r in
            let (url, response) = try await self.session.download(for: r)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                try? FileManager.default.removeItem(at: url)
            }
            return (url, response)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        if let progress {
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            progress.totalUnitCount = size
            progress.completedUnitCount = size
        }
        return ETag.normalize(http.value(forHTTPHeaderField: "ETag") ?? "")
    }

    // MARK: WebDAV writes

    public func createFolder(in parentId: String, name: String) async throws -> RemoteItem {
        let name = name.precomposedStringWithCanonicalMapping
        let url = DAVPaths.child(parentId, name: name, base: baseURL)
        let (_, http) = try await send(request("MKCOL", url))
        return try await finalItem(http, fallback: url).item
    }

    public func upload(_ file: URL, parentId: String, name: String, replacing existing: (id: String, etag: String)?,
                       modified: Date?, progress: Progress?) async throws -> RemoteItem {
        try await uploadConfirming(file, parentId: parentId, name: name, replacing: existing,
                                   modified: modified, progress: progress).item
    }

    /// `upload`, plus whether the response named the resulting item (`OC-FileId`). Without it the
    /// item is a re-read of the replaced id (or of the name), which need not be where the bytes went.
    public func uploadConfirming(_ file: URL, parentId: String, name: String,
                                 replacing existing: (id: String, etag: String)?, modified: Date?,
                                 progress: Progress?) async throws -> (item: RemoteItem, confirmed: Bool) {
        let name = name.precomposedStringWithCanonicalMapping
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int((modified ?? (attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
        progress?.totalUnitCount = size
        progress?.completedUnitCount = 0

        let childURL = DAVPaths.child(parentId, name: name, base: baseURL)
        // OpenCloud ignores `If-None-Match: *` on PUT and on TUS creation (verified live) and would overwrite,
        // so a create checks for the name first. Racy by nature, but it never clobbers a file we can see.
        if existing == nil { try await requireAbsent(childURL) }
        let fallback = existing.map { DAVPaths.item($0.id, base: baseURL) } ?? childURL
        let http: HTTPURLResponse
        // A zero-length PUT is answered 400 by OpenCloud (verified live, also via Cloudflare), so empty
        // files go through TUS creation, which needs no PATCH.
        if size > 0, size <= putLimit {
            let url = existing.map { DAVPaths.item($0.id, base: baseURL) } ?? childURL
            var headers = ["Content-Length": "\(size)", "X-OC-Mtime": "\(mtime)"]
            if let existing { headers["If-Match"] = "\"\(existing.etag)\"" } else { headers["If-None-Match"] = "*" }
            (_, http) = try await send(request("PUT", url, headers), .file(file))
            progress?.completedUnitCount = size
        } else {
            http = try await tusUpload(file, size: size, parentId: parentId, name: name,
                                       existingEtag: existing?.etag, mtime: mtime, progress: progress)
        }
        return try await finalItem(http, fallback: fallback)
    }

    /// Throws `.preconditionFailed` when something already lives at `url` (PROPFIND succeeds); 404 means free.
    private func requireAbsent(_ url: URL) async throws {
        do {
            _ = try await send(request("PROPFIND", url, ["Depth": "0", "Content-Type": "application/xml"]),
                               .data(Self.propfindBody))
        } catch OpenCloudError.notFound {
            return
        }
        throw OpenCloudError.preconditionFailed
    }

    public func move(_ id: String, toParent parentId: String, name: String) async throws -> RemoteItem {
        let name = name.precomposedStringWithCanonicalMapping
        let destination = DAVPaths.child(parentId, name: name, base: baseURL)
        let req = request("MOVE", DAVPaths.item(id, base: baseURL),
                          ["Destination": destination.absoluteString, "Overwrite": "F"])
        let (_, http) = try await send(req, overrides: [412: .alreadyExists])
        return try await finalItem(http, fallback: destination).item
    }

    public func delete(_ id: String) async throws {
        _ = try await send(request("DELETE", DAVPaths.item(id, base: baseURL)))
    }

    // MARK: Plumbing

    func request(_ method: String, _ url: URL, _ headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// The item named by the `OC-FileId` response header (`confirmed`), else whatever lives at `fallback`.
    func finalItem(_ http: HTTPURLResponse, fallback: URL) async throws -> (item: RemoteItem, confirmed: Bool) {
        let named = http.value(forHTTPHeaderField: "OC-FileId").map { DAVPaths.item($0, base: baseURL) }
        return (try await propfind(named ?? fallback, depth: 0).first.orThrow(), named != nil)
    }

    enum Body: Sendable { case none, data(Data), file(URL) }

    /// `authorize: false` sends no `Authorization` header (and so does not retry a 401).
    func send(_ req: URLRequest, _ body: Body = .none, overrides: [Int: OpenCloudError] = [:], authorize: Bool = true)
        async throws -> (Data, HTTPURLResponse) {
        try await perform(req, overrides: overrides, authorize: authorize) { r in
            switch body {
            case .none: try await self.session.data(for: r)
            case .data(let d): try await self.session.upload(for: r, from: d)
            case .file(let f): try await self.session.upload(for: r, fromFile: f)
            }
        }
    }

    /// Adds auth, runs `op`, retries once after a 401 (refreshing first), maps error statuses.
    private func perform<T>(_ req: URLRequest, overrides: [Int: OpenCloudError] = [:], authorize: Bool = true,
                            _ op: (URLRequest) async throws -> (T, URLResponse)) async throws -> (T, HTTPURLResponse) {
        for attempt in 0..<2 {
            var r = req
            if authorize { r.setValue(try await auth.authorizationHeader(), forHTTPHeaderField: "Authorization") }
            let (value, response) = try await op(r)
            guard let http = response as? HTTPURLResponse else { throw OpenCloudError.invalidResponse }
            if http.statusCode == 401, attempt == 0, authorize {
                try await auth.refreshAfterUnauthorized()
                continue
            }
            if let error = overrides[http.statusCode] ?? OpenCloudError(status: http.statusCode) { throw error }
            return (value, http)
        }
        throw OpenCloudError.unauthorized
    }
}

private extension Optional {
    func orThrow() throws -> Wrapped {
        guard let self else { throw OpenCloudError.invalidResponse }
        return self
    }
}

private extension String {
    var trimmingSlashes: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
