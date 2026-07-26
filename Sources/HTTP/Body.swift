//===----------------------------------------------------------------------===//
//
//  Body.swift
//  HTTP
//
//  Port of `axum::body::Body`.
//
//  `Body` is the concrete enum used in `Request` and `Response`.
//  Three cases cover the entire API surface of axum's Body:
//
//    .empty              ≡ Body::empty()
//    .buffered([UInt8])  ≡ Body::from(Vec<u8>) / Body::from(Bytes)
//    .stream(AsyncSeq)   ≡ Body::from_stream(s)
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Body (concrete enum)

/// The body type used in `Request` and `Response`.
///
/// Direct port of `axum::body::Body`. Three cases cover the entire
/// API surface:
///
/// ```swift
/// let b1: Body = .empty                          // Body::empty()
/// let b2: Body = .buffered([0x68, 0x69])         // Body::from(Vec<u8>)
/// let b3: Body = .buffered("hello")              // Body::from(String)
/// let b4: Body = .stream(someAsyncSequence)      // Body::from_stream(s)
/// ```
///
/// For custom body types, conform to `BodyProtocol` and use
/// `Body.from(customBody)`:
///
/// ```swift
/// struct MyBody: BodyProtocol { ... }
/// let body = Body.from(MyBody())
/// ```
///
public enum Body: Sendable {
    /// No body bytes. Equivalent to `Body::empty()` / `Body::default()`.
    case empty

    /// Fully materialised body in memory. Equivalent to
    /// `Body::from(Vec<u8>)` / `Body::from(Bytes)` / `Body::from(&str)`.
    case buffered([UInt8])

    /// Streaming body — chunks delivered over time via an
    /// `AsyncSequence`. Equivalent to `Body::from_stream(s)`.
    ///
    /// Used for SSE, large file uploads, proxied responses — anywhere
    /// we don't want to buffer the entire body in memory before
    /// sending.
    case stream(any AsyncSequence<[UInt8], Error> & Sendable)

    // MARK: - Convenience constructors (mirror axum::body::Body::from)

    /// `Body::from(Vec<u8>)` / `Body::from(Bytes)`.
    @inlinable public init(_ bytes: [UInt8]) {
        self = .buffered(bytes)
    }

    /// `Body::from(&'static str)` / `Body::from(String)`.
    @inlinable public init(_ string: String) {
        self = .buffered(Array(string.utf8))
    }

    /// `Body::from(())` — same as `.empty`.
    @inlinable public init() {
        self = .empty
    }

    /// `Body::from(Data)`.
    @inlinable public init(_ data: Data) {
        self = .buffered(Array(data))
    }

    // MARK: - Accessors

    /// Number of bytes if the body is `.buffered`, otherwise `nil`.
    /// Mirrors the `Option<usize>` you'd get from `body.size_hint().upper()`
    /// when only the buffered case has an exact size.
    @inlinable public var knownSize: Int? {
        switch self {
        case .empty: return 0
        case .buffered(let b): return b.count
        case .stream: return nil
        }
    }

    @inlinable public var isEmpty: Bool {
        switch self {
        case .empty: return true
        case .buffered(let b): return b.isEmpty
        case .stream: return false
        }
    }

    // MARK: - Collect (drain to buffer)

    /// Drain the body into a single `[UInt8]` buffer. Mirrors
    /// `axum::body::to_bytes(body, limit)`.
    ///
    /// For `.empty` / `.buffered` this is O(1) — returns the existing
    /// bytes. For `.stream` it awaits every chunk and concatenates.
    ///
    /// - Parameter maxBytes: maximum total bytes. Throws
    ///   `BodyError.limitExceeded` if exceeded.
    public func collect(maxBytes: Int = .max) async throws -> [UInt8] {
        switch self {
        case .empty:
            return []
        case .buffered(let b):
            if b.count > maxBytes { throw BodyError.limitExceeded }
            return b
        case .stream(let s):
            var result: [UInt8] = []
            for try await chunk in s {
                // Check BEFORE appending — a single oversized chunk
                // must not trigger a multi-GB allocation before the
                // limit fires.
                if result.count + chunk.count > maxBytes {
                    throw BodyError.limitExceeded
                }
                result.append(contentsOf: chunk)
            }
            return result
        }
    }

    // MARK: - Into data stream (mirror Body::into_data_stream)

    /// View the body as an `AsyncThrowingStream` of byte chunks.
    /// Direct port of `axum::body::Body::into_data_stream` — non-data
    /// frames (trailers) are discarded.
    ///
    /// For `.empty`: yields nothing.
    /// For `.buffered`: yields one chunk with all bytes.
    /// For `.stream`: yields each chunk from the underlying sequence.
    public func dataStream() -> AsyncThrowingStream<[UInt8], Error> {
        switch self {
        case .empty:
            return AsyncThrowingStream { cont in cont.finish() }
        case .buffered(let bytes):
            return AsyncThrowingStream { cont in
                if !bytes.isEmpty { cont.yield(bytes) }
                cont.finish()
            }
        case .stream(let s):
            return AsyncThrowingStream { cont in
                let task = Task {
                    do {
                        for try await chunk in s {
                            cont.yield(chunk)
                        }
                        cont.finish()
                    } catch {
                        cont.finish(throwing: error)
                    }
                }
                cont.onTermination = { _ in task.cancel() }
            }
        }
    }
}

// MARK: - Errors

/// Errors thrown by body operations.
public enum BodyError: Error, Sendable, Equatable {
    /// The body exceeded the configured maximum size during `collect`.
    case limitExceeded
    /// The body stream produced an error.
    case ioError
}
