//===----------------------------------------------------------------------===//
//
//  Request.swift
//  StarlightHTTP
//
//  HTTP request.
//
//===----------------------------------------------------------------------===//

import Foundation

/// HTTP request.
///
/// `body` is the concrete `Body` enum — the same type the codec
/// produces and handlers consume. Unlike Rust's `http::Request<B>`,
/// Swift's `Body` enum already covers all body representations
/// (empty / buffered / stream), so there's no need to parameterise
/// over the body type.
public struct Request: Sendable {
    public var method: Method
    public var uri: Uri
    public var version: Version
    public var headers: HeaderMap
    public var body: Body
    /// Extension map — axum's `Request::extensions_mut` analogue.
    /// Used to thread per-request state (matched route id, client
    /// IP, etc.) between middleware and handlers without growing
    /// `Request` itself.
    public var extensions: Extensions

    @inlinable
    public init(
        method: Method = .GET,
        uri: Uri = Uri("/"),
        version: Version = .http11,
        headers: HeaderMap = HeaderMap(),
        body: Body = Body(),
        extensions: Extensions = Extensions()
    ) {
        self.method = method
        self.uri = uri
        self.version = version
        self.headers = headers
        self.body = body
        self.extensions = extensions
    }

    /// Convenience initialiser with an empty body.
    @inlinable
    public init(
        method: Method = .GET,
        uri: Uri = Uri("/"),
        version: Version = .http11,
        headers: HeaderMap = HeaderMap()
    ) {
        self.init(method: method, uri: uri, version: version,
                  headers: headers, body: Body())
    }
}

/// Type-erased extension map.
///
/// Mirrors `http::Extensions`. Stores values keyed by type —
/// each type may have at most one value. Common uses in axum:
/// matched `RouteId`, captured `MatchedPath`, custom middleware
/// state (correlation IDs, auth principal, etc.).
///
/// `@unchecked Sendable` is required because `AnyHashable` is not
/// `Sendable` in Swift 6.2 (it erases the type, so the compiler
/// can't prove the wrapped value is Sendable). We guarantee safety
/// by only accepting `T: Hashable & Sendable` in `insert`.
public struct Extensions: @unchecked Sendable {
    @usableFromInline
    internal struct Box: @unchecked Sendable {
        @usableFromInline internal let value: AnyHashable

        @inlinable internal init(value: AnyHashable) { self.value = value }
    }

    @usableFromInline
    internal var storage: [ObjectIdentifier: Box] = [:]

    @inlinable public init() {}

    /// Clear all stored values, preserving backing storage capacity.
    /// Used by the codec to reuse the Extensions object across
    /// keep-alive requests — avoids Dictionary re-allocation.
    @inlinable public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }

    /// Insert `value` for its dynamic type, replacing any prior.
    @inlinable
    public mutating func insert<T: Hashable & Sendable>(_ value: T) {
        storage[ObjectIdentifier(T.self)] = Box(value: AnyHashable(value))
    }

    /// Get the value for type `T`, if any.
    @inlinable
    public func get<T: Hashable & Sendable>(_ type: T.Type = T.self) -> T? {
        storage[ObjectIdentifier(type)]?.value.base as? T
    }

    /// Remove the value for type `T`.
    @discardableResult
    @inlinable
    public mutating func remove<T: Hashable & Sendable>(_ type: T.Type = T.self) -> T? {
        if let removed = storage.removeValue(forKey: ObjectIdentifier(type)) {
            return removed.value.base as? T
        }
        return nil
    }
}
