//===----------------------------------------------------------------------===//
//
//  Response.swift
//  StarlightHTTP
//
//  HTTP response — direct port of `http::Response<B>`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// HTTP response, parameterised over the body type.
///
/// Like `Request<B>`, generic over body so the codec can stream
/// chunks while handlers see a fixed-buffer body.
public struct Response<B: Sendable>: Sendable {
    public var status: StatusCode
    public var version: Version
    public var headers: HeaderMap
    public var body: B
    public var extensions: Extensions

    @inlinable
    public init(
        status: StatusCode = .ok,
        version: Version = .http11,
        headers: HeaderMap = HeaderMap(),
        body: B,
        extensions: Extensions = Extensions()
    ) {
        self.status = status
        self.version = version
        self.headers = headers
        self.body = body
        self.extensions = extensions
    }
}

/// Concrete alias — what handlers return.
public typealias OutgoingResponse = Response<Body>

extension Response where B == Body {
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
    public static func plain(_ body: String, status: StatusCode = .ok) -> Response<Body> {
        var headers = HeaderMap()
        headers.insert(.contentType, "text/plain; charset=utf-8")
        headers.insert(.contentLength, String(body.utf8.count))
        return Response(status: status, headers: headers, body: .buffered(Array(body.utf8)))
    }

    /// Standard 200 OK with a raw byte body.
    public static func bytes(_ bytes: [UInt8], status: StatusCode = .ok) -> Response<Body> {
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
    ) -> Response<Body> {
        var headers = HeaderMap()
        headers.insert(.contentType, contentType)
        headers.insert(.transferEncoding, "chunked")
        return Response(status: status, headers: headers, body: .stream(stream))
    }
}
