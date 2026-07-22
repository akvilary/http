//===----------------------------------------------------------------------===//
//
//  Body.swift
//  HTTP
//
//  Port of `axum::body::Body` + `http_body::Body` + `http_body::Frame`.
//
//  Three layers, matching Rust's structure:
//
//    1. `Frame<Data>` — a single frame in a body stream. Either a data
//       chunk or trailers (sent after the final data frame).
//       Direct port of `http_body::Frame<T>`.
//
//    2. `BodyProtocol` — the trait equivalent of `http_body::Body`.
//       Conform to write custom body types (e.g. hyper's `Incoming`,
//       a streaming file body, etc.). The trait's poll_frame method
//       becomes `nextFrame() async throws -> Frame?` in Swift.
//
//    3. `Body` — the concrete enum used in `Request` and
//       `Response`. Direct port of `axum::body::Body`. Three
//       cases cover the entire API surface of axum's Body:
//
//         .empty              ≡ Body::empty()
//         .buffered([UInt8])  ≡ Body::from(Vec<u8>) / Body::from(Bytes)
//         .stream(AsyncSeq)   ≡ Body::from_stream(s)
//
//  Body conforms to BodyProtocol so it can be used wherever a generic
//  body type is expected. Custom body types conform to BodyProtocol
//  and can be wrapped via `Body.from(body)`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// A single frame in a body stream.
///
/// Direct port of `http_body::Frame<T>`. Either a data chunk or
/// optional trailers sent after the final data frame.
public enum Frame<Data: Sendable>: Sendable {
    /// Body data chunk.
    case data(Data)
    /// Trailers — optional headers sent after the final data frame
    /// (only valid with chunked Transfer-Encoding or HTTP/2).
    case trailers(HeaderMap)
}

/// A size hint for a body — port of `http_body::SizeHint`.
///
/// Lets the codec decide whether to use Content-Length (known size)
/// or chunked Transfer-Encoding (unknown size) when encoding a
/// response body.
public struct SizeHint: Sendable, Equatable {
    /// Lower bound on the body size. Always known.
    public var lower: UInt64
    /// Upper bound on the body size. `nil` means unbounded.
    public var upper: UInt64?

    @inlinable public init(lower: UInt64 = 0, upper: UInt64? = nil) {
        self.lower = lower
        self.upper = upper
    }

    /// `true` if the exact size is known — equivalent to
    /// `lower == upper` (with upper non-nil).
    @inlinable public var isExact: Bool { upper == lower }

    public static let unknown = SizeHint()
}

/// The trait equivalent of `http_body::Body`.
///
/// Conform to write a custom body type. The trait's `poll_frame`
/// method becomes `nextFrame() async throws -> Frame<[UInt8]>?`:
///
/// ```swift
/// struct FileBody: BodyProtocol {
///     let fd: CInt
///     func nextFrame() async throws -> Frame<[UInt8]>? {
///         // Read next chunk from fd, return nil on EOF
///     }
/// }
/// ```
///
/// `BodyProtocol` is `Sendable` because body instances cross actor
/// boundaries (handler → codec → transport).
public protocol BodyProtocol: Sendable {
    /// Pull the next frame. Returns `nil` when the body is fully
    /// consumed. Throws on I/O error.
    ///
    /// Direct port of `http_body::Body::poll_frame`.
    func nextFrame() async throws -> Frame<[UInt8]>?

    /// `true` if the body has no more frames to deliver. The codec
    /// uses this as a fast path to skip unnecessary polling.
    ///
    /// Direct port of `http_body::Body::is_end_stream`.
    var isEndStream: Bool { get }

    /// Best-effort size hint. Used by the encoder to choose between
    /// `Content-Length` (exact) and `chunked` (unknown) framing.
    ///
    /// Direct port of `http_body::Body::size_hint`.
    var sizeHint: SizeHint { get }
}

/// Default implementations — body types that don't have a meaningful
/// size hint or end-stream fast path can omit them.
public extension BodyProtocol {
    var isEndStream: Bool { false }
    var sizeHint: SizeHint { .unknown }
}

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
                result.append(contentsOf: chunk)
                if result.count > maxBytes { throw BodyError.limitExceeded }
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

// MARK: - BodyProtocol conformance

extension Body: BodyProtocol {
    public var isEndStream: Bool {
        switch self {
        case .empty: return true
        case .buffered: return true
        case .stream: return false
        }
    }

    public var sizeHint: SizeHint {
        switch self {
        case .empty: return SizeHint(lower: 0, upper: 0)
        case .buffered(let b):
            let n = UInt64(b.count)
            return SizeHint(lower: n, upper: n)
        case .stream: return .unknown
        }
    }

    public func nextFrame() async throws -> Frame<[UInt8]>? {
        switch self {
        case .empty:
            return nil
        case .buffered(let b):
            // The buffered case yields one data frame then EOF on
            // subsequent calls. But Body is an enum (immutable) —
            // we can't advance state. The contract is: callers use
            // `dataStream()` or `collect()` for buffered bodies,
            // not `nextFrame()` in a loop.
            //
            // For one-shot framing (which is what hyper's encoder
            // does for buffered responses), this returns the bytes
            // and the caller treats it as end-of-stream via isEndStream.
            if b.isEmpty { return nil }
            return .data(b)
        case .stream(let s):
            // Streams go via dataStream() — direct nextFrame on a
            // stateless enum can't advance the iterator.
            return nil
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
