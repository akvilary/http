HTTP — Swift port of the Rust `http` crate
============================================

Pure value types for the HTTP message model. Direct 1:1 port of
[**http** (Rust)](https://docs.rs/http):

- `Request<B>`, `Response<B>` — generic over body type
- `Method`, `StatusCode`, `Version` — typed wire enums
- `HeaderMap`, `HeaderName`, `HeaderValue` — case-insensitive multimap
- `Uri` — request target with path/query slicing
- `Extensions` — type-keyed per-request state

No I/O, no async, no codec — just the message types. The same role
the `http` crate plays in the Rust axum/hyper/tower ecosystem: hyper
depends on it for message types, axum depends on it for handler
signatures and extractors.

## Status

Early. Currently used by:

- [`starlight`](https://github.com/akvilary/starlight) — Swift port of axum.
- [`hyper`](https://github.com/akvilary/hyper) — Swift port of hyper (HTTP/1+ codec).

## Installation

```swift
.package(url: "https://github.com/akvilary/http.git", from: "0.2.0")
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "HTTP", package: "http"),
])
```

## License

MIT — see [LICENSE](LICENSE).
