import Foundation
import Testing
@testable import StratusKit

/// Opt-in tests against a real OpenCloud server. Skipped unless `OC_URL`, `OC_USER` and `OC_TOKEN` are set.
/// Everything happens inside `/fp-test/run-<uuid>/` of the personal space; only that run folder is deleted.
private let env = ProcessInfo.processInfo.environment
private let liveConfigured = env["OC_URL"] != nil && env["OC_USER"] != nil && env["OC_TOKEN"] != nil
private let largeEnabled = liveConfigured && env["OC_LIVE_LARGE"] == "1"

private struct LiveError: Error, CustomStringConvertible { var description: String }

/// Runs `body` inside a fresh `/fp-test/run-<uuid>/` folder and removes that folder afterwards, pass or fail.
private func withRunFolder<T>(
    _ body: (_ client: OpenCloudClient, _ drive: Drive, _ run: RemoteItem) async throws -> T
) async throws -> T {
    guard let urlString = env["OC_URL"], let baseURL = URL(string: urlString),
          let user = env["OC_USER"], let token = env["OC_TOKEN"]
    else { throw LiveError(description: "OC_URL/OC_USER/OC_TOKEN missing") }

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 300
    config.timeoutIntervalForResource = 3600
    let client = OpenCloudClient(baseURL: baseURL, auth: BasicAuthProvider(user: user, token: token),
                                 session: URLSession(configuration: config))

    guard let drive = try await client.drives().first(where: { $0.type == "personal" })
    else { throw LiveError(description: "no personal drive") }

    let root = try await client.children(of: drive.id)
    let fpTest: RemoteItem
    if let existing = root.children.first(where: { $0.isFolder && $0.name == "fp-test" }) {
        fpTest = existing
    } else {
        fpTest = try await client.createFolder(in: drive.id, name: "fp-test")
    }
    let run = try await client.createFolder(in: fpTest.id, name: "run-\(UUID().uuidString)")

    let result: T
    do {
        result = try await body(client, drive, run)
    } catch {
        await cleanUp(client, run)
        throw error
    }
    await cleanUp(client, run)
    return result
}

/// Deletes the run folder this test created (nothing else). Runs detached so it still works when the test task
/// was cancelled (e.g. by `.timeLimit`), where URLSession's async API would throw immediately. A failed delete is
/// recorded as an issue naming the orphan, so it does not go unnoticed.
private func cleanUp(_ client: OpenCloudClient, _ run: RemoteItem) async {
    let id = run.id
    let failure = await Task.detached { () -> String? in
        do { try await client.delete(id); return nil } catch { return "\(error)" }
    }.value
    if let failure {
        Issue.record("Cleanup failed: orphan folder /fp-test/\(run.name) left on the server (\(failure))")
    }
}

private func tempFile(_ contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stratus-live-\(UUID().uuidString)")
    try contents.write(to: url)
    return url
}

