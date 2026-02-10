import Foundation

struct ASFParser: FormatParser {
    let format: AudioFormat = .asf

    private let asfHeaderGUID = Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C])
    private let filePropGUID = Data([0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65])
    private let streamPropGUID = Data([0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65])
    private let contentDescGUID = Data([0x33, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C])
    private let audioMediaGUID = Data([0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B])

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 16, header.prefix(16) == asfHeaderGUID {
            return true
        }
        return ["asf", "wma"].contains((fileHint as NSString?)?.pathExtension.lowercased() ?? "")
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let header = try reader.read(at: 0, length: 30)
        guard header.count >= 30, header.prefix(16) == asfHeaderGUID else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid asf header")
        }

        let objectCount = Int(try header.toUInt32LE(at: 24))
        var cursor: Int64 = 30

        var length: Double?
        var sampleRate: Int?
        var channels: Int?
        var bitsPerSample: Int?
        var bitrate: Int?
        var tags: [String: MetadataTagValue] = [:]

        for _ in 0..<min(objectCount, 1024) {
            let objectHeader = try reader.read(at: cursor, length: 24)
            guard objectHeader.count == 24 else { break }
            let guid = objectHeader.prefix(16)
            let objectSize = Int64(try objectHeader.toUInt64LE(at: 16))
            if objectSize < 24 {
                break
            }

            let payloadSize = Int(objectSize - 24)
            let payload = try reader.read(at: cursor + 24, length: payloadSize)

            if guid == filePropGUID, payload.count >= 80 {
                let playDuration = try payload.toUInt64LE(at: 40)
                let prerollMs = try payload.toUInt64LE(at: 56)
                let duration100ns = playDuration > prerollMs * 10_000 ? playDuration - prerollMs * 10_000 : playDuration
                length = Double(duration100ns) / 10_000_000.0
                bitrate = Int(try payload.toUInt32LE(at: 76))
            } else if guid == streamPropGUID, payload.count >= 80 {
                let streamType = payload.prefix(16)
                if streamType == audioMediaGUID, payload.count >= 70 {
                    let typeSpecificLength = Int(try payload.toUInt32LE(at: 40))
                    let formatOffset = 54
                    if typeSpecificLength >= 16, payload.count >= formatOffset + 16 {
                        channels = Int(try payload.toUInt16LE(at: formatOffset + 2))
                        sampleRate = Int(try payload.toUInt32LE(at: formatOffset + 4))
                        let avgBytes = Int(try payload.toUInt32LE(at: formatOffset + 8))
                        bitsPerSample = Int(try payload.toUInt16LE(at: formatOffset + 14))
                        if avgBytes > 0 {
                            bitrate = avgBytes * 8
                        }
                    }
                }
            } else if guid == contentDescGUID, payload.count >= 10 {
                let titleLength = Int(try payload.toUInt16LE(at: 0))
                let artistLength = Int(try payload.toUInt16LE(at: 2))
                let copyrightLength = Int(try payload.toUInt16LE(at: 4))
                let descriptionLength = Int(try payload.toUInt16LE(at: 6))
                let ratingLength = Int(try payload.toUInt16LE(at: 8))

                var pos = 10
                func readUTF16(_ length: Int) -> String {
                    guard length > 0, pos + length <= payload.count else { return "" }
                    let data = payload.subdata(in: pos ..< pos + length)
                    pos += length
                    return String(data: data, encoding: .utf16LittleEndian)?.trimmingCharacters(in: .controlCharacters) ?? ""
                }

                let title = readUTF16(titleLength)
                let artist = readUTF16(artistLength)
                let _ = readUTF16(copyrightLength)
                let comment = readUTF16(descriptionLength)
                let _ = readUTF16(ratingLength)

                if let value = ParserHelpers.textTag(title) { tags["Title"] = value }
                if let value = ParserHelpers.textTag(artist) { tags["Author"] = value }
                if let value = ParserHelpers.textTag(comment) { tags["Description"] = value }
            }

            cursor += objectSize
            if let fileLength = reader.length, cursor >= fileLength {
                break
            }
        }

        if bitrate == nil {
            bitrate = ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: reader.length)
        }

        return ParsedAudioMetadata(
            format: .asf,
            coreInfo: AudioCoreInfo(length: length, bitrate: bitrate, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "ASFParser")
        )
    }
}

