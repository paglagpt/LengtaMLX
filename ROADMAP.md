# PaglaMLX Roadmap

**Version:** 1.1  
**Status:** Living document; reviewed quarterly  
**Last updated:** 2026-09-01  
**Audience:** Contributors, maintainers, users, and integrators

## Vision

PaglaMLX is a native Apple Silicon inference engine and local API gateway. The project targets predictable, memory-aware inference on a 16 GB M2 Pro while preserving a familiar OpenAI-compatible interface and a focused macOS menu bar experience.

The v2 architecture removes Python from the runtime path. Swift owns process orchestration, HTTP, configuration, lifecycle, and UI integration; a narrow C-compatible boundary connects the core to MLX C++; and Metal kernels provide hardware-specific acceleration where profiling justifies it.

## Current baseline

The native Swift and C++ implementation is now the foundation for all upcoming work. The HTTP gateway runs in Swift-NIO, `EnginePool` owns model residency and memory-aware eviction, and the stub MLX bridge allows CI and route tests to run without production model files.

| Area | Current state | Near-term implication |
|---|---|---|
| Runtime | Native Swift plus C++ FFI | Do not reintroduce a Python gateway dependency. |
| HTTP | Swift-NIO HTTP/1.1 with OpenAI-shaped routes and SSE | Add route integration tests and backpressure handling. |
| Models | Actor-isolated `EnginePool` with LRU, pinning, TTL, and load suppression | Add request coalescing after behavior is covered by tests. |
| Configuration | Runtime and UI settings exist, with a Codable mirror planned | Establish one non-secret configuration model. |
| Credentials | Migration from legacy `UserDefaults` to macOS Keychain | Complete wiring and test write-before-delete semantics. |
| UI | SwiftUI menu bar application | Lock the visual contract with snapshot tests. |

## Delivery sequence

### v1.1 — Foundation and security (Q3 2026)

**Objective:** Make the native design navigable and remove plaintext credential persistence.

| Item | Category | Priority | Effort | Status |
|---|---|---:|---:|---|
| `ROADMAP.md` | Documentation | P0 | Low | Complete |
| `docs/architecture.md` | Documentation | P0 | Low | Complete |
| `KeychainStore.swift` | Security | P0 | Medium | Complete |
| UserDefaults-to-Keychain migration shim | Security | P0 | Medium | Complete |
| Unified `Codable` configuration model | Architecture | P1 | Medium | Planned |
| Troubleshooting guide | Documentation | P1 | Low | Planned |
| Swift rebuild-and-restart development script | Developer experience | P2 | Low | Planned |

**Exit criteria:** Every supported API credential has a Keychain mapping; migration deletes legacy values only after successful writes; the architecture document reflects actual source behavior; and CI remains independent of vendored MLX sources.

### v2.0 — Quality and deduplication (Q3–Q4 2026)

**Objective:** Make the server safe to evolve and eliminate redundant work under concurrent load.

| Item | Category | Priority | Effort | Status |
|---|---|---:|---:|---|
| HTTP integration tests for `HTTPServer.swift` | Testing | P0 | Medium | Planned |
| JSON request/response model hardening | Reliability | P0 | Medium | Planned |
| SwiftUI menu bar snapshot tests | Testing | P1 | Medium | Planned |
| `--mock` server mode for CI and demos | Testing | P1 | Low | Planned |
| Request coalescing in `EnginePool` | Performance | P1 | Medium | Planned |
| Model warm pool based on usage | Performance | P2 | High | Planned |
| Per-integration setup guides | Documentation | P2 | Medium | Planned |
| Loopback-only default and explicit remote-bind opt-in | Security | P1 | Low | Planned |

**Exit criteria:** Route handlers and JSON parsing have meaningful integration coverage; UI snapshots run on supported macOS CI; mock mode supports end-to-end tests without model files; and benchmark data demonstrates reduced duplicate prefill work.

### v2.1 — User-facing operations (Q4 2026)

**Objective:** Expose the information and controls users need to operate local and cloud-backed models confidently.

