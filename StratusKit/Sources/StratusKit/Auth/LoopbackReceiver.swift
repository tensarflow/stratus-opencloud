import Foundation
import Network

/// One-shot HTTP listener on `127.0.0.1:<ephemeral>` that catches the OIDC redirect. Only a
/// redirect carrying the expected `state` counts; anything else is answered and ignored.
public final class LoopbackReceiver: @unchecked Sendable {
    private static func page(_ text: String) -> Data {
        Data("""
            <!doctype html><meta charset="utf-8"><title>Stratus</title>\
            <p style="font:16px -apple-system,sans-serif">\(text)</p>
            """.utf8)
    }

    private let state: String
    private let timeout: Duration
    private let queue = DispatchQueue(label: "com.arteq.stratus.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var outcome: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?

    public convenience init(state: String) { self.init(state: state, timeout: .seconds(300)) }

    init(state: String, timeout: Duration) {
        self.state = state
        self.timeout = timeout
    }

    /// Starts listening and returns the redirect URI, `http://127.0.0.1:<port>`.
    public func start() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first(), let p = listener.port?.rawValue { continuation.resume(returning: p) }
                case .failed(let error):
                    if once.first() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.first() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Query items of the redirect request (the first one with the expected `state` and a `code`).
    /// Throws `.authorizationFailed` for an `error=` redirect with that state.
    public func callback() async throws -> [String: String] {
        let timer = Task { [timeout] in
            try await Task.sleep(for: timeout)
            self.finish(.failure(AuthError.timedOut))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    public func stop() {
        let l = lock.withLock { () -> NWListener? in defer { listener = nil }; return listener }
        l?.cancel()
        finish(.failure(CancellationError()))
    }

    // MARK: -

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.firstRange(of: Data("\r\n".utf8)) {
                self.respond(to: connection, requestLine: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func respond(to connection: NWConnection, requestLine: String) {
        let parts = requestLine.split(separator: " ")
        let items = parts.count >= 2 && parts[0] == "GET"
            ? URLComponents(string: "http://127.0.0.1" + parts[1])?.queryItems : nil
        let params = Dictionary((items ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let outcome: Result<[String: String], Error>?
        let status: String, body: Data
        if params["code"] == nil, params["error"] == nil {
            (outcome, status, body) = (nil, "404 Not Found", Data())
        } else if params["state"] != state {
            (outcome, status, body) = (nil, "400 Bad Request", Self.page("This sign-in link is not the one Stratus is waiting for."))
        } else if let error = params["error"] {
            (outcome, status, body) = (.failure(AuthError.authorizationFailed(error)), "200 OK",
                                       Self.page("Sign-in failed. You can close this tab."))
        } else {
            (outcome, status, body) = (.success(params), "200 OK", Self.page("Signed in to Stratus. You can close this tab."))
        }
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            if let outcome { self?.finish(outcome) }
        })
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