struct APEv2Parser: FormatParser {
    let format: AudioFormat = .apev2

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 8, String(decoding: header.prefix(8), as: Unicode.ASCII.self) == "APETAGEX" {
            return true
        }
        let ext = (fileHint as NSString?)?.pathExtension.lowercased() ?? ""
        return ext == "apev2" || ext == "ape"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let tags = (try? TagParsers.parseAPEv2Footer(reader: reader, options: context.options)) ?? [:]
        return ParsedAudioMetadata(
            format: .apev2,
            coreInfo: AudioCoreInfo(),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "APEv2Parser")
        )
    }
}

struct AACParser: FormatParser {
    let format: AudioFormat = .aac

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "ADIF" {
            return true
        }
        if header.count >= 2, header[0] == 0xFF, (header[1] & 0xF0) == 0xF0 {
            return true
        }
        return (fileHint as NSString?)?.pathExtension.lowercased() == "aac"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let header = try reader.read(at: 0, length: 9)
        guard !header.isEmpty else {
            throw AudioMetadataError(code: .truncatedData, message: "empty aac")
        }

        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "ADIF" {
            return ParsedAudioMetadata(
                format: .aac,
                coreInfo: AudioCoreInfo(length: nil, bitrate: nil, sampleRate: nil, channels: nil, bitsPerSample: nil),
                tags: [:],
                extensions: ["profile": .text(["ADIF"])],
                diagnostics: ParserDiagnostics(parserName: "AACParser")
            )
        }

        guard header.count >= 7, header[0] == 0xFF, (header[1] & 0xF0) == 0xF0 else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid adts header")
        }

        let samplingFrequencyIndex = Int((header[2] >> 2) & 0x0F)
        let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let sampleRate = samplingFrequencyIndex < sampleRates.count ? sampleRates[samplingFrequencyIndex] : nil

        let channels = Int(((header[2] & 0x01) << 2) | ((header[3] >> 6) & 0x03))
        let frameLength = Int((UInt16(header[3] & 0x03) << 11) | (UInt16(header[4]) << 3) | UInt16((header[5] >> 5) & 0x07))

        var bitrate: Int?
        if let sampleRate, frameLength > 0 {
            bitrate = Int((Double(frameLength) * 8.0 * Double(sampleRate)) / 1024.0)
        }

        var length: Double?
        if let bitrate, let fileLength = reader.length, bitrate > 0 {
            length = (Double(fileLength) * 8.0) / Double(bitrate)
        }

        return ParsedAudioMetadata(
            format: .aac,
            coreInfo: AudioCoreInfo(length: length, bitrate: bitrate, sampleRate: sampleRate, channels: channels, bitsPerSample: nil),
            tags: [:],
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "AACParser")
        )
    }
}

struct AC3Parser: FormatParser {
    let format: AudioFormat = .ac3

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 2, header[0] == 0x0B, header[1] == 0x77 {
            return true
        }
        let ext = (fileHint as NSString?)?.pathExtension.lowercased() ?? ""
        return ext == "ac3" || ext == "eac3"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let data = try reader.read(at: 0, length: 8)
        guard data.count >= 7, data[0] == 0x0B, data[1] == 0x77 else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid ac3/eac3 header")
        }

        let fscod = Int((data[4] & 0xC0) >> 6)
        let frmsizecod = Int(data[4] & 0x3F)
        let bsid = Int((data[5] & 0xF8) >> 3)
        let acmod = Int((data[6] & 0xE0) >> 5)
        let lfeon = Int((data[6] & 0x10) >> 4)

        let sampleRates = [48000, 44100, 32000]
        let sampleRate = fscod < sampleRates.count ? sampleRates[fscod] : nil

        let bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
        let bitrate = frmsizecod / 2 < bitrates.count ? bitrates[frmsizecod / 2] * 1000 : nil

        let channelMap = [2, 1, 2, 3, 3, 4, 4, 5]
        var channels = acmod < channelMap.count ? channelMap[acmod] : nil
        if lfeon == 1, let channelsValue = channels {
            channels = channelsValue + 1
        }

        var length: Double?
        if let bitrate, let fileLength = reader.length, bitrate > 0 {
            length = (Double(fileLength) * 8.0) / Double(bitrate)
        }

        let resolvedFormat: AudioFormat = bsid > 10 ? .eac3 : .ac3

        return ParsedAudioMetadata(
            format: resolvedFormat,
            coreInfo: AudioCoreInfo(length: length, bitrate: bitrate, sampleRate: sampleRate, channels: channels, bitsPerSample: nil),
            tags: [:],
            extensions: ["bsid": .int(bsid)],
            diagnostics: ParserDiagnostics(parserName: "AC3Parser")
        )
    }
}