private func download(_ client: OpenCloudClient, _ id: String) async throws -> Data {
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("stratus-dl-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dest) }
    _ = try await client.download(id, to: dest, progress: nil)
    return try Data(contentsOf: dest)
}

@Suite(.serialized, .enabled(if: liveConfigured)) struct LiveServerTests {
    @Test func roundTrip() async throws {
        try await withRunFolder { client, _, run in
            // Upload + download
            let hello = Data("hello stratus".utf8)
            let src = try tempFile(hello)
            defer { try? FileManager.default.removeItem(at: src) }
            let uploaded = try await client.upload(src, parentId: run.id, name: "hello.txt", replacing: nil,
                                                   modified: Date(timeIntervalSince1970: 1_700_000_000), progress: nil)
            #expect(uploaded.name == "hello.txt")
            #expect(uploaded.size == Int64(hello.count))
            #expect(!uploaded.etag.isEmpty)
            #expect(try await download(client, uploaded.id) == hello)

            // Creating an existing name (replacing: nil) is refused and leaves the server copy alone
            let other = try tempFile(Data("something else entirely".utf8))
            defer { try? FileManager.default.removeItem(at: other) }
            await #expect(throws: OpenCloudError.preconditionFailed) {
                try await client.upload(other, parentId: run.id, name: "hello.txt", replacing: nil,
                                        modified: nil, progress: nil)
            }
            #expect(try await download(client, uploaded.id) == hello)
            #expect(try await client.item(uploaded.id).etag == uploaded.etag)

            // Replace with the correct etag
            let v2 = Data("second version, longer".utf8)
            let src2 = try tempFile(v2)
            defer { try? FileManager.default.removeItem(at: src2) }
            let replaced = try await client.upload(src2, parentId: run.id, name: "hello.txt",
                                                   replacing: (uploaded.id, uploaded.etag), modified: nil, progress: nil)
            #expect(replaced.id == uploaded.id)
            #expect(replaced.etag != uploaded.etag)
            #expect(replaced.size == Int64(v2.count))
            #expect(try await download(client, uploaded.id) == v2)

            // Replace with a stale etag
            await #expect(throws: OpenCloudError.preconditionFailed) {
                try await client.upload(src, parentId: run.id, name: "hello.txt",
                                        replacing: (uploaded.id, uploaded.etag), modified: nil, progress: nil)
            }
            #expect(try await download(client, uploaded.id) == v2)   // untouched

            // 0-byte file
            let empty = try tempFile(Data())
            defer { try? FileManager.default.removeItem(at: empty) }
            let zero = try await client.upload(empty, parentId: run.id, name: "empty.txt", replacing: nil,
                                               modified: nil, progress: nil)
            #expect(zero.size == 0)
            #expect(try await client.item(zero.id).size == 0)
            #expect(try await download(client, zero.id).isEmpty)

            // Rename to a URL-hostile, non-ASCII name; id is stable
            let hostile = "Ödev Çağlayan şğ #1 100% a+b?.txt".precomposedStringWithCanonicalMapping
            let moved = try await client.move(uploaded.id, toParent: run.id, name: hostile)
            #expect(moved.id == uploaded.id)
            #expect(moved.name == hostile)
            let listing = try await client.children(of: run.id).children
            #expect(listing.filter { $0.name == hostile }.count == 1)
            #expect(listing.map(\.name).sorted() == [hostile, "empty.txt"].sorted())
            #expect(try await download(client, uploaded.id) == v2)

            // Moving onto an existing name does not overwrite
            await #expect(throws: OpenCloudError.alreadyExists) {
                try await client.move(zero.id, toParent: run.id, name: hostile)
            }

            // Folders
            let folder = try await client.createFolder(in: run.id, name: "sub folder ü")
            #expect(folder.isFolder)
            await #expect(throws: OpenCloudError.alreadyExists) {
                try await client.createFolder(in: run.id, name: "sub folder ü")
            }

            // Delete
            try await client.delete(moved.id)
            await #expect(throws: OpenCloudError.notFound) { try await client.item(moved.id) }
            try await client.delete(folder.id)
            await #expect(throws: OpenCloudError.notFound) { try await client.item(folder.id) }
        }
    }

    @Test(.enabled(if: largeEnabled), .timeLimit(.minutes(10)))
    func largeTUSThroughCloudflare() async throws {
        try await withRunFolder { client, _, run in
            let size: Int64 = 157_286_400    // 150 MiB, above the single-PUT limit
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("stratus-big-\(UUID().uuidString)")
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            defer { try? FileManager.default.removeItem(at: url) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size))      // sparse
            try handle.close()

            let progress = Progress()
            let item = try await client.upload(url, parentId: run.id, name: "big.bin", replacing: nil,
                                               modified: nil, progress: progress)
            #expect(item.size == size)
            #expect(progress.completedUnitCount == size)
            #expect(try await client.item(item.id).size == size)
        }
    }
}
