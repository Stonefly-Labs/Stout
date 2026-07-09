# Contributing to Stout

Thank you for your interest in contributing to Stout. This is a public, open-source
library whose top priorities — **at all times, over speed or feature count** — are
**security, stability, and quality**. Every contribution is expected to uphold those
principles.

Please also read the [Code of Conduct](CODE_OF_CONDUCT.md) and the project
[design docs](docs/) before starting.

## Prerequisites

- **Swift 6.0 or newer** toolchain.
- The library targets **macOS 13+** and **Linux** (server-side only — no
  iOS/tvOS/watchOS).

## Build, test, and lint

```sh
# Resolve dependencies and build
swift build

# Run the test suite
swift test

# Lint formatting (must pass with no diagnostics)
swift format lint --strict --recursive Sources Tests

# Auto-format your changes before committing
swift format --in-place --recursive Sources Tests
```

CI runs `swift build`, `swift test`, and the `swift format` lint gate. All three
must be green before a pull request can merge.

## Swift 6 strict concurrency

Stout builds under **Swift 6 language mode with complete strict-concurrency
checking** (`swiftLanguageModes: [.v6]`). All code must be data-race-free: types
crossing concurrency boundaries must be `Sendable`, and you must not silence
concurrency diagnostics with unsafe flags or `@unchecked Sendable` shortcuts unless
there is a documented, reviewed reason. Telemetry failures must **never** crash or
block the host application.

## Non-functional criteria (every PR)

Because Stout runs inside customers' production services and handles secrets, every
pull request must explicitly uphold the constitution's non-functional criteria:

- **Security** — connection strings, instrumentation keys, and tokens are secrets:
  never logged, never placed in error messages or our own telemetry. Validate inputs
  and fail closed. Keep dependencies minimal and audited; every new dependency is a
  reviewed decision.
- **Resilience** — graceful degradation (a telemetry failure must not take down the
  host), bounded memory with drop-on-overflow (never unbounded buffers), and robust
  retry/backoff.
- **Quality** — high test coverage including translation tables and failure paths,
  SemVer discipline, clear public API boundaries, and documented behavior.

Restate, in your PR description, how the change meets these criteria (or note that it
is unaffected). Reviewers will hold every PR to them.

## Developer Certificate of Origin (DCO) sign-off

All commits must be signed off under the
[Developer Certificate of Origin](https://developercertificate.org/). This certifies
that you wrote the code (or otherwise have the right to submit it under the project's
license). Add a `Signed-off-by` trailer to each commit:

```sh
git commit -s -m "Your commit message"
```

This appends a line such as:

```
Signed-off-by: Your Name <your.email@example.com>
```

Use your real name and an email you can be reached at. Pull requests with unsigned
commits will be asked to amend before merge.

## License

By contributing, you agree that your contributions are licensed under the project's
[Apache License 2.0](LICENSE).
