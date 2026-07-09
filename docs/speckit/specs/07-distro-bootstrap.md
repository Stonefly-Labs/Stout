# Spec 07 — Distro / One-Call Bootstrap Convenience Layer

Pass the prompt below to `/speckit.specify`.

---

Build the **distro / one-call bootstrap convenience layer** for `stout`, a collector-free, open-source Azure Monitor / Application Insights exporter for server-side Swift (Linux + macOS, Swift 6). This is the primary consumer entry point: the single, ergonomic API that a developer calls at application startup to configure and bootstrap the tracing, logging, and metrics backends together (and optionally Live Metrics) from a single Application Insights **connection string**, with a clean graceful-shutdown hook. It mirrors the ergonomics of the .NET Azure Monitor distro (`AddAzureMonitor` / `UseAzureMonitor`).

This feature **composes and configures** the sibling specs — core (01), tracing (02), logging (03), metrics (04), durable delivery/sampling/auth (05), and optionally Live Metrics (06). It MUST NOT reimplement any of them. It owns only the composition surface: the public options value, the bootstrap call, the wiring of each signal backend into its SSWG facade, and the coordinated shutdown.

> Locked design decisions: see design.md §11 (D1–D4). This spec reflects D1 (lifecycle/shutdown: drain-and-go-inert, injectable backends as the testability seam, inert post-shutdown handlers) and D3 (swift-service-lifecycle ships as an optional additive target, never a core dependency).

## Overview / Why

Getting telemetry into Application Insights should take a few lines. Today a consumer would have to individually construct the core exporter, register the `Tracer` with `swift-distributed-tracing`, register the `LogHandler` with `swift-log`, register the `MetricsFactory` with `swift-metrics`, wire resource attributes and sampling into each, and remember to flush all of them on shutdown — a lot of boilerplate, easy to get wrong, and easy to leave a pipeline unflushed on exit. The Microsoft distros (.NET/Java/Node/Python) solve this with a single bootstrap call. This feature delivers the same one-call experience for server-side Swift.

The value is **developer experience and correctness by default**: a developer adds the package, calls one bootstrap function with a connection string (and optionally an options value), and immediately gets traces, logs, and metrics flowing to Application Insights — configured with secure, sensible defaults, and with a single shutdown handle that flushes every enabled pipeline. Because this is the surface most consumers touch first, its API clarity, defaults, and documentation carry outsized weight.

## Consumer scenarios

1. **Minimal one-call bootstrap.** A developer reads an Application Insights connection string from an environment variable and calls a single entry point (illustratively `Stout.bootstrap(connectionString:)`) at app startup. Traces, logs, and metrics are all enabled by default and begin flowing to Application Insights. The call registers the tracing, logging, and metrics backends with their respective SSWG facades so existing instrumentation (Vapor, Hummingbird, gRPC-swift, app code) lights up without touching library internals. The call returns a handle the developer holds for shutdown.

2. **Bootstrap with explicit options.** A developer constructs an options value to customize behavior — enabling/disabling individual signals, setting the cloud role name and role instance (resource attributes), setting a sampling rate, choosing an auth mode, and (opt-in) enabling Live Metrics — then passes it to the bootstrap call. Any field left unset uses a secure, sensible default.

3. **Partial enablement.** A developer disables one or more signals (e.g. metrics off, or only tracing on). Only the enabled backends are constructed and registered with their facades; the disabled signals register nothing (or a documented no-op) and consume no export resources. Shutdown flushes exactly the enabled pipelines and nothing else.

4. **Live Metrics opt-in.** By default Live Metrics is **off**. A developer opts in via options; the bootstrap additionally starts the Live Metrics (QuickPulse) side-channel using the `LiveEndpoint` from the same connection string. If Live Metrics is not enabled, no Live Metrics endpoint contact occurs.

5. **Graceful shutdown flushes everything.** At application exit, the developer invokes the shutdown handle (directly, or via a service-lifecycle integration). Every enabled pipeline — traces, logs, metrics, and Live Metrics if enabled — flushes its pending telemetry best-effort within a bounded timeout, in-flight requests complete, and all resources are released. Shutdown never crashes or hangs the host, and is idempotent.

6. **Service-lifecycle integration.** A developer using a service lifecycle manager (e.g. swift-service-lifecycle) registers the bootstrap result as a managed service/resource so startup and coordinated graceful shutdown happen automatically as part of the application's lifecycle, without hand-writing a shutdown hook. Per D3, this integration ships as an **optional additive target** (e.g. `StoutServiceLifecycle`) and is **never** a core dependency: the core distro provides dependency-free graceful shutdown (D1), and opt-in users add the target for ordered start/stop.

