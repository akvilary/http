//===----------------------------------------------------------------------===//
//
//  HeaderName.swift / HeaderValue.swift / HeaderMap.swift
//  StarlightHTTP
//
//  Direct port of `http::{HeaderName, HeaderValue, HeaderMap}`.
//
//===----------------------------------------------------------------------===//

import Foundation


/// Internal small-byte-string pack/unpack shared by `HeaderName` and
/// `HeaderValue`: ≤15 bytes pack into two UInt64 lanes + a length —
/// no heap allocation, dense value storage in `HeaderMap.entries`.
@usableFromInline
internal enum SmallAscii {

    @inlinable
    @inline(__always)
    static func packInline(_ bytes: [UInt8]) -> (lo: UInt64, hi: UInt64, len: UInt8)? {
        guard bytes.count <= 15 else { return nil }
        var lo: UInt64 = 0, hi: UInt64 = 0
        for (k, b) in bytes.enumerated() {
            if k < 8 { lo |= UInt64(b) << (8 &* UInt64(k)) }
            else { hi |= UInt64(b) << (8 &* UInt64(k &- 8)) }
        }
        return (lo, hi, UInt8(bytes.count))
    }

    @inline(__always)
    static func unpack(_ lo: UInt64, _ hi: UInt64, _ len: UInt8) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Int(len))
        for k in 0..<Int(len) {
            out.append(k < 8
                ? UInt8(truncatingIfNeeded: lo >> (8 &* UInt64(k)))
                : UInt8(truncatingIfNeeded: hi >> (8 &* UInt64(k &- 8))))
        }
        return out
    }
}

/// HTTP header name (e.g. `Content-Type`, `Content-Length`).
///
/// Case-insensitive on comparison, case-preserving on display —
/// matching RFC 9110 §5.1. Stored lowercased; the canonical form is
/// materialised on demand via `description`.
///
/// Data layout: names of ≤15 bytes (virtually all real-world header
/// names) live INLINE in the struct — two `UInt64` lanes plus a
/// length — so parsing a request allocates nothing per header name,
/// and `HeaderMap.entries` becomes a dense, cache-friendly value
/// array instead of an array of heap pointers.
public struct HeaderName: Sendable, Hashable, CustomStringConvertible {
    @usableFromInline
    internal enum Storage: Hashable, Sendable {
        /// ≤15 bytes: lane 0 = bytes 0…7, lane 1 = bytes 8…14.
        case inline(UInt64, UInt64, UInt8)
        case heap([UInt8])
    }
    @usableFromInline internal var storage: Storage

    @inlinable
    public init(_ name: String) {
        // Lowercase ASCII for the lookup fast path.
        // (RFC 9110: header names are case-insensitive.)
        let lowered = name.utf8.map { b -> UInt8 in
            if b >= 0x41 && b <= 0x5A { return b + 32 }   // A-Z → a-z
            return b
        }
        self.storage = Self.makeStorage(lowered)
    }

    /// Construct from raw bytes — used by the parser to avoid a
    /// `String` round-trip on the hot path.
    @inlinable
    public init(lowercasedBytes bytes: [UInt8]) {
        self.storage = Self.makeStorage(bytes)
    }

    /// Construct from raw buffer bytes, lowercasing ASCII A-Z in
    /// place while copying into the storage — zero intermediate
    /// allocation for names that fit inline (the parser's hot path:
    /// it borrows directly from the connection read buffer).
    @inlinable
    public init(lowercasingBuffer bytes: UnsafeBufferPointer<UInt8>) {
        if bytes.count <= 15 {
            var lo: UInt64 = 0, hi: UInt64 = 0
            for (k, b) in bytes.enumerated() {
                let lower = (b >= 0x41 && b <= 0x5A) ? b &+ 32 : b
                if k < 8 { lo |= UInt64(lower) << (8 &* UInt64(k)) }
                else { hi |= UInt64(lower) << (8 &* UInt64(k &- 8)) }
            }
            self.storage = .inline(lo, hi, UInt8(bytes.count))
        } else {
            var copy = [UInt8]()
            copy.reserveCapacity(bytes.count)
            copy.append(contentsOf: bytes.map {
                ($0 >= 0x41 && $0 <= 0x5A) ? $0 &+ 32 : $0
            })
            self.storage = .heap(copy)
        }
    }

