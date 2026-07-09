# Stout — Constitution Prompt

Pass the prompt below to `/speckit.constitution`.

---

Establish the governing constitution for **Stout**, a collector-free, open-source Azure Monitor / Application Insights exporter for server-side Swift (Linux + macOS, Swift 6). It implements the Swift Server Working Group observability facades (`swift-log`, `swift-metrics`, `swift-distributed-tracing`), translates telemetry into the Application Insights "Breeze" schema, and POSTs directly to ingestion — no OpenTelemetry Collector, no Azure Monitor Agent. This library handles customer credentials and runs inside customers' production services, so **security, stability, and quality outrank speed and feature count at all times.**

These principles are durable and binding. They constrain every spec, plan, and pull request that follows. Each principle below is testable; treat every "MUST"/"MUST NOT" as a non-negotiable acceptance criterion that CI, code review, and specs are required to enforce. Where a principle cannot be met, the work does not ship — telemetry loss is always preferable to violating a principle.

## Principle 1 — Security-First (NON-NEGOTIABLE)

- Connection strings, instrumentation keys, and Entra/AAD tokens are secrets. Library code **MUST NOT** log them, include them in error messages or thrown errors, surface them in the library's own self-diagnostics/telemetry, or write them to any persisted store in cleartext. Redaction MUST be the default and MUST be covered by tests.
- All configuration and external input (connection strings, endpoints, response bodies, attributes) **MUST** be validated and **fail closed**: reject malformed or ambiguous input rather than guessing or proceeding with partial state.
- The library **MUST** be secure-by-default: TLS/HTTPS-only transport to ingestion and control endpoints, no insecure fallback, and no configuration option that weakens security silently.
- Dependencies **MUST** be minimal and audited; every new runtime dependency requires explicit justification in the PR. Prefer the single approved runtime dependency posture described in the design over adding more.
- A responsible security-disclosure process (SECURITY.md with a private reporting channel and response expectations) **MUST** exist and be kept current.
- *Rationale: the library holds credentials and runs in production; a single leak or injection is a customer breach, which is categorically worse than any missing feature.*

## Principle 2 — Resilience & Do-No-Harm (NON-NEGOTIABLE)

- The library **MUST NEVER** crash, block, deadlock, or measurably degrade the host application. No `fatalError`, force-unwrap, `try!`, blocking I/O on caller threads, or unbounded waits in library code paths reachable from the host.
- Resource use **MUST** be bounded for both memory and disk. Buffers and offline stores are fixed-capacity; on overflow the library **MUST** drop or evict telemetry (with a metric/counter) rather than grow without limit.
- Transport failures **MUST** be handled with robust retry, exponential backoff with jitter, honoring `Retry-After`, and circuit-breaking so a slow or failing endpoint cannot back-pressure the host.
- **Telemetry loss is always preferable to host impact.** When forced to choose, drop telemetry.
- *Rationale: an observability library that harms the service it observes is a net negative; it must be invisible to the host under all failure and load conditions.*

## Principle 3 — Concurrency Safety (NON-NEGOTIABLE)

- All modules **MUST** build and test under Swift 6 strict concurrency with no data-race warnings suppressed. Types crossing concurrency boundaries **MUST** be correctly `Sendable`; `@unchecked Sendable` requires an explicit, reviewed justification.
- Shared mutable state **MUST** be protected (actors or equivalent); there **MUST** be no data races.
- *Rationale: this is concurrent, long-running infrastructure inside production servers; a data race is an unacceptable stability and correctness risk.*

## Principle 4 — Quality & Testing

- Every change **MUST** ship with automated tests. The Breeze translation tables (span→envelope mapping, Part A/B/C tags, severity/status mapping) and all failure paths (overflow, retry, partial success, malformed input, secret redaction) **MUST** be covered.
- CI **MUST** pass on both **Linux and macOS** for supported Swift 6 toolchains; lint and format gates **MUST** be enforced and blocking.
- Every public API **MUST** be documented (doc comments) before it is released.
- *Rationale: correctness of the translation core and confidence across both platforms are what make the library trustworthy in production.*

## Principle 5 — API Stewardship

- The library **MUST** follow SemVer. Public-vs-internal boundaries **MUST** be explicit; anything not intended for consumers stays non-`public`.
- Breaking changes to public API **MUST** bump the major version and follow a documented deprecation policy (deprecate-then-remove, with migration notes); backwards compatibility within a major version is required.
- *Rationale: consumers embed this in their services; unannounced breakage erodes trust and violates the stability mandate.*

## Principle 6 — Fidelity

- The mapping to the Breeze schema **MUST** be correct and faithful (envelope structure, `iKey`, endpoint/path, `sampleRate`/`itemCount`, per-signal `baseData`), verified against the authoritative MIT-licensed reference behavior and covered by golden/round-trip tests.
- The project **MUST** track evolving OpenTelemetry semantic conventions (HTTP/DB/messaging) deliberately, documenting the convention versions targeted and revisiting them as they drift.
- *Rationale: silently wrong telemetry is worse than none — it misleads operators during incidents.*

## Principle 7 — OSS Governance

- The project **MUST** maintain licensing clarity: a clear OSS license, correct third-party attribution (including any ported logic or vendored slices), and license compatibility for all dependencies.
- The project **MUST** maintain contribution standards (CONTRIBUTING) and a code of conduct.
- Self-diagnostics and internal telemetry **MUST NEVER** leak customer data or secrets.
- *Rationale: an open, credential-handling library earns adoption through transparent governance and a demonstrable commitment to never exfiltrating customer data.*

## Governance & Constraints

- This constitution is the highest authority for the project. Where any spec, plan, or PR conflicts with it, the constitution wins and the work MUST be revised.
- Principles 1, 2, and 3 are marked NON-NEGOTIABLE: no exception, waiver, or "temporary" bypass is permitted, and no reviewer may approve a violation.
- Every feature spec **MUST** restate the relevant security, resilience, concurrency, and quality principles as explicit non-functional acceptance criteria.
- Every PR description **MUST** attest that it upholds these principles (secrets not logged, bounded resources, Sendable-clean, tested, docs updated) or explain how it is exempt.
- Amendments to this constitution **MUST** be explicit, reviewed, and versioned; principles may be strengthened freely but weakened only through a recorded, justified amendment.