7. **Optional web-framework middleware (enhancement).** A Vapor or Hummingbird developer additionally opts into lightweight request middleware that begins/ends a server span per request and correlates request-scoped logs to that span. This is a clearly separable enhancement — the core bootstrap works fully without it, and the middleware is only compiled/available when the consumer opts in.

8. **Misconfiguration fails closed.** A developer passes an empty, malformed, or secret-missing connection string, or selects Entra auth without the information that mode requires. The bootstrap fails closed with a clear, **secret-free** error and does NOT start any pipeline in a partially-configured or insecure state. No half-bootstrapped facades are left registered.

## Functional requirements

### Single entry point / bootstrap

- Provide a single public entry point that takes an Application Insights **connection string** and an optional **options** value, and in one call configures and bootstraps the enabled signal backends. Provide a convenience overload that takes just the connection string and uses all defaults.
- The bootstrap MUST parse/validate the connection string via the core (spec 01) and MUST fail closed on invalid input before starting any pipeline.
- The bootstrap constructs each enabled signal backend by composing the sibling modules — it MUST NOT reimplement translation, transport, pipeline, or protocol logic.
- Registering the backends with their SSWG facades:
  - Tracing → bootstrap the `swift-distributed-tracing` instrumentation system / tracer with the tracing backend (spec 02).
  - Logging → bootstrap the `swift-log` logging system with the logging backend (spec 03).
  - Metrics → bootstrap the `swift-metrics` metrics system with the metrics backend (spec 04).
- [NEEDS CLARIFICATION: the SSWG facades (`LoggingSystem.bootstrap`, `MetricsSystem.bootstrap`, `InstrumentationSystem.bootstrap`) are process-global and documented as one-time-only. Define the contract when a consumer calls bootstrap more than once, or when a facade was already bootstrapped by someone else — options: throw/fail closed, log a self-diagnostic and skip that facade, or provide an explicit "already-bootstrapped is an error" flag. Also define testability: a way to construct the composed backends without mutating process-global facade state so the layer is unit-testable.]
- Return a single **shutdown handle** (a `Sendable` value) that owns the coordinated flush/teardown of exactly the pipelines that were enabled.

### Options value

- Provide a public, `Sendable` options value with secure, sensible defaults for every field, such that a consumer can bootstrap with connection string only and get a safe configuration. All defaults MUST be documented.
- **Per-signal enable/disable**: independently enable or disable tracing, logging, and metrics. Default: all three **enabled**.
- **Live Metrics enable/disable**: default **off** (opt-in only).
- **Resource attributes**: set the cloud role name (`service.name`/`service.namespace` → `ai.cloud.role`) and role instance (`service.instance.id`/`host.name` → `ai.cloud.roleInstance`), forwarded to core resource detection (spec 01). Unset values fall back to the core's auto-detection.
- **Sampling rate**: set the fixed-rate ingestion sampling percentage, forwarded to the sampling behavior owned by specs 01/05. Default: no sampling (100%). Validate the rate is within a valid range and fail closed (or clamp with a self-diagnostic — [NEEDS CLARIFICATION: clamp vs reject an out-of-range sampling rate]).
- **Auth mode**: select between instrumentation-key auth (from the connection string) and Entra (AAD token) auth, forwarded to spec 05. Default: **instrumentation-key** auth from the connection string. When Entra is selected, the required credential/token-source input MUST be supplied; if it is missing, fail closed with a secret-free error. [NEEDS CLARIFICATION: how the token credential/source is supplied to the options — an abstract credential-provider value defined by spec 05, referenced here.]
- Options MUST be extensible for future knobs (e.g. batch/flush tuning) without a source-breaking change; expose only what a consumer needs, and forward the rest to sibling defaults.
- Options MUST NOT contain or echo secret material in any description, debug, or diagnostic representation.

### Graceful shutdown

- The bootstrap returns a shutdown handle whose invocation flushes **every enabled pipeline** (traces, logs, metrics, and Live Metrics if enabled) best-effort within a bounded, configurable timeout, awaits in-flight exports, and releases all resources (HTTP clients, background loops/tasks).
- Shutdown MUST be **idempotent** (a second call is a safe no-op) and MUST NOT crash or hang the host process even if a pipeline's flush fails or times out. A failure in one pipeline's flush MUST NOT prevent the others from flushing.
- Shutdown ordering MUST ensure the SSWG facades stop emitting into (or safely no-op against) torn-down backends, so no telemetry is emitted into a released pipeline. Per D1 (drain-and-go-inert), because facade bootstrap is process-global and effectively irreversible, the un-removable registered handlers become safe **inert no-ops** after shutdown: post-shutdown emission is dropped after a single rate-limited warning via the library's internal diagnostics channel — never re-entering the user telemetry pipeline and never carrying payload or secrets — and never crashes or blocks the host.

