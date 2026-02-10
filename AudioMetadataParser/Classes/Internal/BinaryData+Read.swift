import Foundation

extension Data {
    func toUInt16LE(at offset: Int) throws -> UInt16 {
        guard count >= offset + 2 else {
            throw AudioMetadataError(code: .truncatedData, message: "UInt16LE out of range")
        }
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1]) << 8
        return b0 | b1
    }

    func toUInt16BE(at offset: Int) throws -> UInt16 {
        guard count >= offset + 2 else {
            throw AudioMetadataError(code: .truncatedData, message: "UInt16BE out of range")
        }
        let b0 = UInt16(self[offset]) << 8
        let b1 = UInt16(self[offset + 1])
        return b0 | b1
    }

    func toUInt32LE(at offset: Int) throws -> UInt32 {
        guard count >= offset + 4 else {
            throw AudioMetadataError(code: .truncatedData, message: "UInt32LE out of range")
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func toUInt32BE(at offset: Int) throws -> UInt32 {
        guard count >= offset + 4 else {
            throw AudioMetadataError(code: .truncatedData, message: "UInt32BE out of range")
        }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func toUInt64LE(at offset: Int) throws -> UInt64 {
        guard count >= offset + 8 else {
            throw AudioMetadataError(code: .truncatedData, message: "UInt64LE out of range")
        }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(self[offset + i]) << (UInt64(i) * 8)
        }
        return value
    }

    func toUInt64BE(at offset: Int) throws -> UInt64 {
        guard count >= offset + 8 else {
            throw AudioMetadataError(code: .truncatedData, message: "UInt64BE out of range")
        }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(self[offset + i])
        }
        return value
    }
}
