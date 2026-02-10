import Foundation

private struct MPEGHeaderInfo {
    let version: Double
    let layer: Int
    let bitrate: Int
    let sampleRate: Int
    let channels: Int
    let frameLength: Int
    let samplesPerFrame: Int
}

struct MP3Parser: FormatParser {
    let format: AudioFormat = .mp3

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 3, String(decoding: header.prefix(3), as: Unicode.ASCII.self) == "ID3" {
            return true
        }
        if header.count >= 2, header[0] == 0xFF, (header[1] & 0xE0) == 0xE0 {
            return true
        }
        let ext = (fileHint as NSString?)?.pathExtension.lowercased()
        return ext == "mp3"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        var tags: [String: MetadataTagValue] = [:]
        var extensions: [String: MetadataTagValue] = [:]

        var offset: Int64 = 0
        let id3 = try TagParsers.parseID3v2(reader: reader, at: 0, options: context.options)
        if id3.size > 0 {
            tags.merge(id3.tags, uniquingKeysWith: { _, new in new })
            offset = Int64(id3.size)
        }

        let search = try reader.read(at: offset, length: 1024 * 128)
        guard let syncOffset = findSync(in: search) else {
            throw AudioMetadataError(code: .invalidHeader, message: "mpeg sync not found", offset: offset)
        }
        let frameOffset = offset + Int64(syncOffset)

        let frameHeader = try reader.read(at: frameOffset, length: 4)
        let header = try parseMPEGHeader(frameHeader)

        var lengthSeconds: Double?
        var bitrate = header.bitrate
        var encoderInfo: String?
        var bitrateMode = "CBR"

        let xingOffset = (header.version == 1.0) ? (header.channels == 1 ? 21 : 36) : (header.channels == 1 ? 13 : 21)
        let xingData = try reader.read(at: frameOffset + Int64(xingOffset), length: 160)
        if xingData.count >= 16,
           String(decoding: xingData.prefix(4), as: Unicode.ASCII.self) == "Xing" ||
           String(decoding: xingData.prefix(4), as: Unicode.ASCII.self) == "Info" {
            let flags = Int(xingData[4]) << 24 | Int(xingData[5]) << 16 | Int(xingData[6]) << 8 | Int(xingData[7])
            var cursor = 8
            var frameCount: Int?
            var byteCount: Int?
            if (flags & 0x1) != 0, cursor + 4 <= xingData.count {
                frameCount = Int(xingData[cursor]) << 24 | Int(xingData[cursor + 1]) << 16 | Int(xingData[cursor + 2]) << 8 | Int(xingData[cursor + 3])
                cursor += 4
            }
            if (flags & 0x2) != 0, cursor + 4 <= xingData.count {
                byteCount = Int(xingData[cursor]) << 24 | Int(xingData[cursor + 1]) << 16 | Int(xingData[cursor + 2]) << 8 | Int(xingData[cursor + 3])
                cursor += 4
            }
            if let frameCount {
                lengthSeconds = (Double(frameCount * header.samplesPerFrame) / Double(header.sampleRate))
                if let byteCount, lengthSeconds ?? 0 > 0 {
                    bitrate = Int((Double(byteCount) * 8.0) / (lengthSeconds ?? 1.0))
                }
            }
            bitrateMode = String(decoding: xingData.prefix(4), as: Unicode.ASCII.self) == "Info" ? "CBR" : "VBR"

            if let lameRange = xingData.range(of: Data("LAME".utf8)) {
                let end = min(xingData.count, lameRange.lowerBound + 16)
                encoderInfo = String(data: xingData[lameRange.lowerBound..<end], encoding: .ascii)
            }
        } else {
            let vbriData = try reader.read(at: frameOffset + 36, length: 32)
            if vbriData.count >= 26, String(decoding: vbriData.prefix(4), as: Unicode.ASCII.self) == "VBRI" {
                let byteCount = Int(try vbriData.toUInt32BE(at: 10))
                let frameCount = Int(try vbriData.toUInt32BE(at: 14))
                lengthSeconds = (Double(frameCount * header.samplesPerFrame) / Double(header.sampleRate))
                if lengthSeconds ?? 0 > 0 {
                    bitrate = Int((Double(byteCount) * 8.0) / (lengthSeconds ?? 1.0))
                }
                bitrateMode = "VBR"
            }
        }

