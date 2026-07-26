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
/// `Sendable` is satisfied structurally: the value box wraps
/// `any Sendable` (which is itself Sendable), and the Dictionary
/// `[ObjectIdentifier: Box]` is Sendable when both key and value
/// are Sendable. No `@unchecked` needed.
public struct Extensions: Sendable {
    @usableFromInline
    internal struct Box: Sendable {
        @usableFromInline internal let value: any Sendable

        @inlinable internal init(_ value: any Sendable) { self.value = value }
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
    public mutating func insert<T: Sendable>(_ value: T) {
        storage[ObjectIdentifier(T.self)] = Box(value)
    }

    /// Get the value for type `T`, if any.
    @inlinable
    public func get<T: Sendable>(_ type: T.Type = T.self) -> T? {
        storage[ObjectIdentifier(type)]?.value as? T
    }

    /// Remove the value for type `T`.
    @discardableResult
    @inlinable
    public mutating func remove<T: Sendable>(_ type: T.Type = T.self) -> T? {
        if let removed = storage.removeValue(forKey: ObjectIdentifier(type)) {
            return removed.value as? T
        }
        return nil
    }
}
