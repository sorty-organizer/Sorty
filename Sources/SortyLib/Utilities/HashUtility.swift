//
//  HashUtility.swift
//  Sorty
//
//  Centralized hashing utilities
//

import Foundation
import CryptoKit

public enum HashUtility {
    struct ReadFailure: Error, Hashable, Sendable {
        let domain: String
        let code: Int
        let message: String

        init(_ error: Error) {
            let nsError = error as NSError
            domain = nsError.domain
            code = nsError.code
            message = nsError.localizedDescription
        }

        init(message: String) {
            domain = NSCocoaErrorDomain
            code = NSFileReadUnknownError
            self.message = message
        }
    }

    enum ReadResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure(ReadFailure)
        case cancelled

        var value: Value? {
            guard case .success(let value) = self else { return nil }
            return value
        }
    }

    public struct SampleFingerprint: Sendable {
        public let digest: String
        public let isFullFileHash: Bool

        public init(digest: String, isFullFileHash: Bool) {
            self.digest = digest
            self.isFullFileHash = isFullFileHash
        }
    }

    private static let streamingBufferSize = 1024 * 1024
    private static let sampleSize = 64 * 1024
    /// Cooperative yield interval while streaming a file. Hashing runs on
    /// `.utility` tasks (see callers); yielding every 8 MB keeps long hashes
    /// from monopolizing a cooperative thread without awaiting (this type is
    /// intentionally synchronous so tests and single-file scans keep a
    /// non-async entry point).
    private static let bytesPerThreadYield = 8 * 1024 * 1024

    private static func yieldThreadIfNeeded(_ bytesSinceYield: inout Int) {
        guard bytesSinceYield >= bytesPerThreadYield else { return }
        bytesSinceYield = 0
        Thread.sleep(forTimeInterval: 0)
    }

    /// Compute SHA-256 hash for a file at the given URL using streaming to avoid memory issues
    public static func computeSHA256(for url: URL) -> String? {
        computeSHA256Result(for: url).value
    }

    static func computeSHA256Result(for url: URL) -> ReadResult<String> {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .failure(ReadFailure(error))
        }
        
        defer {
            try? handle.close()
        }
        
        var hasher = SHA256()
        var bytesSinceYield = 0

        while true {
            if Task.isCancelled {
                return .cancelled
            }

            do {
                guard let data = try handle.read(upToCount: streamingBufferSize), !data.isEmpty else {
                    break
                }
                hasher.update(data: data)
                bytesSinceYield += data.count
                yieldThreadIfNeeded(&bytesSinceYield)
            } catch {
                return .failure(ReadFailure(error))
            }
        }
        
        return .success(hexDigest(hasher.finalize()))
    }

    /// Reads only the first and last 64 KiB of large files. Files at or below
    /// 128 KiB are hashed completely, so that digest can be used as the final
    /// exact-match hash without reading the file again.
    public static func computeSampleFingerprint(for url: URL) -> SampleFingerprint? {
        computeSampleFingerprintResult(for: url).value
    }

    static func computeSampleFingerprintResult(for url: URL) -> ReadResult<SampleFingerprint> {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .failure(ReadFailure(error))
        }

        defer {
            try? handle.close()
        }

        do {
            let fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)

            if fileSize <= UInt64(sampleSize * 2) {
                var hasher = SHA256()
                var bytesSinceYield = 0
                while true {
                    if Task.isCancelled {
                        return .cancelled
                    }

                    guard let data = try handle.read(upToCount: streamingBufferSize),
                          !data.isEmpty else {
                        break
                    }
                    hasher.update(data: data)
                    bytesSinceYield += data.count
                    yieldThreadIfNeeded(&bytesSinceYield)
                }

                return .success(
                    SampleFingerprint(
                        digest: hexDigest(hasher.finalize()),
                        isFullFileHash: true
                    )
                )
            }

            guard !Task.isCancelled,
                  let prefix = try handle.read(upToCount: sampleSize),
                  prefix.count == sampleSize else {
                return Task.isCancelled
                    ? .cancelled
                    : .failure(ReadFailure(message: "The file changed while it was being read."))
            }

            try handle.seek(toOffset: fileSize - UInt64(sampleSize))
            guard !Task.isCancelled,
                  let suffix = try handle.read(upToCount: sampleSize),
                  suffix.count == sampleSize else {
                return Task.isCancelled
                    ? .cancelled
                    : .failure(ReadFailure(message: "The file changed while it was being read."))
            }

            var hasher = SHA256()
            var bigEndianFileSize = fileSize.bigEndian
            withUnsafeBytes(of: &bigEndianFileSize) { bytes in
                hasher.update(bufferPointer: bytes)
            }
            hasher.update(data: prefix)
            hasher.update(data: suffix)

            return .success(
                SampleFingerprint(
                    digest: hexDigest(hasher.finalize()),
                    isFullFileHash: false
                )
            )
        } catch {
            return .failure(ReadFailure(error))
        }
    }

    private static func hexDigest<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
