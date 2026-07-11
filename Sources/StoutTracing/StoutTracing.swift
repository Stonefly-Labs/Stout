// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

/// `StoutTracing` — the distributed-tracing exporter (spec 02).
///
/// This module implements `opentelemetry-swift`'s public `SpanExporter` protocol
/// (`AzureMonitorTraceExporter`) and translates finished `SpanData` into
/// Application Insights **Breeze** telemetry — `RequestData` (server/consumer),
/// `RemoteDependencyData` (client/producer/internal/unspecified), and the derived
/// `ExceptionData`/`MessageData` from span events — stamped into an `Envelope` by
/// spec 01's `EnvelopeFactory` and handed to spec 01's bounded, drop-on-overflow
/// `ExportPipeline`.
///
/// It is a **consumer of `StoutCore`**: it redefines none of the core's envelope,
/// transport, diagnostics, resource-detection, or pipeline primitives — it only
/// adds the trace-specific Breeze payload types and the pure, table-driven mapping
/// from OTel semantic conventions to those payloads. Correlation, batching,
/// sampling, and span lifecycle stay owned by the SDK; Stout is a terminal
/// exporter (see `docs/design.md` D8 and `specs/002-distributed-tracing/`).
///
/// This `enum` is an empty namespace anchor only; the public surface is
/// `AzureMonitorTraceExporter` and its registration helper.
public enum StoutTracing {}
