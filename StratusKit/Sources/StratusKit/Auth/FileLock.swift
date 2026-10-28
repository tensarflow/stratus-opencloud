import Darwin
import Foundation

/// Cross-process (and cross-task) mutual exclusion via `flock` on a lock file.
public enum FileLock {
    public static func withLock<T>(at url: URL, _ body: () async throws -> T) async throws -> T {
        let fd = try await acquire(url)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try await body()
    }

    /// `flock` blocks, so it runs on a dedicated dispatch thread rather than the cooperative pool.
    private static func acquire(_ url: URL) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
                guard fd >= 0 else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
                if flock(fd, LOCK_EX) != 0 {
                    let code = errno
                    close(fd)
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
                    return
                }
                continuation.resume(returning: fd)
            }
        }
    }
}
