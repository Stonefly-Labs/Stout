<!--
Sync Impact Report
==================
Version change: (unfilled template) → 1.0.0
Rationale: Initial ratification — the template placeholders are replaced with the
seven governing principles supplied by the project constitution prompt
(docs/speckit/constitution.md). MAJOR baseline for a first adopted constitution.

Framing reconciliation (substance of every MUST/MUST NOT preserved verbatim):
The source prompt predates locked decisions D7 (platforms: iOS + macOS + watchOS +
tvOS + visionOS + Linux, not server-only) and D8 (build on opentelemetry-swift and
implement its public SpanExporter/MetricExporter/LogRecordExporter protocols;
supersedes the earlier swift-log / swift-metrics / swift-distributed-tracing SSWG
facade design). Per CLAUDE.md — which is authoritative and forbids reintroducing
those facades — the preamble and platform/CI references are stated in terms of the
opentelemetry-swift exporter model and the full platform matrix. No principle was
weakened; Principle 4's CI scope was broadened from "Linux and macOS" to include the
iOS Simulator, matching D6/D7.

Modified principles: none renamed. Seven principles added (Security-First;
Resilience & Do-No-Harm; Concurrency Safety; Quality & Testing; API Stewardship;
Fidelity; OSS Governance).
Added sections: Additional Constraints & Compliance; Development Workflow & Quality
Gates; Governance.
Removed sections: none (template placeholder sections replaced in place).

Templates requiring updates:
- ✅ .specify/templates/plan-template.md — Constitution Check is a generic
  per-feature gate placeholder; no stale platform/facade references. No change.
