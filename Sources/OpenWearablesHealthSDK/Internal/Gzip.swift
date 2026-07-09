import Foundation
import Compression

/// Minimal gzip encoder for upload payloads.
///
/// A third-party dependency (GzipSwift / DataCompression) would be preferable,
/// but the versions published to CocoaPods trunk declare deployment targets
/// below iOS 12, which no longer compile under current Xcode — so any pod
/// depending on them fails `pod trunk push` validation. Apple's Compression
/// framework only emits raw DEFLATE (`COMPRESSION_ZLIB`), so the gzip container
/// (RFC 1952) — 10-byte header plus CRC32/ISIZE trailer — is assembled by hand.
/// Self-contained: builds identically under SwiftPM and CocoaPods.
extension Data {

    /// Returns the receiver compressed as a gzip stream, or `nil` if
    /// compression fails (caller should fall back to the uncompressed body).
    func gzipped() -> Data? {
        guard !isEmpty else { return nil }

        let dstCapacity = count + count / 2 + 256
        var dst = [UInt8](repeating: 0, count: dstCapacity)
        let compressedSize = withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let srcPtr = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&dst, dstCapacity, srcPtr, count, nil, COMPRESSION_ZLIB)
        }
        guard compressedSize > 0 else { return nil }

        var out = Data(capacity: compressedSize + 18)
        // Header: magic, deflate, no flags, no mtime, no extra flags, unknown OS.
        out.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(contentsOf: dst[0..<compressedSize])

        var crc = crc32().littleEndian
        Swift.withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: count).littleEndian
        Swift.withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    private static let crc32Table: [UInt32] = (0...255).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1 == 1) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private func crc32() -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                crc = Data.crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
