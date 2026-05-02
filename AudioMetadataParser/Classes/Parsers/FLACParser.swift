import Foundation

struct FLACParser: FormatParser {
    let format: AudioFormat = .flac

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "fLaC" {
            return true
        }
        return (fileHint as NSString?)?.pathExtension.lowercased() == "flac"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        var tags: [String: MetadataTagValue] = [:]
        var extensions: [String: MetadataTagValue] = [:]

        let header = try reader.read(at: 0, length: 4)
        let flacOffset: Int64
        if String(decoding: header, as: Unicode.ASCII.self) == "fLaC" {
            flacOffset = 0
        } else {
            let id3 = try TagParsers.parseID3v2(reader: reader, at: 0, options: context.options)
            guard id3.size > 0 else {
                throw AudioMetadataError(code: .invalidHeader, message: "missing flac marker")
            }
            tags.merge(id3.tags, uniquingKeysWith: { _, new in new })

            let shiftedHeader = try reader.read(at: Int64(id3.size), length: 4)
            guard String(decoding: shiftedHeader, as: Unicode.ASCII.self) == "fLaC" else {
                throw AudioMetadataError(code: .invalidHeader, message: "missing flac marker", offset: Int64(id3.size))
            }
            flacOffset = Int64(id3.size)
            extensions["leading_id3v2_size"] = .int(id3.size)
        }

        var cursor = flacOffset + 4
        var isLast = false

        var sampleRate: Int?
        var channels: Int?
        var bitsPerSample: Int?
        var totalSamples: UInt64?
        var hasStreamInfo = false
        var audioStart: Int64?

        while !isLast {
            let blockHeader = try reader.read(at: cursor, length: 4)
            guard blockHeader.count == 4 else {
                throw AudioMetadataError(code: .truncatedData, message: "flac metadata block header truncated", offset: cursor)
            }
            isLast = (blockHeader[0] & 0x80) != 0
            let blockType = blockHeader[0] & 0x7F
            let blockLength = Int(blockHeader[1]) << 16 | Int(blockHeader[2]) << 8 | Int(blockHeader[3])
            cursor += 4

            if let fileLength = reader.length, cursor + Int64(blockLength) > fileLength {
                if blockType == 0 && !hasStreamInfo {
                    throw AudioMetadataError(code: .truncatedData, message: "flac streaminfo block truncated", offset: cursor)
                }
                extensions["flac_metadata_truncated"] = .bool(true)
                audioStart = try findFrameSync(reader: reader, start: cursor, fileLength: fileLength)
                break
            }

            let blockData = try reader.read(at: cursor, length: blockLength)
            guard blockData.count == blockLength else {
                if blockType == 0 && !hasStreamInfo {
                    throw AudioMetadataError(code: .truncatedData, message: "flac streaminfo block truncated", offset: cursor)
                }
                extensions["flac_metadata_truncated"] = .bool(true)
                if let fileLength = reader.length {
                    audioStart = try findFrameSync(reader: reader, start: cursor, fileLength: fileLength)
                }
                break
            }

            switch blockType {
            case 0: // STREAMINFO
                if blockData.count >= 34 {
                    let b10 = UInt64(blockData[10])
                    let b11 = UInt64(blockData[11])
                    let b12 = UInt64(blockData[12])
                    let b13 = UInt64(blockData[13])
                    let b14 = UInt64(blockData[14])
                    let b15 = UInt64(blockData[15])
                    let b16 = UInt64(blockData[16])
                    let b17 = UInt64(blockData[17])

                    sampleRate = Int((b10 << 12) | (b11 << 4) | (b12 >> 4))
                    channels = Int(((b12 >> 1) & 0x07) + 1)
                    bitsPerSample = Int((((b12 & 0x01) << 4) | (b13 >> 4)) + 1)
                    totalSamples = ((b13 & 0x0F) << 32) | (b14 << 24) | (b15 << 16) | (b16 << 8) | b17
                    extensions["total_samples"] = .int(Int(totalSamples ?? 0))
                    hasStreamInfo = true
                } else if !hasStreamInfo {
                    throw AudioMetadataError(code: .invalidHeader, message: "invalid flac streaminfo block", offset: cursor)
                }
            case 4: // VORBIS_COMMENT
                let vorbisTags = TagParsers.parseVorbisCommentPacket(blockData)
                tags.merge(vorbisTags, uniquingKeysWith: { _, new in new })
            case 6: // PICTURE
                tags["PICTURE"] = .binary(parsePictureDigest(blockData, options: context.options))
            default:
                break
            }

            cursor += Int64(blockLength)
        }
        if audioStart == nil {
            audioStart = cursor
        }

        let length: Double?
        if let totalSamples, let sampleRate, sampleRate > 0 {
            length = Double(totalSamples) / Double(sampleRate)
        } else {
            length = nil
        }

        let audioByteCount: Int64?
        if let fileLength = reader.length, let audioStart, fileLength > audioStart {
            audioByteCount = fileLength - audioStart
        } else {
            audioByteCount = nil
        }
        let bitrate = ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: audioByteCount)

        return ParsedAudioMetadata(
            format: .flac,
            coreInfo: AudioCoreInfo(length: length, bitrate: bitrate, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: extensions,
            diagnostics: ParserDiagnostics(parserName: "FLACParser")
        )
    }

    private func parsePictureDigest(_ blockData: Data, options: ParseOptions) -> BinaryDigest {
        func fallback() -> BinaryDigest {
            TagParsers.binaryDigest(payload: blockData, mime: nil, options: options)
        }

        guard blockData.count >= 8 else { return fallback() }
        var offset = 4
        guard let mimeLength = readUInt32BE(blockData, at: offset) else { return fallback() }
        offset += 4
        guard offset + mimeLength <= blockData.count else { return fallback() }
        let mimeData = blockData.subdata(in: offset ..< offset + mimeLength)
        let mime = String(data: mimeData, encoding: .utf8)
        offset += mimeLength

        guard let descLength = readUInt32BE(blockData, at: offset) else { return fallback() }
        offset += 4
        guard offset + descLength <= blockData.count else { return fallback() }
        offset += descLength

        guard offset + 20 <= blockData.count else { return fallback() }
        offset += 16 // width, height, depth, colors
        guard let dataLength = readUInt32BE(blockData, at: offset) else { return fallback() }
        offset += 4

        let imageData: Data
        if offset + dataLength <= blockData.count {
            imageData = blockData.subdata(in: offset ..< offset + dataLength)
        } else {
            imageData = Data(blockData.suffix(from: offset))
        }
        guard !imageData.isEmpty else { return fallback() }
        return TagParsers.binaryDigest(payload: imageData, mime: mime, options: options)
    }

    private func readUInt32BE(_ data: Data, at offset: Int) -> Int? {
        guard offset + 4 <= data.count else { return nil }
        return (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }

    private func findFrameSync(reader: WindowedReader, start: Int64, fileLength: Int64) throws -> Int64? {
        let scanLength = Int(min(128 * 1024, max(0, fileLength - start)))
        let data = try reader.read(at: start, length: scanLength)
        guard data.count >= 2 else { return nil }
        for index in 0..<(data.count - 1) where data[index] == 0xFF && (data[index + 1] & 0xFC) == 0xF8 {
            return start + Int64(index)
        }
        return nil
    }
}