    @usableFromInline
    internal static func makeStorage(_ bytes: [UInt8]) -> Storage {
        if let p = SmallAscii.packInline(bytes) {
            return .inline(p.lo, p.hi, p.len)
        }
        return .heap(bytes)
    }

    /// Number of bytes in the name — O(1), no materialisation.
    @inlinable
    public var byteCount: Int {
        switch storage {
        case .inline(_, _, let n): return Int(n)
        case .heap(let b): return b.count
        }
    }

    /// The lowercased bytes, materialised. Prefer `withUnsafeBytes`
    /// on hot paths — this allocates.
    public var bytes: [UInt8] {
        switch storage {
        case .inline(let lo, let hi, let len):
            return SmallAscii.unpack(lo, hi, len)
        case .heap(let b):
            return b
        }
    }

    /// Zero-allocation byte access — inline lanes are unpacked into
    /// stack storage; heap arrays borrow their buffer.
    @inlinable
    public func withUnsafeBytes<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        switch storage {
        case .inline(let lo, let hi, let len):
            var lanes = (lo, hi)
            return try Swift.withUnsafeBytes(of: &lanes) { raw in
                let full = raw.bindMemory(to: UInt8.self)
                let view = UnsafeBufferPointer(
                    start: full.baseAddress, count: Int(len)
                )
                return try body(view)
            }
        case .heap(let b):
            return try b.withUnsafeBufferPointer { try body($0) }
        }
    }

    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }

    // Hashable / Equatable over byte content.

    public func hash(into hasher: inout Hasher) {
        // Inline storage hashes its two lanes in O(1) (equal values
        // always share a representation — representation choice is
        // deterministic by length — so this stays consistent with
        // ==). Heap storage (long names, rare) hashes per byte.
        hasher.combine(byteCount)
        switch storage {
        case .inline(let lo, let hi, _):
            hasher.combine(lo)
            hasher.combine(hi)
        case .heap(let b):
            for byte in b { hasher.combine(byte) }
        }
    }

    public static func == (lhs: HeaderName, rhs: HeaderName) -> Bool {
        guard lhs.byteCount == rhs.byteCount else { return false }
        return lhs.withUnsafeBytes { a in
            rhs.withUnsafeBytes { b in a.elementsEqual(b) }
        }
    }
}

extension HeaderName {
    // ── Common names (RFC 9110 §15 + extensions) ─────────────────
    public static let accept          = HeaderName("accept")
    public static let acceptEncoding  = HeaderName("accept-encoding")
    public static let allow           = HeaderName("allow")
    public static let authorization   = HeaderName("authorization")
    public static let cacheControl    = HeaderName("cache-control")
    public static let connection      = HeaderName("connection")
    public static let contentLength   = HeaderName("content-length")
    public static let contentType     = HeaderName("content-type")
    public static let cookie          = HeaderName("cookie")
    public static let date            = HeaderName("date")
    public static let etag            = HeaderName("etag")
    public static let expect          = HeaderName("expect")
    public static let host            = HeaderName("host")
    public static let ifMatch         = HeaderName("if-match")
    public static let ifModifiedSince = HeaderName("if-modified-since")
    public static let ifNoneMatch     = HeaderName("if-none-match")
    public static let location        = HeaderName("location")
    public static let range           = HeaderName("range")
    public static let server          = HeaderName("server")
    public static let setCookie       = HeaderName("set-cookie")
    public static let transferEncoding = HeaderName("transfer-encoding")
    public static let userAgent       = HeaderName("user-agent")

    /// Hop-by-hop headers (RFC 9110 §7.6.1). These are per-connection
    /// and must not be forwarded to handlers or proxied to clients.
    public static let keepAlive        = HeaderName("keep-alive")
    public static let te               = HeaderName("te")
    public static let trailer          = HeaderName("trailer")
    public static let upgrade          = HeaderName("upgrade")
    public static let proxyConnection  = HeaderName("proxy-connection")

