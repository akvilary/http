//===----------------------------------------------------------------------===//
//
//  ConnectInfo.swift
//  HTTP
//
//  Connection-level metadata — the peer's socket address. Set by the
//  server when a connection is accepted. Stored in Request.extensions.
//
//===----------------------------------------------------------------------===//

import Foundation

/// Peer socket address, set by the server on connection accept.
///
/// Direct port of `axum::extract::ConnectInfo<Addr>`. The worker
/// stashes the peer address in `Request.extensions` — extractors and
/// middleware read it from there.
///
/// ```swift
/// router.get("/whoami") { (ci: ConnectInfo) in
///     return .plain("peer: \(ci.description)")
/// }
/// ```
public struct ConnectInfo: Sendable, CustomStringConvertible {
    /// Best-effort peer address string — typically "ip:port".
    public let peerAddress: String

    @inlinable public init(peerAddress: String) {
        self.peerAddress = peerAddress
    }

    public var description: String { peerAddress }
}

/// Extension point for the server. The worker calls this on each
/// accepted connection to stash the peer address in the request.
@inlinable
public func setConnectInfo(_ peerAddress: String, on request: inout Request) {
    request.extensions.insert(ConnectInfo(peerAddress: peerAddress))
}
