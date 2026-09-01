# PaglaMLX 2.0 Architecture

**Status:** Living design document  
**Audience:** Contributors, maintainers, integrators, and operators  
**Last updated:** 2026-09-01

## 1. Scope and design goals

PaglaMLX 2.0 is a native macOS inference service for Apple Silicon. The runtime is implemented in Swift, with a narrow C-compatible bridge into the MLX C++ runtime and a Swift-NIO HTTP server exposing an OpenAI-compatible API. The menu bar application, command-line interface, server, scheduler, and tests share the same headless core rather than communicating through a Python sidecar.

The architecture optimizes for four properties: low process overhead, predictable memory use on 16 GB unified-memory Macs, a small security boundary, and testability without requiring model files or the production MLX runtime. Swift actors provide the default isolation boundary; the C ABI keeps ownership and interop explicit; and the server binds to loopback by default.

> **Source of truth:** This document describes the intended contracts of the current native implementation. Where a future capability is mentioned, it is marked as planned rather than presented as implemented.

## 2. Repository and target layout

| Component | Responsibility | Runtime boundary |
|---|---|---|
| `PaglaMLXCore` | Engine pool, memory enforcement, decoding, HTTP server, configuration, and secure credential access | Headless Swift library |
| `MLXBridge` | C-compatible ownership and inference functions over MLX C++ | Swift ↔ C/C++ FFI |
| `PaglaMLXMetal` | Custom Metal kernels and Swift dispatch wrappers | Swift ↔ Metal |
| `PaglaMLXApp` | Menu bar UI, settings, status, and user actions | SwiftUI/AppKit |
| `PaglaMLXCLI` | `serve`, `status`, benchmark, and operational commands | Command line |
| `PaglaMLXBench` | Repeatable performance measurements | Command line |

The core target must not depend on SwiftUI or AppKit. This keeps server and test execution independent from the menu bar process and makes the headless engine usable by both the CLI and future service wrappers.

## 3. Process and startup model

The normal native startup path is:

1. The CLI or application resolves runtime configuration, including host, port, memory budget, model directory, and request limits.
2. `SystemResourceEnforcer` is created to establish the memory policy for the host.
3. The MLX bridge creates the engine context. In CI and development, the stub bridge can be used without vendored MLX sources.
4. `EnginePool` is initialized with the engine and resource enforcer, then its background TTL sweep is started.
5. `HTTPServer` is initialized with the pool and `HTTPServer.Configuration`, binds the configured loopback address, and transitions from `.starting` to `.running`.
6. The process remains alive until cancellation or an operational stop command closes the server channel and stops the pool sweep.

The application and the server may share the core in one process. The CLI is also able to host the same server without the UI. There is no Python gateway, uvicorn process, or HTTP hop between the server and the engine.

## 4. Request lifecycle

### 4.1 HTTP ingress

Swift-NIO accepts an HTTP/1.1 connection through `MultiThreadedEventLoopGroup.singleton`. Each channel configures the HTTP server pipeline and installs the request handler. Request head and body parts are accumulated until `.end`; malformed requests are rejected with `400 Bad Request`.

The current routes are:

| Method | Path | Behavior |
|---|---|---|
| `GET` | `/healthz` | Returns a plain-text liveness response. |
| `GET` | `/v1/models` | Returns currently resident model names in OpenAI list format. |
| `GET` | `/metrics` | Returns minimal Prometheus exposition text. |
| `POST` | `/v1/chat/completions` | Generates a completion, or emits SSE when `Accept: text/event-stream` is supplied. |
| `POST` | `/v1/completions` | Generates a text completion. |

Unknown routes return `404`. Invalid UTF-8 or malformed bodies return `400`. Engine failures are converted to `500` responses without terminating the server process.

### 4.2 Dispatch and isolation

The channel handler launches an asynchronous task after the complete request body is received. The task performs route dispatch and awaits actor-isolated `EnginePool` operations. This prevents synchronous request parsing from blocking the NIO event loop while preserving a single mutation owner for model state.