    /// `true` if this header name is hop-by-hop (RFC 9110 §7.6.1).
    /// These headers must be stripped after parsing and before encoding.
    @inlinable
    public func isHopByHop() -> Bool {
        switch self {
        case .connection, .keepAlive, .te, .trailer,
             .transferEncoding, .upgrade, .proxyConnection:
            return true
        default:
            return false
        }
    }
}

/// HTTP header value (the bytes after the `:`).
///
/// Stored as raw bytes — visible ASCII per RFC 9110 §5.5, but we
/// do not enforce visibility at the type level (callers may inject
/// opaque bytes for `Set-Cookie`, `Sec-WebSocket-*`, etc.). The
/// `String` form is materialised on demand via `description`.
///
/// Data layout: values of ≤15 bytes (a large share of real-world
/// values — `close`, `chunked`, `keep-alive`, short mime types,
/// numbers) live INLINE — no heap allocation per header value on
/// the request hot path.
public struct HeaderValue: Sendable, Hashable, CustomStringConvertible {
    @usableFromInline
    internal enum Storage: Hashable, Sendable {
        case inline(UInt64, UInt64, UInt8)
        case heap([UInt8])
    }
    @usableFromInline internal var storage: Storage

    @inlinable
    public init(_ value: String) {
        // RFC 9110 §5.5: optional leading/trailing whitespace is
        // trimmed by recipients. We do that here so `.host` lookups
        // never see `"  example.com  "`.
        let trimmed = Substring(value).drop(while: { $0.isWhitespace })
        var end = trimmed.endIndex
        while end > trimmed.startIndex {
            let prev = trimmed.index(before: end)
            if !trimmed[prev].isWhitespace { break }
            end = prev
        }
        let stripped = trimmed[trimmed.startIndex..<end]
        let raw = Array(stripped.utf8)
        if let p = SmallAscii.packInline(raw) {
            self.storage = .inline(p.lo, p.hi, p.len)
        } else {
            self.storage = .heap(raw)
        }
    }

    @inlinable
    public init(bytes: [UInt8]) {
        if let p = SmallAscii.packInline(bytes) {
            self.storage = .inline(p.lo, p.hi, p.len)
        } else {
            self.storage = .heap(bytes)
        }
    }

    /// Construct by borrowing bytes directly from a parse buffer —
    /// copies into the storage with zero intermediate allocation for
    /// values that fit inline (the parser's hot path).
    @inlinable
    public init(borrowingBuffer bytes: UnsafeBufferPointer<UInt8>) {
        if bytes.count <= 15 {
            var lo: UInt64 = 0, hi: UInt64 = 0
            for (k, b) in bytes.enumerated() {
                if k < 8 { lo |= UInt64(b) << (8 &* UInt64(k)) }
                else { hi |= UInt64(b) << (8 &* UInt64(k &- 8)) }
            }
            self.storage = .inline(lo, hi, UInt8(bytes.count))
        } else {
            var copy = [UInt8]()
            copy.reserveCapacity(bytes.count)
            copy.append(contentsOf: bytes)
            self.storage = .heap(copy)
        }
    }

    /// Number of bytes in the value — O(1), no materialisation.
    @inlinable
    public var byteCount: Int {
        switch storage {
        case .inline(_, _, let n): return Int(n)
        case .heap(let b): return b.count
        }
    }

    /// The raw bytes, materialised. Prefer `withUnsafeBytes` on hot
    /// paths — this allocates.
    public var bytes: [UInt8] {
        switch storage {
        case .inline(let lo, let hi, let len):
            return SmallAscii.unpack(lo, hi, len)
        case .heap(let b):
            return b
        }
    }