### Service-lifecycle integration (optional)

- Provide integration so the bootstrap result can participate in a service lifecycle manager (e.g. swift-service-lifecycle) for coordinated startup and graceful shutdown. Per D3, this integration MUST ship as a **separate optional additive target** (e.g. `StoutServiceLifecycle`) that depends on swift-service-lifecycle; the **core distro MUST NOT depend on swift-service-lifecycle**. The core distro's own graceful shutdown (D1) is dependency-free; the optional target adds ordered start/stop for opt-in users.

### Web-framework middleware (optional enhancement, separable)

- Provide optional, lightweight request middleware for Vapor and/or Hummingbird that starts a server span per incoming request (via the tracing facade), ends it with request outcome/status, and correlates request-scoped logs to the active span.
- This MUST be clearly separable: distinct, opt-in module target(s) so that a consumer who does not use Vapor/Hummingbird pays no dependency cost, and the core bootstrap has no dependency on any web framework.
- The middleware MUST rely on the already-registered tracing/logging backends (it emits through the SSWG facades) and MUST NOT contain its own translation or transport logic. [NEEDS CLARIFICATION: which frameworks and versions are in scope for v1 — Vapor, Hummingbird, both, or defer to a follow-up.]

## Non-functional / quality requirements (OSS — non-negotiable)

**Security**
- Connection strings, instrumentation keys, and Entra tokens are **secrets**: they MUST NEVER be logged, MUST NEVER appear in error messages, exception text, self-diagnostics, or the options/handle description or debug output. Redact on any diagnostic path.
- **Secure defaults**: default configuration is safe without further tuning — Live Metrics off, HTTPS-only (inherited from core), instrumentation-key auth from the connection string, no sampling unless requested.
- **Fail closed on misconfiguration**: invalid connection string, invalid options (e.g. out-of-range sampling if reject-mode, Entra selected without a credential) MUST prevent any pipeline from starting and MUST NOT leave a partially-bootstrapped or insecure state.
- Keep dependencies minimal and auditable; the core distro pulls in only the sibling modules plus the SSWG facades. Optional framework/lifecycle dependencies live behind separable targets so they are not forced on all consumers.

**Stability**
- Swift 6 **strict concurrency**: the options value and shutdown handle are `Sendable`; no data races. Bootstrap and shutdown are safe to call once from app setup/teardown.
- Setup and teardown MUST NEVER crash or block the host application. A failure to reach the ingestion endpoint at startup MUST NOT crash bootstrap; telemetry degrades gracefully (behavior owned by core).
- **Graceful shutdown flushes ALL enabled pipelines**, is idempotent, is bounded in time, and never hangs the host — even if an individual pipeline fails to flush.
- Partial enablement MUST be robust: disabled signals allocate/register nothing that must later be torn down, and shutdown handles exactly the set that was enabled.

**Quality**
- High test coverage including, at minimum: minimal bootstrap (all defaults), each partial-enablement combination (each signal individually on/off, all-off), Live Metrics on/off, resource-attribute and sampling-rate forwarding, auth-mode selection incl. Entra-without-credential failure, misconfiguration fail-closed paths, idempotent shutdown, shutdown flushing exactly the enabled pipelines, and shutdown resilience when one pipeline's flush fails/times out.
- Tests MUST verify no secret material appears in any error, log, or diagnostic emitted by the layer.
- **Excellent docs & ergonomics**: this is the primary consumer entry point — a documented quick-start (add package → one call → shutdown), a documented options reference with every default, and clear guidance on partial enablement and lifecycle integration.
- Clear, documented **public API** boundary; SemVer discipline.

## Acceptance criteria