- ✅ .specify/templates/spec-template.md — no constitution/platform references. No change.
- ✅ .specify/templates/tasks-template.md — no constitution/platform references. No change.
- ✅ .specify/templates/commands/*.md — directory empty; nothing to reconcile.

Follow-up TODOs: none. RATIFICATION_DATE set to the initial adoption date (today).
-->

# Stout Constitution

Stout is a **collector-free**, open-source Azure Monitor / Application Insights
telemetry **exporter for `opentelemetry-swift`** (the OpenTelemetry Swift SDK),
written in **Swift 6**. It runs everywhere `opentelemetry-swift` runs — **iOS,
macOS, watchOS, tvOS (+ visionOS), and Linux** — implementing that SDK's public
`SpanExporter` / `MetricExporter` / `LogRecordExporter` protocols, translating
telemetry into the Application Insights **"Breeze"** schema, and POSTing directly to
ingestion — no OpenTelemetry Collector, no Azure Monitor Agent. Because this library
handles customer credentials and runs inside customers' production services **and on
end-user devices**, **security, stability, and quality outrank speed and feature
count at all times.**

These principles are durable and binding. They constrain every spec, plan, and pull
request that follows. Each principle below is testable; treat every "MUST"/"MUST NOT"
as a non-negotiable acceptance criterion that CI, code review, and specs are required
to enforce. Where a principle cannot be met, the work does not ship — **telemetry
loss is always preferable to violating a principle.**

## Core Principles

### I. Security-First (NON-NEGOTIABLE)

- Connection strings, instrumentation keys, and Entra/AAD tokens are secrets. Library
  code **MUST NOT** log them, include them in error messages or thrown errors, surface
  them in the library's own self-diagnostics/telemetry, or write them to any persisted
  store in cleartext. Redaction MUST be the default and MUST be covered by tests.
- All configuration and external input (connection strings, endpoints, response
  bodies, attributes) **MUST** be validated and **fail closed**: reject malformed or
  ambiguous input rather than guessing or proceeding with partial state.
- The library **MUST** be secure-by-default: TLS/HTTPS-only transport to ingestion and
  control endpoints, no insecure fallback, and no configuration option that weakens
  security silently.
- Dependencies **MUST** be minimal and audited; every new runtime dependency requires
  explicit justification in the PR. Prefer the approved runtime dependency posture
  described in the design (`opentelemetry-swift` plus the platform transport split)
  over adding more.
- A responsible security-disclosure process (SECURITY.md with a private reporting
  channel and response expectations) **MUST** exist and be kept current.
- *Rationale: the library holds credentials and runs in production and on end-user
  devices; a single leak or injection is a customer breach, which is categorically
  worse than any missing feature.*

### II. Resilience & Do-No-Harm (NON-NEGOTIABLE)

- The library **MUST NEVER** crash, block, deadlock, or measurably degrade the host
  application or service. No `fatalError`, force-unwrap, `try!`, blocking I/O on caller
  threads, or unbounded waits in library code paths reachable from the host.
- Resource use **MUST** be bounded for both memory and disk. Buffers and offline stores
  are fixed-capacity; on overflow the library **MUST** drop or evict telemetry (with a
  metric/counter) rather than grow without limit.
- Transport failures **MUST** be handled with robust retry, exponential backoff with
  jitter, honoring `Retry-After`, and circuit-breaking so a slow or failing endpoint
  cannot back-pressure the host.
- **Telemetry loss is always preferable to host impact.** When forced to choose, drop
  telemetry.
- *Rationale: an observability library that harms the app or service it observes is a
  net negative; it must be invisible to the host under all failure and load conditions.*

### III. Concurrency Safety (NON-NEGOTIABLE)

- All modules **MUST** build and test under Swift 6 strict concurrency with no
  data-race warnings suppressed. Types crossing concurrency boundaries **MUST** be
  correctly `Sendable`; `@unchecked Sendable` requires an explicit, reviewed
  justification.
- Shared mutable state **MUST** be protected (actors or equivalent); there **MUST** be
  no data races.
- *Rationale: this is concurrent, long-running infrastructure inside production
  services and on end-user devices; a data race is an unacceptable stability and
  correctness risk.*

### IV. Quality & Testing

- Every change **MUST** ship with automated tests. The Breeze translation tables
  (span→envelope mapping, Part A/B/C tags, severity/status mapping) and all failure
  paths (overflow, retry, partial success, malformed input, secret redaction) **MUST**
  be covered.
- CI **MUST** pass on **Linux and the Apple platforms — at minimum macOS and the iOS
  Simulator** — for supported Swift 6 toolchains; lint and format gates **MUST** be
  enforced and blocking.
- Every public API **MUST** be documented (doc comments) before it is released.
- *Rationale: correctness of the translation core and confidence across every supported
  platform are what make the library trustworthy in production and on-device.*

### V. API Stewardship

- The library **MUST** follow SemVer. Public-vs-internal boundaries **MUST** be
  explicit; anything not intended for consumers stays non-`public`.
- Breaking changes to public API **MUST** bump the major version and follow a documented
  deprecation policy (deprecate-then-remove, with migration notes); backwards
  compatibility within a major version is required.
- *Rationale: consumers embed this in their apps and services; unannounced breakage
  erodes trust and violates the stability mandate.*

### VI. Fidelity

- The mapping to the Breeze schema **MUST** be correct and faithful (envelope structure,
  `iKey`, endpoint/path, `sampleRate`/`itemCount`, per-signal `baseData`), verified
  against the authoritative MIT-licensed reference behavior and covered by
  golden/round-trip tests.
- The project **MUST** track evolving OpenTelemetry semantic conventions
  (HTTP/DB/messaging) deliberately, documenting the convention versions targeted and
  revisiting them as they drift.
- *Rationale: silently wrong telemetry is worse than none — it misleads operators during
  incidents.*

### VII. OSS Governance

- The project **MUST** maintain licensing clarity: a clear OSS license (Apache-2.0),
  correct third-party attribution (including any ported logic or vendored slices), and
  license compatibility for all dependencies.
- The project **MUST** maintain contribution standards (CONTRIBUTING) and a code of
  conduct.
- Self-diagnostics and internal telemetry **MUST NEVER** leak customer data or secrets.
- *Rationale: an open, credential-handling library earns adoption through transparent
  governance and a demonstrable commitment to never exfiltrating customer data.*

## Additional Constraints & Compliance

- This constitution is the highest authority for the project. Where any spec, plan, or
  PR conflicts with it, the constitution wins and the work MUST be revised.
- Principles I, II, and III are marked NON-NEGOTIABLE: no exception, waiver, or
  "temporary" bypass is permitted, and no reviewer may approve a violation.
- Every feature spec **MUST** restate the relevant security, resilience, concurrency,
  and quality principles as explicit non-functional acceptance criteria.
- Every PR description **MUST** attest that it upholds these principles (secrets not
  logged, bounded resources, Sendable-clean, tested, docs updated) or explain how it is
  exempt.

## Development Workflow & Quality Gates

- Work flows through Spec Kit: `/speckit-constitution` → `/speckit-specify` →
  `/speckit-clarify` → `/speckit-plan` → `/speckit-tasks` → `/speckit-implement`, with
  specs governed by this constitution.
- `main` is protected: branch → PR → required checks green → merge, with linear history
  and no force-push. Required checks include Build & Test and Lint (swift-format), and
  the build/test matrix **MUST** exercise the iOS Simulator and Linux, not macOS alone.
- The commands `swift build`, `swift test`, and
  `swift format lint --strict --recursive Sources Tests` **MUST** pass before merge.

## Governance

- This constitution supersedes all other development practices. Compliance is verified
  in code review and CI; complexity and any new runtime dependency MUST be justified.
- Amendments **MUST** be explicit, reviewed, and versioned. Principles may be
  strengthened freely but weakened only through a recorded, justified amendment.
- Versioning policy (semantic): **MAJOR** for backward-incompatible governance/principle
  removals or redefinitions; **MINOR** for a newly added or materially expanded
  principle or section; **PATCH** for clarifications and non-semantic refinements.
- Runtime development guidance for agents lives in `CLAUDE.md`; the full governing
  detail and design rationale live in `docs/speckit/constitution.md` and
  `docs/design.md`. These support the constitution but never override it.

**Version**: 1.0.0 | **Ratified**: 2026-07-09 | **Last Amended**: 2026-07-09