struct WavPackParser: FormatParser {
    let format: AudioFormat = .wavpack

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "wvpk" {
            return true
        }
        return (fileHint as NSString?)?.pathExtension.lowercased() == "wv"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let header = try reader.read(at: 0, length: 32)
        guard header.count >= 32,
              String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "wvpk" else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid wavpack header")
        }

        let version = Int(try header.toUInt16LE(at: 8))
        let totalSamples = Int64(try header.toUInt32LE(at: 12))
        let flags = Int(try header.toUInt32LE(at: 24))

        let sampleRateIndex = (flags >> 23) & 0x0F
        let sampleRates = [6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000, 192000, 0]
        let sampleRate = sampleRateIndex < sampleRates.count ? sampleRates[sampleRateIndex] : nil

        let channels = (flags & 0x4) != 0 ? 1 : 2
        let bitsPerSample = ((flags & 0x3) + 1) * 8

        var length: Double?
        if let sampleRate, sampleRate > 0, totalSamples > 0, totalSamples != 0xFFFFFFFF {
            length = Double(totalSamples) / Double(sampleRate)
        }

        let bitrate = ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: reader.length)
        let tags = (try? TagParsers.parseAPEv2Footer(reader: reader, options: context.options)) ?? [:]

        return ParsedAudioMetadata(
            format: .wavpack,
            coreInfo: AudioCoreInfo(length: length, bitrate: bitrate, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: ["version": .int(version)],
            diagnostics: ParserDiagnostics(parserName: "WavPackParser")
        )
    }
}

struct MusepackParser: FormatParser {
    let format: AudioFormat = .musepack

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4 {
            let magic = String(decoding: header.prefix(4), as: Unicode.ASCII.self)
            if magic == "MPCK" || magic.hasPrefix("MP+") {
                return true
            }
        }
        return (fileHint as NSString?)?.pathExtension.lowercased() == "mpc"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let head = try reader.read(at: 0, length: 16)
        guard head.count >= 4 else {
            throw AudioMetadataError(code: .truncatedData, message: "musepack header truncated")
        }

        var extensions: [String: MetadataTagValue] = [:]
        if String(decoding: head.prefix(4), as: Unicode.ASCII.self) == "MPCK" {
            extensions["stream_version"] = .text(["SV8"])
        } else if String(decoding: head.prefix(3), as: Unicode.ASCII.self) == "MP+" {
            extensions["stream_version"] = .text(["SV7"])
        }

        let tags = (try? TagParsers.parseAPEv2Footer(reader: reader, options: context.options)) ?? [:]

        return ParsedAudioMetadata(
            format: .musepack,
            coreInfo: AudioCoreInfo(length: nil, bitrate: nil, sampleRate: nil, channels: nil, bitsPerSample: nil),
            tags: tags,
            extensions: extensions,
            diagnostics: ParserDiagnostics(parserName: "MusepackParser")
        )
    }
}

struct TAKParser: FormatParser {
    let format: AudioFormat = .tak

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "tBaK" {
            return true
        }
        return (fileHint as NSString?)?.pathExtension.lowercased() == "tak"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let head = try reader.read(at: 0, length: 4)
        guard head.count == 4, String(decoding: head, as: Unicode.ASCII.self) == "tBaK" else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid tak header")
        }
        let tags = (try? TagParsers.parseAPEv2Footer(reader: reader, options: context.options)) ?? [:]
        return ParsedAudioMetadata(
            format: .tak,
            coreInfo: AudioCoreInfo(),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "TAKParser")
        )
    }
}