    /// Zero-allocation byte access.
    @inlinable
    public func withUnsafeBytes<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        switch storage {
        case .inline(let lo, let hi, let len):
            var lanes = (lo, hi)
            return try Swift.withUnsafeBytes(of: &lanes) { raw in
                let full = raw.bindMemory(to: UInt8.self)
                let view = UnsafeBufferPointer(
                    start: full.baseAddress, count: Int(len)
                )
                return try body(view)
            }
        case .heap(let b):
            return try b.withUnsafeBufferPointer { try body($0) }
        }
    }

    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(byteCount)
        switch storage {
        case .inline(let lo, let hi, _):
            hasher.combine(lo)
            hasher.combine(hi)
        case .heap(let b):
            for byte in b { hasher.combine(byte) }
        }
    }

    public static func == (lhs: HeaderValue, rhs: HeaderValue) -> Bool {
        guard lhs.byteCount == rhs.byteCount else { return false }
        return lhs.withUnsafeBytes { a in
            rhs.withUnsafeBytes { b in a.elementsEqual(b) }
        }
    }
}

/// Case-insensitive, insertion-ordered multimap of headers.
///
/// Mirrors `http::HeaderMap` (which itself mirrors hyper's
/// `HeaderMap`). Multiple values per name are supported — important
/// for `Set-Cookie` and `Cache-Control`.
public struct HeaderMap: Sendable {
    /// Backing storage: array of `(HeaderName, HeaderValue)` pairs in insertion
    /// order. Linear scan on lookup is faster than `Dictionary` for
    /// typical HTTP header counts (3-12 headers/request).
    ///
    /// Public so the codec (in a separate module) can iterate when
    /// serialising — mirrors `http::HeaderMap::iter()`.
    public var entries: [(HeaderName, HeaderValue)] = []

    @inlinable public init() {}

    @inlinable public init<S: Sequence>(_ entries: S) where S.Element == (HeaderName, HeaderValue) {
        self.entries = Array(entries)
    }

    /// Number of stored header entries (counting multiple values
    /// for the same name separately).
    @inlinable public var count: Int { entries.count }
    @inlinable public var isEmpty: Bool { entries.isEmpty }

    /// Append a header value. Does not replace existing values for
    /// the same name — multiple `append`s for `Set-Cookie` build up
    /// the expected list. Matches `http::HeaderMap::append`.
    @inlinable
    public mutating func append(_ name: HeaderName, _ value: HeaderValue) {
        entries.append((name, value))
    }

    @inlinable
    public mutating func append(_ name: HeaderName, _ value: String) {
        append(name, HeaderValue(value))
    }

    /// Insert a header value, removing any existing values for the
    /// same name first. Matches `http::HeaderMap::insert`.
    @inlinable
    public mutating func insert(_ name: HeaderName, _ value: HeaderValue) {
        entries.removeAll { $0.0 == name }
        entries.append((name, value))
    }

    @inlinable
    public mutating func insert(_ name: HeaderName, _ value: String) {
        insert(name, HeaderValue(value))
    }

    /// First value for `name`, or `nil` if absent. axum's typed
    /// header extractors (`TypedHeader<T>`) use this as the lookup.
    @inlinable
    public func first(for name: HeaderName) -> HeaderValue? {
        for (n, v) in entries where n == name { return v }
        return nil
    }

    /// All values for `name`. Order preserved.
    @inlinable
    public func all(for name: HeaderName) -> [HeaderValue] {
        entries.compactMap { $0.0 == name ? $0.1 : nil }
    }

    /// True if any entry matches `name`.
    @inlinable
    public func contains(_ name: HeaderName) -> Bool {
        entries.contains { $0.0 == name }
    }

    /// Remove all entries for `name`. Returns the removed count.
    @discardableResult
    @inlinable
    public mutating func remove(_ name: HeaderName) -> Int {
        let before = entries.count
        entries.removeAll { $0.0 == name }
        return before - entries.count
    }
}

extension HeaderMap: Equatable {
    @inlinable
    public static func == (lhs: HeaderMap, rhs: HeaderMap) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (i, (ln, lv)) in lhs.entries.enumerated() {
            let (rn, rv) = rhs.entries[i]
            if ln != rn || lv != rv { return false }
        }
        return true
    }
}
