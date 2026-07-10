// This source file is part of the Stout open-source project
//
// Copyright 2026 Stonefly Labs
// SPDX-License-Identifier: Apache-2.0

// System zlib: on Linux via the `CZlib` shim target, on Apple via the SDK's own
// `zlib` module. One code path, no third-party dependency (research R1).
#if canImport(CZlib)
  import CZlib
#else
  import zlib
#endif

/// A gzip compression failure. Carries only the zlib return code — never any
/// payload — so it is safe to surface through diagnostics (FR-028).
public enum GzipError: Error, Sendable, Equatable {
  case initializationFailed(code: Int32)
  case compressionFailed(code: Int32)
}

/// Compress `input` into a gzip stream (RFC 1952) using system zlib (FR-010).
///
/// We ask zlib for gzip framing directly with `windowBits = MAX_WBITS + 16`, so
/// zlib emits the 10-byte gzip header, the DEFLATE body, the CRC-32, and the
/// ISIZE trailer itself — the core writes no framing or checksum code. The whole
/// operation runs synchronously over value types (`z_stream` never escapes this
/// call), so it is trivially concurrency-safe.
///
/// - Parameter input: raw bytes to compress (e.g. the newline-delimited JSON
///   batch body).
/// - Returns: the gzip-compressed bytes.
/// - Throws: `GzipError` if zlib reports a failure.
func gzip(_ input: [UInt8]) throws -> [UInt8] {
  var stream = z_stream()
  let windowBits = Int32(MAX_WBITS + 16)  // 31 → gzip header + CRC-32 + ISIZE.
  let initStatus = deflateInit2_(
    &stream,
    Z_DEFAULT_COMPRESSION,
    Z_DEFLATED,
    windowBits,
    Int32(MAX_MEM_LEVEL),
    Z_DEFAULT_STRATEGY,
    ZLIB_VERSION,
    Int32(MemoryLayout<z_stream>.size)
  )
  guard initStatus == Z_OK else {
    throw GzipError.initializationFailed(code: initStatus)
  }
  defer { deflateEnd(&stream) }

  let chunkSize = 16_384
  var output = [UInt8]()
  output.reserveCapacity(max(chunkSize, input.count / 2))
  var chunk = [UInt8](repeating: 0, count: chunkSize)

  // `input` is copied to a mutable buffer because `z_stream.next_in` is a
  // mutable pointer; zlib does not modify the input bytes.
  var mutableInput = input
  return try mutableInput.withUnsafeMutableBufferPointer { inputPtr in
    stream.next_in = inputPtr.baseAddress
    stream.avail_in = uInt(inputPtr.count)

    while true {
      let status: Int32 = chunk.withUnsafeMutableBufferPointer { chunkPtr in
        stream.next_out = chunkPtr.baseAddress
        stream.avail_out = uInt(chunkPtr.count)
        return deflate(&stream, Z_FINISH)
      }
      let produced = chunkSize - Int(stream.avail_out)
      if produced > 0 {
        output.append(contentsOf: chunk[0..<produced])
      }
      if status == Z_STREAM_END {
        break
      }
      guard status == Z_OK else {
        throw GzipError.compressionFailed(code: status)
      }
      // Z_OK with a full output buffer means there is more to emit; loop with a
      // fresh chunk.
    }
    return output
  }
}

/// Decompress a gzip stream produced by `gzip(_:)`. Used for round-trip
/// verification (SC-004); the exporter itself never decompresses in production.
func gunzip(_ input: [UInt8]) throws -> [UInt8] {
  var stream = z_stream()
  let windowBits = Int32(MAX_WBITS + 16)  // 31 → accept gzip framing.
  let initStatus = inflateInit2_(
    &stream,
    windowBits,
    ZLIB_VERSION,
    Int32(MemoryLayout<z_stream>.size)
  )
  guard initStatus == Z_OK else {
    throw GzipError.initializationFailed(code: initStatus)
  }
  defer { inflateEnd(&stream) }

  let chunkSize = 16_384
  var output = [UInt8]()
  var chunk = [UInt8](repeating: 0, count: chunkSize)
  var mutableInput = input
  return try mutableInput.withUnsafeMutableBufferPointer { inputPtr in
    stream.next_in = inputPtr.baseAddress
    stream.avail_in = uInt(inputPtr.count)

    while true {
      let status: Int32 = chunk.withUnsafeMutableBufferPointer { chunkPtr in
        stream.next_out = chunkPtr.baseAddress
        stream.avail_out = uInt(chunkPtr.count)
        return inflate(&stream, Z_NO_FLUSH)
      }
      let produced = chunkSize - Int(stream.avail_out)
      if produced > 0 {
        output.append(contentsOf: chunk[0..<produced])
      }
      if status == Z_STREAM_END {
        break
      }
      guard status == Z_OK else {
        throw GzipError.compressionFailed(code: status)
      }
    }
    return output
  }
}