| Item | Category | Priority | Effort | Status |
|---|---|---:|---:|---|
| Token and estimated cost tracking dashboard | Features | P1 | Medium | Planned |
| First-run onboarding wizard | UX | P1 | Medium | Planned |
| Menu bar quick actions and context menu | UX | P1 | Low | Planned |
| System notifications for load, failure, and quota events | UX | P2 | Low | Planned |
| Model benchmark button | Features | P2 | Medium | Planned |
| Adaptive light/dark theme support | UX | P2 | Low | Planned |
| Opt-in redacted audit logging | Security | P2 | Medium | Planned |
| Searchable, opt-in conversation history | Features | P3 | High | Planned |

### v3.0 — Scheduler and streaming scale (Q1 2027)

**Objective:** Improve concurrency without violating memory budgets or responsiveness.

| Item | Category | Priority | Effort | Status |
|---|---|---:|---:|---|
| Production continuous-batching scheduler | Performance | P0 | High | Planned |
| Multi-model concurrency within measured memory budgets | Performance | P0 | High | Planned |
| Quantization-aware auto-router | Performance | P1 | Medium | Planned |
| Streaming backpressure and cancellation | Reliability | P1 | Medium | Planned |
| Plugin SDK for custom routers | Extensibility | P2 | High | Planned |
| Companion web UI | Features | P2 | High | Planned |

### v4.0 — Distribution and ecosystem (Q2 2027 and later)

| Item | Category | Priority | Effort | Status |
|---|---|---:|---:|---|
| Homebrew distribution | Distribution | P1 | Medium | Planned |
| SBOM and pinned release dependencies | Security | P1 | Medium | Planned |
| Opt-in anonymous telemetry | Growth | P2 | Medium | Planned |
| Community showcase and demo assets | Growth | P2 | Low | Planned |
| Internationalized documentation | Documentation | P2 | High | Planned |
| Neural Engine exploration | Performance | P3 | High | Research |
| Foundation Models fallback where appropriate | Compatibility | P3 | High | Research |

The former Python gateway binary is explicitly deprecated. It is not a future runtime milestone and should not be used as an architectural dependency.

## Suggestion mapping

The original proposal’s suggestions map to the native plan as follows.

| Suggestion | Native treatment |
|---|---|
| Decouple Python gateway | Complete by the native Swift-NIO server; no further work required. |
| Hot-reload gateway | Replace with a Swift rebuild-and-restart development script. |
| Unify configuration | v1.1 `Codable` configuration model and edge adapters. |
| Keychain storage | v1.1 `KeychainStore` and migration shim. |
| Loopback hardening and mTLS | Loopback default in v1.1/v2.0; mTLS remains a deployment research item. |
| Integration and snapshot tests | v2.0 test milestones. |
| Architecture documentation | `docs/architecture.md`, delivered in v1.1. |
| Token, cost, onboarding, benchmark, and menu bar polish | v2.1 user-facing operations. |
| Request coalescing and warm pool | v2.0 `EnginePool` work. |
| Streaming backpressure | v3.0 streaming reliability work. |
| Quantization-aware routing | v3.0 router work. |
| Web UI, plugins, SBOM, telemetry, community, and i18n | v3.0–v4.0 ecosystem milestones. |

## Prioritization rules

Security and data-loss prevention take precedence over convenience features. Work that reduces uncertainty—tests, typed boundaries, reproducible benchmarks, and operational documentation—comes before performance tuning. Changes that affect the FFI, memory ownership, credentials, or network exposure require a design update and a regression test before release.

Performance claims must be demonstrated on the target Apple Silicon configurations with model size, quantization, prompt length, generated token count, and memory pressure recorded. A faster benchmark that increases crash or eviction risk does not meet the project’s acceptance standard.

## Contribution workflow

Contributors should first read [`docs/architecture.md`](docs/architecture.md), select a roadmap item, and confirm its acceptance criteria before implementation. Changes should remain scoped, include tests where behavior changes, and avoid adding secrets, prompts, or generated content to logs. The stub bridge is the default path for local and CI validation; production MLX linkage is required only for hardware validation.

## Changelog

| Date | Version | Change |
|---|---|---|
| 2026-09-01 | 1.1 | Reframed the roadmap around the native Swift-NIO architecture; added Tier 1 security, testing, and performance sequencing. |
