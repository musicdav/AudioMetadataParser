import Foundation

struct WaveParser: FormatParser {
    let format: AudioFormat = .wave

    func canParse(header: Data, fileHint: String?) -> Bool {
        guard header.count >= 12 else {
            return (fileHint as NSString?)?.pathExtension.lowercased() == "wav"
        }
        return String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "RIFF"
            && String(decoding: header[8..<12], as: Unicode.ASCII.self) == "WAVE"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let header = try reader.read(at: 0, length: 12)
        guard header.count == 12,
              String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "RIFF",
              String(decoding: header[8..<12], as: Unicode.ASCII.self) == "WAVE" else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid RIFF/WAVE header")
        }

        var cursor: Int64 = 12
        var channels: Int?
        var sampleRate: Int?
        var bitsPerSample: Int?
        var dataSize: Int64 = 0
        var tags: [String: MetadataTagValue] = [:]

        while let fileLength = reader.length, cursor + 8 <= fileLength {
            let chunkHeader = try reader.read(at: cursor, length: 8)
            guard chunkHeader.count == 8 else { break }

            let chunkID = String(decoding: chunkHeader.prefix(4), as: Unicode.ASCII.self)
            let chunkSize = Int64(try chunkHeader.toUInt32LE(at: 4))
            let chunkDataOffset = cursor + 8

            if chunkSize < 0 {
                break
            }

            switch chunkID.lowercased() {
            case "fmt ":
                let fmtData = try reader.read(at: chunkDataOffset, length: Int(min(chunkSize, 32)))
                if fmtData.count >= 16 {
                    channels = Int(try fmtData.toUInt16LE(at: 2))
                    sampleRate = Int(try fmtData.toUInt32LE(at: 4))
                    bitsPerSample = Int(try fmtData.toUInt16LE(at: 14))
                }
            case "data":
                dataSize = chunkSize
            case "id3 ", "id3":
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
        if let sampleRate, let channels, let bitsPerSample, sampleRate > 0, channels > 0, bitsPerSample > 0 {
            let bytesPerSampleFrame = Double(channels * bitsPerSample) / 8.0
            if bytesPerSampleFrame > 0 {
                length = Double(dataSize) / (Double(sampleRate) * bytesPerSampleFrame)
            } else {
                length = nil
            }
        } else {
            length = nil
        }

        let bitrate = ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: reader.length)

        return ParsedAudioMetadata(
            format: .wave,
            coreInfo: AudioCoreInfo(length: length, bitrate: bitrate, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "WaveParser")
        )
    }
}
