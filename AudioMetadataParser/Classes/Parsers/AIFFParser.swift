import Foundation

struct AIFFParser: FormatParser {
    let format: AudioFormat = .aiff

    func canParse(header: Data, fileHint: String?) -> Bool {
        guard header.count >= 12 else {
            return ["aif", "aiff", "aifc"].contains((fileHint as NSString?)?.pathExtension.lowercased() ?? "")
        }
        let form = String(decoding: header.prefix(4), as: Unicode.ASCII.self)
        let kind = String(decoding: header[8..<12], as: Unicode.ASCII.self)
        return form == "FORM" && (kind == "AIFF" || kind == "AIFC")
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let header = try reader.read(at: 0, length: 12)
        guard header.count == 12,
              String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "FORM" else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid AIFF header")
        }

        var cursor: Int64 = 12
        var channels: Int?
        var sampleRate: Int?
        var bitsPerSample: Int?
        var sampleFrames: Int64?
        var tags: [String: MetadataTagValue] = [:]

        while let fileLength = reader.length, cursor + 8 <= fileLength {
            let chunkHeader = try reader.read(at: cursor, length: 8)
            guard chunkHeader.count == 8 else { break }

            let chunkID = String(decoding: chunkHeader.prefix(4), as: Unicode.ASCII.self)
            let chunkSize = Int64(try chunkHeader.toUInt32BE(at: 4))
            let chunkDataOffset = cursor + 8

            switch chunkID {
            case "COMM":
                let comm = try reader.read(at: chunkDataOffset, length: Int(min(chunkSize, 26)))
                if comm.count >= 18 {
                    channels = Int(try comm.toUInt16BE(at: 0))
                    sampleFrames = Int64(try comm.toUInt32BE(at: 2))
                    bitsPerSample = Int(try comm.toUInt16BE(at: 6))
                    let ext = comm.subdata(in: 8..<18)
                    sampleRate = Int(readExtended80(ext) ?? 0)
                }
            case "ID3":
                let id3Data = try reader.read(at: chunkDataOffset, length: Int(chunkSize))
                let id3Reader = WindowedReader(source: DataByteSource(data: id3Data, fileHint: nil), windowSize: context.options.windowSize, maxReadBytes: context.options.maxReadBytes)
                let parsed = try TagParsers.parseID3v2(reader: id3Reader, options: context.options)
                tags.merge(parsed.tags, uniquingKeysWith: { _, new in new })
            default:
                break
            }

            let paddedSize = chunkSize + (chunkSize % 2)
            cursor = chunkDataOffset + paddedSize
        }

        let length: Double?
        if let sampleFrames, let sampleRate, sampleRate > 0 {
            length = Double(sampleFrames) / Double(sampleRate)
        } else {
            length = nil
        }

        let bitrate: Int?
        if let channels, let bitsPerSample, let sampleRate {
            bitrate = channels * bitsPerSample * sampleRate
        } else {
            bitrate = ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: reader.length)
        }

        return ParsedAudioMetadata(
            format: .aiff,
            coreInfo: AudioCoreInfo(length: length, bitrate: bitrate, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "AIFFParser")
        )
    }

    // 80-bit IEEE extended float used by AIFF sample rate field.
    private func readExtended80(_ bytes: Data) -> Double? {
        guard bytes.count == 10 else { return nil }
        let sign = (bytes[0] & 0x80) == 0 ? 1.0 : -1.0
        let exponent = Int(((UInt16(bytes[0] & 0x7F) << 8) | UInt16(bytes[1]))) - 16383

        var mantissa: UInt64 = 0
        for i in 0..<8 {
            mantissa = (mantissa << 8) | UInt64(bytes[2 + i])
        }

        if mantissa == 0 {
            return 0
        }

        let normalized = Double(mantissa) / Double(UInt64(1) << 63)
        let value = sign * pow(2.0, Double(exponent)) * normalized
        if value.isFinite {
            return value
        }
        return nil
    }
}
