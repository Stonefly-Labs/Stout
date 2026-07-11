// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

import OpenTelemetrySdk
import StoutCore

/// Thin factory that assembles an ``AzureMonitorTraceExporter`` from the spec-01
/// building blocks. It exists so the umbrella `Stout` distribution (spec 07) has one
/// place to construct the exporter and register it with a `TracerProvider` via a
/// `BatchSpanProcessor`. This feature does **not** implement provider bootstrap —
/// that (and connection-string parsing) is spec 07.
///
/// The single responsibility beyond wiring is resource-tag detection: the OTel
/// `Resource` is a per-provider constant shared across all its spans, so the Part A
/// resource tags (`ai.cloud.role`, `ai.internal.sdkVersion`, `ai.device.*`, …) are
/// detected **once here** via `ResourceDetector` and baked into the `EnvelopeFactory`
/// — never recomputed off each `SpanData` (FR-009).
public enum TraceExporterRegistration {
  /// Build an exporter over an already-assembled pipeline, detecting resource tags
  /// once from the provider's `Resource`.
  ///
  /// - Parameters:
  ///   - pipeline: the spec-01 export pipeline (owns transport/retry/buffering).
  ///   - instrumentationKey: the ingestion instrumentation key (from the connection
  ///     string; routed to each envelope's `iKey`).
  ///   - resource: the `TracerProvider`'s OpenTelemetry `Resource`. Defaults to the
  ///     SDK default resource.
  ///   - resourceOverrides: Part A tags that take precedence over detection (FR-022).
  /// - Returns: a ready-to-register `SpanExporter`.
  public static func makeExporter(
    pipeline: ExportPipeline,
    instrumentationKey: String,
    resource: Resource = Resource(),
    resourceOverrides: TelemetryTags = TelemetryTags()
  ) -> AzureMonitorTraceExporter {
    let resourceTags = ResourceDetector.detect(resource: resource, overrides: resourceOverrides)
    let envelopeFactory = EnvelopeFactory(
      instrumentationKey: instrumentationKey, resourceTags: resourceTags)
    return AzureMonitorTraceExporter(pipeline: pipeline, envelopeFactory: envelopeFactory)
  }
}