struct DSFParser: FormatParser {
    let format: AudioFormat = .dsf

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "DSD " {
            return true
        }
        return (fileHint as NSString?)?.pathExtension.lowercased() == "dsf"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let dsdHeader = try reader.read(at: 0, length: 28)
        guard dsdHeader.count == 28,
              String(decoding: dsdHeader.prefix(4), as: Unicode.ASCII.self) == "DSD " else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid dsf header")
        }

        let metadataPointer = Int64(try dsdHeader.toUInt64LE(at: 20))

        let fmtHeader = try reader.read(at: 28, length: 52 + 12)
        guard fmtHeader.count >= 64,
              String(decoding: fmtHeader.prefix(4), as: Unicode.ASCII.self) == "fmt " else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid dsf fmt chunk")
        }

        let channels = Int(try fmtHeader.toUInt32LE(at: 24))
        let sampleRate = Int(try fmtHeader.toUInt32LE(at: 28))
        let bitsPerSample = Int(try fmtHeader.toUInt32LE(at: 32))
        let sampleCount = try fmtHeader.toUInt64LE(at: 36)

        let length = sampleRate > 0 ? Double(sampleCount) / Double(sampleRate) : nil

        var tags: [String: MetadataTagValue] = [:]
        if metadataPointer > 0, let fileLength = reader.length, metadataPointer < fileLength {
            let id3Data = try reader.read(at: metadataPointer, length: Int(fileLength - metadataPointer))
            let id3Reader = WindowedReader(source: DataByteSource(data: id3Data, fileHint: nil), windowSize: context.options.windowSize, maxReadBytes: context.options.maxReadBytes)
            if let parsed = try? TagParsers.parseID3v2(reader: id3Reader, options: context.options), parsed.size > 0 {
                tags = parsed.tags
            }
        }

        return ParsedAudioMetadata(
            format: .dsf,
            coreInfo: AudioCoreInfo(length: length, bitrate: ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: reader.length), sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "DSFParser")
        )
    }
}

struct DSDIFFParser: FormatParser {
    let format: AudioFormat = .dsdiff

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "FRM8" {
            return true
        }
        let ext = (fileHint as NSString?)?.pathExtension.lowercased() ?? ""
        return ext == "dff" || ext == "dsdiff"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let head = try reader.read(at: 0, length: 12)
        guard head.count == 12,
              String(decoding: head.prefix(4), as: Unicode.ASCII.self) == "FRM8" else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid dsdiff header")
        }

        var cursor: Int64 = 12
        var sampleRate: Int?
        var channels: Int?
        let bitsPerSample: Int? = 1
        var dsdDataBytes: Int64?
        var tags: [String: MetadataTagValue] = [:]

        while let fileLength = reader.length, cursor + 12 <= fileLength {
            let chunkHead = try reader.read(at: cursor, length: 12)
            guard chunkHead.count == 12 else { break }
            let id = String(decoding: chunkHead.prefix(4), as: Unicode.ASCII.self)
            let size = Int64(try chunkHead.toUInt64BE(at: 4))
            let dataOffset = cursor + 12

            if id == "PROP" {
                let propType = try reader.read(at: dataOffset, length: 4)
                if String(decoding: propType, as: Unicode.ASCII.self) == "SND " {
                    var subCursor = dataOffset + 4
                    let propEnd = dataOffset + size
                    while subCursor + 12 <= propEnd {
                        let subHead = try reader.read(at: subCursor, length: 12)
                        let subID = String(decoding: subHead.prefix(4), as: Unicode.ASCII.self)
                        let subSize = Int64(try subHead.toUInt64BE(at: 4))
                        let subDataOffset = subCursor + 12
                        if subID == "FS  " {
                            let fs = try reader.read(at: subDataOffset, length: 4)
                            sampleRate = Int(try fs.toUInt32BE(at: 0))
                        } else if subID == "CHNL" {
                            let ch = try reader.read(at: subDataOffset, length: 2)
                            channels = Int(try ch.toUInt16BE(at: 0))
                        }
                        subCursor = subDataOffset + subSize + (subSize % 2)
                    }
                }
            } else if id == "DSD " {
                dsdDataBytes = size
            } else if id == "ID3 " {
                let id3Data = try reader.read(at: dataOffset, length: Int(size))
                let id3Reader = WindowedReader(source: DataByteSource(data: id3Data, fileHint: nil), windowSize: context.options.windowSize, maxReadBytes: context.options.maxReadBytes)
                if let parsed = try? TagParsers.parseID3v2(reader: id3Reader, options: context.options) {
                    tags = parsed.tags
                }
            }

            cursor = dataOffset + size + (size % 2)
        }

        let length: Double?
        if let sampleRate, let channels, let dsdDataBytes, sampleRate > 0, channels > 0 {
            length = (Double(dsdDataBytes) * 8.0) / (Double(sampleRate) * Double(channels))
        } else {
            length = nil
        }

        return ParsedAudioMetadata(
            format: .dsdiff,
            coreInfo: AudioCoreInfo(length: length, bitrate: ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: reader.length), sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "DSDIFFParser")
        )
    }
}

