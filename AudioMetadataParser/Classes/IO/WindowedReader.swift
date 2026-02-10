import Foundation

final class WindowedReader {
    private let source: any ByteSource
    private let windowSize: Int
    private let maxReadBytes: Int

    private var windowOffset: Int64 = 0
    private var windowData = Data()

    private(set) var bytesRead: Int = 0

    init(source: any ByteSource, windowSize: Int, maxReadBytes: Int) {
        self.source = source
        self.windowSize = max(4096, windowSize)
        self.maxReadBytes = max(256 * 1024, maxReadBytes)
    }

    var length: Int64? { source.length }
    var nameHint: String? { source.nameHint }

    func read(at offset: Int64, length: Int) throws -> Data {
        guard offset >= 0 else {
            throw AudioMetadataError(code: .ioFailure, message: "negative offset", offset: offset)
        }
        if length <= 0 {
            return Data()
        }

        let requestedEnd = offset + Int64(length)
        if offset >= windowOffset && requestedEnd <= windowOffset + Int64(windowData.count) {
            let lower = Int(offset - windowOffset)
            return windowData.subdata(in: lower ..< lower + length)
        }

        if length > maxReadBytes {
            throw AudioMetadataError(
                code: .ioFailure,
                message: "requested read exceeds maxReadBytes",
                offset: offset,
                context: ["requested": String(length), "maxReadBytes": String(maxReadBytes)]
            )
        }

        let fetchLength = max(windowSize, length)
        windowData = try source.read(at: offset, length: fetchLength)
        windowOffset = offset
        bytesRead += windowData.count

        if windowData.count < length {
            return windowData
        }
        return windowData.subdata(in: 0 ..< length)
    }

    func readUInt8(at offset: Int64) throws -> UInt8 {
        let data = try read(at: offset, length: 1)
        guard data.count == 1 else {
            throw AudioMetadataError(code: .truncatedData, message: "cannot read UInt8", offset: offset)
        }
        return data[data.startIndex]
    }

    func readUInt16LE(at offset: Int64) throws -> UInt16 {
        try read(at: offset, length: 2).toUInt16LE(at: 0)
    }

    func readUInt16BE(at offset: Int64) throws -> UInt16 {
        try read(at: offset, length: 2).toUInt16BE(at: 0)
    }

    func readUInt24BE(at offset: Int64) throws -> UInt32 {
        let data = try read(at: offset, length: 3)
        guard data.count == 3 else {
            throw AudioMetadataError(code: .truncatedData, message: "cannot read UInt24BE", offset: offset)
        }
        return (UInt32(data[0]) << 16) | (UInt32(data[1]) << 8) | UInt32(data[2])
    }

    func readUInt32LE(at offset: Int64) throws -> UInt32 {
        try read(at: offset, length: 4).toUInt32LE(at: 0)
    }

    func readUInt32BE(at offset: Int64) throws -> UInt32 {
        try read(at: offset, length: 4).toUInt32BE(at: 0)
    }

    func readUInt64LE(at offset: Int64) throws -> UInt64 {
        try read(at: offset, length: 8).toUInt64LE(at: 0)
    }

    func readUInt64BE(at offset: Int64) throws -> UInt64 {
        try read(at: offset, length: 8).toUInt64BE(at: 0)
    }

    func readASCII(at offset: Int64, length: Int) throws -> String {
        let data = try read(at: offset, length: length)
        guard data.count == length else {
            throw AudioMetadataError(code: .truncatedData, message: "cannot read ascii", offset: offset)
        }
        return String(decoding: data, as: Unicode.ASCII.self)
    }
}