        if lengthSeconds == nil {
            if let fileLength = reader.length {
                lengthSeconds = (Double(fileLength - frameOffset) * 8.0) / Double(max(1, bitrate))
            }
        }

        if let encoderInfo {
            extensions["encoder_info"] = .text([encoderInfo])
        }
        extensions["bitrate_mode"] = .text([bitrateMode])
        extensions["mpeg_version"] = .double(header.version)
        extensions["mpeg_layer"] = .int(header.layer)

        if let apeTags = try? TagParsers.parseAPEv2Footer(reader: reader, options: context.options) {
            tags.merge(apeTags, uniquingKeysWith: { old, _ in old })
        }

        return ParsedAudioMetadata(
            format: .mp3,
            coreInfo: AudioCoreInfo(
                length: lengthSeconds,
                bitrate: bitrate,
                sampleRate: header.sampleRate,
                channels: header.channels,
                bitsPerSample: nil
            ),
            tags: tags,
            extensions: extensions,
            diagnostics: ParserDiagnostics(parserName: "MP3Parser")
        )
    }

    private func findSync(in data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        for i in 0..<(data.count - 1) where data[i] == 0xFF && (data[i + 1] & 0xE0) == 0xE0 {
            return i
        }
        return nil
    }

    private func parseMPEGHeader(_ data: Data) throws -> MPEGHeaderInfo {
        guard data.count >= 4 else {
            throw AudioMetadataError(code: .truncatedData, message: "mpeg header truncated")
        }

        let b1 = data[1]
        let b2 = data[2]
        let b3 = data[3]

        let versionBits = (b1 >> 3) & 0x03
        let layerBits = (b1 >> 1) & 0x03
        let bitrateIndex = Int((b2 >> 4) & 0x0F)
        let sampleRateIndex = Int((b2 >> 2) & 0x03)
        let padding = Int((b2 >> 1) & 0x01)
        let mode = Int((b3 >> 6) & 0x03)

        guard versionBits != 1, layerBits != 0, bitrateIndex != 0, bitrateIndex != 15, sampleRateIndex != 3 else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid mpeg header")
        }

        let version: Double
        switch versionBits {
        case 0: version = 2.5
        case 2: version = 2.0
        case 3: version = 1.0
        default: version = 0
        }

        let layer = 4 - Int(layerBits)
        let channels = mode == 3 ? 1 : 2

        let sampleRateTable: [Double: [Int]] = [
            1.0: [44100, 48000, 32000],
            2.0: [22050, 24000, 16000],
            2.5: [11025, 12000, 8000]
        ]
        let sampleRate = sampleRateTable[version]?[sampleRateIndex] ?? 0

        let bitrateTable: [String: [Int]] = [
            "V1L1": [0,32,64,96,128,160,192,224,256,288,320,352,384,416,448],
            "V1L2": [0,32,48,56,64,80,96,112,128,160,192,224,256,320,384],
            "V1L3": [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320],
            "V2L1": [0,32,48,56,64,80,96,112,128,144,160,176,192,224,256],
            "V2L2": [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160],
            "V2L3": [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160]
        ]

        let key: String
        if version == 1.0 {
            key = "V1L\(layer)"
        } else {
            key = "V2L\(layer)"
        }

        let bitrate = (bitrateTable[key]?[bitrateIndex] ?? 0) * 1000

        let samplesPerFrame: Int
        let slotSize: Int
        if layer == 1 {
            samplesPerFrame = 384
            slotSize = 4
        } else if layer == 3 && version != 1.0 {
            samplesPerFrame = 576
            slotSize = 1
        } else {
            samplesPerFrame = 1152
            slotSize = 1
        }

        let frameLength = ((samplesPerFrame / 8 * bitrate) / max(1, sampleRate) + padding) * slotSize

        return MPEGHeaderInfo(
            version: version,
            layer: layer,
            bitrate: bitrate,
            sampleRate: sampleRate,
            channels: channels,
            frameLength: frameLength,
            samplesPerFrame: samplesPerFrame
        )
    }
}
