import Foundation

struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    var path: String { url.path(percentEncoded: true) }
}

struct StubReply: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    init(_ status: Int, headers: [String: String] = [:], body: String = "") {
        self.status = status
        self.headers = headers
        self.body = Data(body.utf8)
    }
}

/// Records every request and answers with a canned reply. State is process-wide, so suites
/// that use it must be `.serialized`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [RecordedRequest] = []
    nonisolated(unsafe) private static var _handler: (@Sendable (RecordedRequest) -> StubReply)?

    static var requests: [RecordedRequest] { lock.withLock { _requests } }

    static func install(_ handler: @escaping @Sendable (RecordedRequest) -> StubReply) {
        lock.withLock { _requests = []; _handler = handler }
    }

    /// Replies from `replies` in order (the last one repeats).
    static func install(sequence replies: [StubReply]) {
        let counter = Counter()
        install { _ in replies[min(counter.next(), replies.count - 1)] }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET", url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:], body: body)
        let handler = Self.lock.withLock { () -> (@Sendable (RecordedRequest) -> StubReply)? in
            Self._requests.append(recorded)
            return Self._handler
        }
        let reply = handler?(recorded) ?? StubReply(500)
        let response = HTTPURLResponse(
            url: recorded.url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
