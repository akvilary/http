//===----------------------------------------------------------------------===//
//
//  Response.swift
//  StarlightHTTP
//
//  HTTP response.
//
//===----------------------------------------------------------------------===//

import Foundation

/// HTTP response.
///
/// `body` is the concrete `Body` enum — the same type the codec
/// consumes and handlers produce. Unlike Rust's `http::Response<B>`,
/// Swift's `Body` enum already covers all body representations
/// (empty / buffered / stream), so there's no need to parameterise
/// over the body type.
public struct Response: Sendable {
    public var status: StatusCode
    public var version: Version
    public var headers: HeaderMap
    public var body: Body
    public var extensions: Extensions

    @inlinable
    public init(
        status: StatusCode = .ok,
        version: Version = .http11,
        headers: HeaderMap = HeaderMap(),
        body: Body = .empty,
        extensions: Extensions = Extensions()
    ) {
        self.status = status
        self.version = version
        self.headers = headers
        self.body = body
        self.extensions = extensions
    }

    /// Convenience initialiser: status + body, default headers empty.
    @inlinable
    public init(
        status: StatusCode = .ok,
        body: Body = .empty
    ) {
        self.init(status: status, version: .http11,
                  headers: HeaderMap(), body: body,
                  extensions: Extensions())
    }

    /// Standard 200 OK with a `text/plain` body.
    public static func plain(_ body: String, status: StatusCode = .ok) -> Response {
        var headers = HeaderMap()
        headers.insert(.contentType, "text/plain; charset=utf-8")
        headers.insert(.contentLength, String(body.utf8.count))
        return Response(status: status, headers: headers, body: .buffered(Array(body.utf8)))
    }

    /// Standard 200 OK with a raw byte body.
    public static func bytes(_ bytes: [UInt8], status: StatusCode = .ok) -> Response {
        var headers = HeaderMap()
        headers.insert(.contentLength, String(bytes.count))
        return Response(status: status, headers: headers, body: .buffered(bytes))
    }

    /// 200 OK with a streaming body. Sets `Transfer-Encoding: chunked`
    /// automatically — the encoder handles the chunk framing.
    public static func stream(
        _ stream: any AsyncSequence<[UInt8], Error> & Sendable,
        status: StatusCode = .ok,
        contentType: String = "text/plain; charset=utf-8"
    ) -> Response {
        var headers = HeaderMap()
        headers.insert(.contentType, contentType)
        headers.insert(.transferEncoding, "chunked")
        return Response(status: status, headers: headers, body: .stream(stream))
    }
}
