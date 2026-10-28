import Foundation

extension OpenCloudClient {
    /// TUS creation (`POST` on the parent) followed by `PATCH` chunks read from disk.
    /// Returns the final PATCH response (it carries `OC-FileId`).
    func tusUpload(_ file: URL, size: Int64, parentId: String, name: String, existingEtag: String?,
                   mtime: Int, progress: Progress?) async throws -> HTTPURLResponse {
        let b64 = { (s: String) in Data(s.utf8).base64EncodedString() }
        var headers = [
            "Tus-Resumable": "1.0.0",
            "Upload-Length": "\(size)",
            "Upload-Metadata": "filename \(b64(name)),mtime \(b64("\(mtime)"))",
            "X-OC-Mtime": "\(mtime)",
        ]
        if let existingEtag { headers["If-Match"] = "\"\(existingEtag)\"" }
        let (_, created) = try await send(request("POST", DAVPaths.item(parentId, base: baseURL), headers))
        if size == 0 {      // creation alone completes an empty upload; there is no Location to PATCH
            progress?.completedUnitCount = 0
            return created
        }
        guard let location = created.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location, relativeTo: baseURL)?.absoluteURL
        else { throw OpenCloudError.invalidResponse }
        // The Location URL carries its own upload token; the bearer token goes along only to the
        // server's own host, and never over a downgraded scheme.
        let sameServer = uploadURL.host(percentEncoded: false)?.lowercased() == baseURL.host(percentEncoded: false)?.lowercased()
            && (uploadURL.scheme == "https" || uploadURL.scheme == baseURL.scheme)

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var last = created
        while offset < size {
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: Int(min(Int64(chunkSize), size - offset))) ?? Data()
            guard !chunk.isEmpty else { throw OpenCloudError.invalidResponse }   // file shrank underneath us
            let patch = request("PATCH", uploadURL, [
                "Tus-Resumable": "1.0.0",
                "Upload-Offset": "\(offset)",
                "Content-Type": "application/offset+octet-stream",
                "Content-Length": "\(chunk.count)",
            ])
            (_, last) = try await send(patch, .data(chunk), authorize: sameServer)
            let next = last.value(forHTTPHeaderField: "Upload-Offset").flatMap { Int64($0) } ?? offset + Int64(chunk.count)
            guard next > offset else { throw OpenCloudError.invalidResponse }
            offset = next
            progress?.completedUnitCount = offset
        }
        return last
    }
}