The current body extraction is intentionally small and fast, but it is not a general JSON parser. Production hardening should replace the regular-expression extraction with `Codable` request and response models before accepting arbitrary escaped strings, nested message content, or large payloads.

### 4.3 Engine acquisition

For a completion, `EnginePool` locates the requested resident model, calls `acquire`, and updates recency and request count. If the model is not resident, the pool loads it after making memory available through its eviction policy. The generated text is returned as an OpenAI-shaped JSON response.

The pool is an actor. Its `slots`, LRU ordering, loading set, and event stream are therefore mutated serially. A loading set suppresses duplicate concurrent loads of the same model. Request coalescing for identical inference work is planned, but is not yet part of the current contract.

### 4.4 Streaming

Streaming uses Server-Sent Events. The server writes an HTTP response head, emits one `data:` event per generated token, writes `data: [DONE]`, and flushes the response end. The engine exposes an `AsyncThrowingStream<String, Error>` for this path.

The current implementation writes each token directly to the channel. Explicit writability checks, bounded buffering, cancellation propagation, and a NIO backpressure handler are planned for the streaming-hardening milestone.

## 5. EnginePool and memory policy

`EnginePool` maintains model slots containing the opaque MLX model pointer, memory footprint, timestamps, pin state, TTL, and request count. The first item in the LRU list is the most recently used model. Unpinned models may be unloaded when the enforcer reports insufficient headroom or when their TTL expires.

| Policy | Current behavior |
|---|---|
| Residency | Models are loaded on demand and retained in actor-owned slots. |
| Eviction | Least-recently-used, excluding pinned models. |
| Cleanup | A periodic sweep unloads expired, non-pinned models. |
| Memory accounting | Pool footprint is combined with a current process-resident estimate. |
| Duplicate loads | The `loading` set prevents duplicate load work for the same model. |
| Concurrent inference | Serialized through the actor’s state boundary; richer scheduling is planned. |

The memory target is a 16 GB M2 Pro configuration, so memory pressure is a first-class failure condition rather than an exceptional afterthought. A load may fail when pinned models and the requested model cannot fit within the configured budget. Such errors are surfaced to the HTTP layer as request failures and logged with operational context, without including credential values.

## 6. MLX FFI boundary

The Swift core communicates with MLX through `MLXBridge`, a narrow C-compatible surface. Swift receives opaque engine and model handles and passes primitive buffers and scalar options across the boundary. The bridge owns the C-side allocation contract; Swift releases model handles through the imported deinitializer when a `ModelSlot` is destroyed.

The bridge has two build modes:

| Mode | Purpose |
|---|---|
| Stub | CI, local development, and route tests without vendored MLX sources. |
| Real | Production inference using the vendored MLX C++ implementation and Metal support. |

The FFI must remain narrow. Swift code should not depend on MLX C++ implementation details, and C++ code should not call into Swift UI or configuration types. Any new boundary function must document pointer ownership, buffer lifetime, thread-safety assumptions, and error mapping.

## 7. Port and network strategy

The default endpoint is `127.0.0.1:2525`. The loopback default is deliberate: API credentials and prompts are local application data, and an accidental wildcard bind would expose them to the LAN. The `Configuration` object still accepts a host value for controlled deployments, but operators should treat non-loopback binding as an explicit security decision.

Binding uses `SO_REUSEADDR`, a configured backlog, and `TCP_NODELAY`. A bind failure transitions the server to `.failed(String)` and is rethrown to the caller, allowing the CLI or UI to present an actionable error. A future hardening change should validate the host and require an explicit opt-in for non-loopback addresses.

## 8. Credential storage and configuration

Secrets are stored by `KeychainStore` in the macOS Keychain as generic-password items. Each item uses the service `com.paglaai.paglamlx`, a stable provider-specific account, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Non-secret runtime settings may remain in the configuration layer or `UserDefaults`; API keys and bearer tokens must not.