1. `Stout.bootstrap(connectionString:)` (illustrative) with a valid connection string and no options enables tracing, logging, and metrics by default, registers each with its SSWG facade, and returns a shutdown handle — in a single call.
2. Emitting a trace/log/metric through the SSWG facades after a default bootstrap results in that telemetry flowing to Application Insights (via the composed sibling backends), with no direct consumer contact with library internals.
3. With options disabling a signal, only the enabled backends are constructed and registered; the disabled signal registers nothing (or a documented no-op) and is not present in the shutdown flush set. All partial-enablement combinations behave correctly.
4. Live Metrics is off by default and no `LiveEndpoint` contact occurs unless it is explicitly enabled in options; when enabled, the Live Metrics side-channel starts using the connection string's `LiveEndpoint`.
5. Resource attributes (cloud role/instance) and sampling rate set in options are forwarded to the composed backends; unset resource values fall back to core auto-detection; unset sampling means no sampling.
6. Auth mode defaults to instrumentation-key from the connection string; selecting Entra without the required credential fails closed with a **secret-free** error and starts no pipeline.
7. An empty/malformed/secret-missing connection string fails bootstrap closed with a clear, secret-free error and leaves no facade registered and no pipeline running.
8. Invoking the shutdown handle flushes every enabled pipeline within the bounded timeout, completes in-flight exports, releases all resources, and does not hang; a second invocation is a safe no-op.
9. If one enabled pipeline's flush fails or times out during shutdown, the other enabled pipelines still flush and shutdown still completes without crashing or hanging.
10. No error, log, options description, handle description, or diagnostic emitted by this layer ever contains the connection string, iKey, or any token.
11. The core distro target has no compile-time dependency on any web framework or (if so decided) on swift-service-lifecycle; the optional middleware and lifecycle integrations live in separable targets.
12. The options value, shutdown handle, and public bootstrap API compile clean under Swift 6 strict concurrency (`Sendable`, no data-race warnings).

## Out of scope (sibling specs)

- **Core ingestion foundation** — connection-string parse/validation, Breeze envelope model, buffering/batching pipeline, resource detection, HTTP transport (spec 01). This layer *forwards to* and *composes* it; it does not reimplement it.
- **Tracing backend** — `Tracer`, span → `RequestData`/`RemoteDependencyData`/`ExceptionData` translation, W3C traceparent propagation (spec 02).
- **Logging backend** — `LogHandler`, `MessageData`/`ExceptionData`, severity mapping, span correlation (spec 03).
- **Metrics backend** — `MetricsFactory`, `MetricData`, histograms/dimensions (spec 04).
- **Durable delivery, ingestion sampling logic, and auth** — disk-backed offline store, fixed-rate sampling decisions, and Entra/AAD token authentication mechanics (spec 05). This layer only exposes the *knobs* (sampling rate, auth mode) and forwards them.
- **Live Metrics / QuickPulse protocol** — the ping/post state machine, `MonitoringDataPoint`/`DocumentIngress` model, and filtering DSL (spec 06). This layer only *enables/disables* it and hands it the connection string.

This spec COMPOSES and configures all of the above; it does not reimplement any of them.

## Open questions

- **Process-global facade bootstrap semantics.** `swift-log`, `swift-metrics`, and `swift-distributed-tracing` facades are bootstrapped once per process and are effectively irreversible. **Resolved by D1:** the post-shutdown emission contract is drain-and-go-inert — the un-removable registered handlers become safe inert no-ops, dropping post-shutdown emission after a single rate-limited internal-diagnostics warning; and the backends are independently-constructable, injectable objects so the composed pipelines can be built and unit-tested without mutating global facade state (the global `bootstrap()` is a thin layer over them). Still open: exact behavior on double bootstrap and when a facade was already bootstrapped externally — throw/fail closed vs self-diagnostic-and-skip vs an explicit "already-bootstrapped is an error" flag. [NEEDS CLARIFICATION: double-bootstrap / externally-bootstrapped-facade behavior]
- **swift-service-lifecycle dependency.** **Resolved by D3:** lifecycle integration ships as an optional additive target (e.g. `StoutServiceLifecycle`); the core distro never depends on swift-service-lifecycle and provides dependency-free graceful shutdown (D1).
- **Web-framework scope for v1.** Vapor, Hummingbird, both, or defer middleware entirely to a follow-up — and which versions. [NEEDS CLARIFICATION]
- **Entra credential supply.** Exactly how the token credential/source (defined by spec 05) is passed through the options value. [NEEDS CLARIFICATION]
- **Out-of-range sampling rate.** Reject (fail closed) vs clamp-with-self-diagnostic. [NEEDS CLARIFICATION]
- **Bootstrap API shape / naming.** Confirm the public entry-point name and shape (e.g. static `Stout.bootstrap` vs a configurator builder) and the shutdown-handle type, to best mirror the .NET distro ergonomics while fitting Swift conventions. [NEEDS CLARIFICATION]