struct TrueAudioParser: FormatParser {
    let format: AudioFormat = .trueAudio

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "TTA1" {
            return true
        }
        return (fileHint as NSString?)?.pathExtension.lowercased() == "tta"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let data = try reader.read(at: 0, length: 22)
        guard data.count >= 18,
              String(decoding: data.prefix(4), as: Unicode.ASCII.self) == "TTA1" else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid trueaudio header")
        }

        let channels = Int(try data.toUInt16LE(at: 6))
        let bitsPerSample = Int(try data.toUInt16LE(at: 8))
        let sampleRate = Int(try data.toUInt32LE(at: 10))
        let sampleCount = Int64(try data.toUInt32LE(at: 14))
        let length = sampleRate > 0 ? Double(sampleCount) / Double(sampleRate) : nil

        let tags = (try? TagParsers.parseID3v2(reader: reader, at: 0, options: context.options).tags) ?? [:]

        return ParsedAudioMetadata(
            format: .trueAudio,
            coreInfo: AudioCoreInfo(length: length, bitrate: ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: reader.length), sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "TrueAudioParser")
        )
    }
}

struct OptimFROGParser: FormatParser {
    let format: AudioFormat = .optimFrog

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "OFR " {
            return true
        }
        let ext = (fileHint as NSString?)?.pathExtension.lowercased() ?? ""
        return ext == "ofr" || ext == "ofs"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let head = try reader.read(at: 0, length: 8)
        guard head.count >= 4,
              String(decoding: head.prefix(4), as: Unicode.ASCII.self) == "OFR " else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid optimfrog header")
        }

        return ParsedAudioMetadata(
            format: .optimFrog,
            coreInfo: AudioCoreInfo(),
            tags: [:],
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "OptimFROGParser")
        )
    }
}

struct SMFParser: FormatParser {
    let format: AudioFormat = .smf

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "MThd" {
            return true
        }
        let ext = (fileHint as NSString?)?.pathExtension.lowercased() ?? ""
        return ext == "mid" || ext == "smf"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let header = try reader.read(at: 0, length: 14)
        guard header.count >= 14,
              String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "MThd" else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid midi header")
        }

        let headerLength = Int(try header.toUInt32BE(at: 4))
        let trackCount = Int(try header.toUInt16BE(at: 10))
        let division = Int(try header.toUInt16BE(at: 12))

        var cursor: Int64 = Int64(8 + headerLength)
        var maxTicks = 0
        var tempoEvents: [(tick: Int, usPerQuarter: Int)] = [(0, 500_000)]

        for _ in 0..<trackCount {
            let trackHeader = try reader.read(at: cursor, length: 8)
            guard trackHeader.count == 8,
                  String(decoding: trackHeader.prefix(4), as: Unicode.ASCII.self) == "MTrk" else {
                break
            }
            let trackLength = Int(try trackHeader.toUInt32BE(at: 4))
            let trackData = try reader.read(at: cursor + 8, length: trackLength)
            let parsed = parseTrack(trackData)
            maxTicks = max(maxTicks, parsed.maxTick)
            tempoEvents.append(contentsOf: parsed.tempoEvents)
            cursor += Int64(8 + trackLength)
        }

        let length = computeMIDILength(maxTicks: maxTicks, division: division, tempoEvents: tempoEvents)

        return ParsedAudioMetadata(
            format: .smf,
            coreInfo: AudioCoreInfo(length: length, bitrate: nil, sampleRate: nil, channels: nil, bitsPerSample: nil),
            tags: [:],
            extensions: ["tracks": .int(trackCount)],
            diagnostics: ParserDiagnostics(parserName: "SMFParser")
        )
    }

    private func parseTrack(_ data: Data) -> (maxTick: Int, tempoEvents: [(Int, Int)]) {
        var cursor = 0
        var tick = 0
        var maxTick = 0
        var runningStatus: UInt8 = 0
        var tempos: [(Int, Int)] = []

        func readVarLen() -> Int {
            var value = 0
            var count = 0
            while cursor < data.count && count < 4 {
                let byte = Int(data[cursor])
                cursor += 1
                value = (value << 7) | (byte & 0x7F)
                count += 1
                if (byte & 0x80) == 0 {
                    break
                }
            }
            return value
        }

        while cursor < data.count {
            tick += readVarLen()
            maxTick = max(maxTick, tick)
            if cursor >= data.count { break }

            var status = data[cursor]
            if status < 0x80 {
                status = runningStatus
            } else {
                cursor += 1
                runningStatus = status
            }

            if status == 0xFF {
                if cursor + 1 > data.count { break }
                let type = data[cursor]
                cursor += 1
                let len = readVarLen()
                if type == 0x51, len == 3, cursor + 3 <= data.count {
                    let tempo = Int(data[cursor]) << 16 | Int(data[cursor + 1]) << 8 | Int(data[cursor + 2])
                    tempos.append((tick, tempo))
                }
                cursor += len
                continue
            }

            if status == 0xF0 || status == 0xF7 {
                let len = readVarLen()
                cursor += len
                continue
            }

            let high = status & 0xF0
            let dataBytes = (high == 0xC0 || high == 0xD0) ? 1 : 2
            cursor += dataBytes
        }

        return (maxTick, tempos)
    }

    private func computeMIDILength(maxTicks: Int, division: Int, tempoEvents: [(Int, Int)]) -> Double? {
        guard division > 0 else { return nil }
        let tpq = division & 0x7FFF
        if tpq <= 0 { return nil }

        let sorted = tempoEvents.sorted { $0.0 < $1.0 }
        var lastTick = 0
        var currentTempo = 500_000
        var seconds = 0.0

        for (tick, tempo) in sorted where tick <= maxTicks {
            let deltaTicks = max(0, tick - lastTick)
            seconds += (Double(deltaTicks) / Double(tpq)) * (Double(currentTempo) / 1_000_000.0)
            lastTick = tick
            currentTempo = tempo
        }

        if maxTicks > lastTick {
            let deltaTicks = maxTicks - lastTick
            seconds += (Double(deltaTicks) / Double(tpq)) * (Double(currentTempo) / 1_000_000.0)
        }

        return seconds
    }
}

