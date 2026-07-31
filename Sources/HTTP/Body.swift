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
/// Direct port of `axum::body::Body`. Four cases cover the entire
/// API surface:
///
/// ```swift
/// let b1: Body = .empty                          // Body::empty()
/// let b2: Body = .buffered([0x68, 0x69])         // Body::from(Vec<u8>)
/// let b3: Body = .buffered("hello")              // Body::from(String)
/// let b4: Body = .stream(someAsyncSequence)      // Body::from_stream(s) (response)
/// let b5: Body = .pull { await nextChunk() }     // request body from H1Conn (lazy)
/// ```
///
/// `.pull` is the request-side streaming case: it carries a
/// closure that pulls one chunk at a time from the underlying
/// connection driver. The hot path (`body.collect()` in extractors
/// like `Json<T>` / `Form<T>`) uses a direct `while let chunk = try
/// await next()` loop — no `AsyncThrowingStream`, no per-request
/// `Task` spawn, no existential iterator boxing. One closure-capture
/// allocation per request with a body (mirrors axum's `BoxBody`).
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
    /// Used for **response** bodies (SSE, large file responses,
    /// proxied responses) — anywhere we don't want to buffer the
    /// entire body in memory before sending. Carries an existential
    /// `any AsyncSequence`, so the boxing cost lands on responses
    /// (off the request hot path).
    case stream(any AsyncSequence<[UInt8], Error> & Sendable)

    /// **Request-side** streaming body — a closure that pulls one
    /// chunk at a time from the underlying connection driver
    /// (`H1Conn.nextBodyChunk`). Returns `nil` at end of body.
    ///
    /// Used by `StarlightServer` when a request arrives with a body
    /// (`Content-Length > 0` or `Transfer-Encoding: chunked`). The
    /// `H1Conn` actor lives for the duration of the connection; the
    /// closure captures it (plus a generation counter that detects
    /// stale reads after the connection has moved on to the next
    /// keep-alive request).
    ///
    /// `Body.collect(maxBytes:)` consumes this case via a direct
    /// `while` loop — no `AsyncThrowingStream` wrapping, no per-request
    /// `Task` spawn. `Body.dataStream()` adapts it to a custom
    /// `BodyDataStream` AsyncSequence for callers that prefer
    /// `for try await chunk in body` syntax.
    indirect case pull(@Sendable () async throws -> [UInt8]?)

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
        case .pull: return nil
        }
    }

    @inlinable public var isEmpty: Bool {
        switch self {
        case .empty: return true
        case .buffered(let b): return b.isEmpty
        case .stream: return false
        case .pull: return false
        }
    }

    // MARK: - Collect (drain to buffer)

    /// Drain the body into a single `[UInt8]` buffer. Mirrors
    /// `axum::body::to_bytes(body, limit)`.
    ///
    /// For `.empty` / `.buffered` this is O(1) — returns the existing
    /// bytes. For `.pull` / `.stream` it awaits every chunk and
    /// concatenates.
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
        case .pull(let next):
            // Hot path for request bodies: direct while-loop on the
            // closure. No AsyncThrowingStream, no Task spawn, no
            // existential iterator. The closure is a thin wrapper
            // around `H1Conn.nextBodyChunk` which executes inline
            // when the caller is on the same eventLoop.
            var result: [UInt8] = []
            while let chunk = try await next() {
                if result.count + chunk.count > maxBytes {
                    throw BodyError.limitExceeded
                }
                result.append(contentsOf: chunk)
            }
            return result
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
    /// For `.pull`: yields each chunk pulled from the underlying
    ///   connection driver on demand. Note that this incurs one
    ///   `Task` allocation per call (the closure is async, but
    ///   `AsyncThrowingStream`'s producer is callback-based). The
    ///   hot path for `.pull` bodies is `Body.collect(maxBytes:)`,
    ///   which drives the closure directly without going through
    ///   this method.
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
        case .pull(let next):
            return AsyncThrowingStream { cont in
                let task = Task {
                    do {
                        while let chunk = try await next() {
                            cont.yield(chunk)
                        }
                        cont.finish()
                    } catch {
                        cont.finish(throwing: error)
                    }
                }
                cont.onTermination = { _ in task.cancel() }
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
    /// The connection moved on to the next keep-alive request before
    /// this body was fully read. Thrown by `.pull` when the
    /// generation counter captured at body-creation time no longer
    /// matches the underlying `H1Conn`'s current generation —
    /// i.e. the handler escaped its `Request` past
    /// `driveConnection`'s next `decodeHead` cycle.
    case connectionAdvanced
}