The v1 migration is one-way and idempotent. On first startup after upgrade, known legacy credential keys are read from `UserDefaults`, copied to Keychain only when the corresponding Keychain item is absent, and removed from `UserDefaults` only after a successful write. If a write fails, the legacy value is retained so the user can retry rather than losing access. Migration errors are reported without printing secret values.

| Credential | Keychain account |
|---|---|
| Gateway bearer token | `paglamlx.bearer` |
| OpenAI | `paglamlx.openai` |
| Anthropic | `paglamlx.anthropic` |
| OpenRouter | `paglamlx.openrouter` |
| Groq | `paglamlx.groq` |
| Together | `paglamlx.together` |
| Gemini | `paglamlx.gemini` |
| DeepSeek | `paglamlx.deepseek` |
| Mistral | `paglamlx.mistral` |
| Perplexity | `paglamlx.perplexity` |
| Cohere | `paglamlx.cohere` |
| Fireworks | `paglamlx.fireworks` |
| Hyperbolic | `paglamlx.hyperbolic` |
| SambaNova | `paglamlx.sambanova` |

Configuration should be represented once as a `Codable` model and adapted to UI bindings, CLI arguments, and environment overrides at the edges. The secure store is deliberately independent of that model: configuration carries references and non-secret preferences, while KeychainStore owns secret persistence.

## 9. Failure modes and recovery

| Failure | Detection | Recovery contract |
|---|---|---|
| Port unavailable | NIO bind throws | Server enters `.failed`; caller may retry with another port. |
| Malformed request | Missing head/body or invalid UTF-8 | Return `400`; keep the channel alive where safe. |
| Unknown route | Route table miss | Return `404`. |
| Model not resident | EnginePool throws `modelNotResident` | Return an engine error; load explicitly before retrying. |
| Memory budget exceeded | Enforcer cannot free enough memory | Reject the load/request and preserve resident pinned models. |
| Keychain unavailable | Security framework status | Keep legacy credential during migration and report a redacted error. |
| Client disconnects during stream | Channel cancellation/closure | Stop emitting and propagate cancellation to the stream in the backpressure milestone. |
| Native bridge failure | Non-success FFI status | Map to a typed engine error; do not crash the server. |

## 10. Observability

The server currently exposes liveness, loaded-model count, estimated memory usage, and a placeholder request counter at `/metrics`. The engine emits typed events for load, unload, pin, and unpin operations for UI and logging consumers. Structured logs use `swift-log` labels rather than ad hoc process-wide logging.

Token accounting, request latency, provider cost, and durable audit logging are roadmap items. Until those are implemented, logs must avoid prompts, generated content, bearer tokens, and provider API keys.

## 11. Testing strategy

The stub MLX bridge enables deterministic tests without downloading model files. The next quality milestone should add HTTP integration tests that exercise health, model listing, malformed JSON, unknown routes, completion errors, and SSE framing. UI snapshot tests should lock the menu bar’s visual contract separately from core tests.

Tests must not depend on a developer’s Keychain. KeychainStore should receive an injectable storage backend or use a test-specific service/account namespace. Migration tests should verify the important invariant: a UserDefaults secret is deleted only after its Keychain write succeeds.

## 12. Planned evolution

The roadmap prioritizes documentation and secure storage first, then route integration tests, UI snapshots, and request coalescing. Later work includes token and cost tracking, onboarding, benchmarks, streaming backpressure, model warm pools, and a plugin SDK. The Python gateway is not a future compatibility target; the native Swift server is the supported runtime architecture.

## References

[1]: https://github.com/apple/swift-nio "Apple SwiftNIO"
[2]: https://developer.apple.com/documentation/security/keychain_services "Apple Keychain Services Documentation"
[3]: https://developer.apple.com/documentation/swift/actor "Swift Actor Documentation"
[4]: https://spec.openapis.org/oas/latest.html "OpenAPI Specification"