struct MonkeysAudioParser: FormatParser {
    let format: AudioFormat = .monkeysAudio

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "MAC " {
            return true
        }
        return (fileHint as NSString?)?.pathExtension.lowercased() == "ape"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let header = try reader.read(at: 0, length: 128)
        guard header.count >= 6,
              String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "MAC " else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid monkey's audio header")
        }

        let version = Int(try header.toUInt16LE(at: 4))
        var sampleRate: Int?
        var channels: Int?
        var bitsPerSample: Int?
        var length: Double?

        if version >= 3980, header.count >= 84 {
            let descriptorBytes = Int(try header.toUInt32LE(at: 6))
            let headerBytes = Int(try header.toUInt32LE(at: 10))
            let headerOffset = 6 + descriptorBytes
            if headerBytes >= 24, header.count >= headerOffset + 24 {
                let blocksPerFrame = Int(try header.toUInt32LE(at: headerOffset + 4))
                let finalFrameBlocks = Int(try header.toUInt32LE(at: headerOffset + 8))
                let totalFrames = Int(try header.toUInt32LE(at: headerOffset + 12))
                bitsPerSample = Int(try header.toUInt16LE(at: headerOffset + 16))
                channels = Int(try header.toUInt16LE(at: headerOffset + 18))
                sampleRate = Int(try header.toUInt32LE(at: headerOffset + 20))
                if let sampleRate, sampleRate > 0, totalFrames > 0 {
                    let totalSamples = max(0, (totalFrames - 1) * blocksPerFrame + finalFrameBlocks)
                    length = Double(totalSamples) / Double(sampleRate)
                }
            }
        }

        return ParsedAudioMetadata(
            format: .monkeysAudio,
            coreInfo: AudioCoreInfo(length: length, bitrate: ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: reader.length), sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: (try? TagParsers.parseAPEv2Footer(reader: reader, options: context.options)) ?? [:],
            extensions: ["version": .int(version)],
            diagnostics: ParserDiagnostics(parserName: "MonkeysAudioParser")
        )
    }
}

struct FallbackSignatureParser: FormatParser {
    let format: AudioFormat = .unknown

    func canParse(header: Data, fileHint: String?) -> Bool {
        true
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let probe = FormatProbe.probe(header: try reader.read(at: 0, length: 64), fileHint: context.fileHint)
        let guessed = probe.first?.format ?? ParserHelpers.extensionFormat(fileHint: context.fileHint)

        var tags: [String: MetadataTagValue] = [:]
        if let id3 = try? TagParsers.parseID3v2(reader: reader, options: context.options), id3.size > 0 {
            tags.merge(id3.tags, uniquingKeysWith: { _, new in new })
        }
        if let ape = try? TagParsers.parseAPEv2Footer(reader: reader, options: context.options) {
            tags.merge(ape, uniquingKeysWith: { old, _ in old })
        }

        return ParsedAudioMetadata(
            format: guessed,
            coreInfo: AudioCoreInfo(),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "FallbackSignatureParser", warnings: ["limited parser fallback used"])
        )
    }
}
