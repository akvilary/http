// swift-tools-version: 6.2
//
//  http — Swift port of the Rust `http` crate.
//
//  Pure value types for the HTTP message model: `Request`, `Response`,
//  `HeaderMap`, `Method`, `StatusCode`, `Uri`, `Version`. No I/O, no
//  async — just the typed view of an HTTP message on the wire.
//
//  Direct 1:1 port of https://docs.rs — same types, same
//  semantics, same case-insensitive HeaderMap. Unlike the Rust
//  crate, `Request` and `Response` are not generic over body —
//  the concrete `Body` enum covers all representations.
//
//  This is the foundation crate for the whole axum/hyper/tower
//  ecosystem in Rust, and the same role here: hyper depends on it
//  for the message types, Starlight (axum port) depends on it for
//  handler signatures and extractors.
//
import PackageDescription

let package = Package(
    name: "http-model",
    products: [
        .library(name: "HTTPModel", targets: ["HTTPModel"]),
    ],
    targets: [
        .target(
            name: "HTTPModel",
            path: "Sources/HTTPModel",
            swiftSettings: baseSwiftSettings
        ),
        .testTarget(
            name: "HTTPModelTests",
            dependencies: ["HTTPModel"],
            path: "Tests/HTTPModelTests",
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
