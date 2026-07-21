// swift-tools-version: 6.2
//
//  http — Swift port of the Rust `http` crate.
//
//  Pure value types for the HTTP message model: `Request`, `Response`,
//  `HeaderMap`, `Method`, `StatusCode`, `Uri`, `Version`. No I/O, no
//  async — just the typed view of an HTTP message on the wire.
//
//  Direct 1:1 port of https://docs.rs/http — same types, same
//  semantics, same case-insensitive HeaderMap, same generic-over-body
//  Request<B> / Response<B>.
//
//  This is the foundation crate for the whole axum/hyper/tower
//  ecosystem in Rust, and the same role here: hyper depends on it
//  for the message types, Starlight (axum port) depends on it for
//  handler signatures and extractors.
//
import PackageDescription

let package = Package(
    name: "http",
    products: [
        .library(name: "HTTP", targets: ["HTTP"]),
    ],
    targets: [
        .target(
            name: "HTTP",
            path: "Sources/HTTP",
            swiftSettings: baseSwiftSettings
        ),
        .testTarget(
            name: "HTTPTests",
            dependencies: ["HTTP"],
            path: "Tests/HTTPTests",
            swiftSettings: baseSwiftSettings
        ),
    ]
)

// Swift 6.2 settings — load-bearing for the wider axum ecosystem:
// any consumer inherits these via the @inlinable surface.
var baseSwiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("StrictMemorySafety"),
    ]
}
