import Foundation

private struct OggPage {
    let offset: Int64
    let headerType: UInt8
    let granulePosition: Int64
    let serial: UInt32
    let segments: [UInt8]
    let payload: Data
    let nextOffset: Int64
}

struct OggFamilyParser: FormatParser {
    let format: AudioFormat = .ogg

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 4, String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "OggS" {
            return true
        }
        let ext = (fileHint as NSString?)?.pathExtension.lowercased() ?? ""
        return ["ogg", "oga", "ogv", "opus", "spx", "oggflac", "oggtheora"].contains(ext)
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        guard let fileLength = reader.length else {
            throw AudioMetadataError(code: .ioFailure, message: "unknown file length")
        }

        let maxPacketsPerSerial = 8
        var cursor: Int64 = 0
        var packetsBySerial: [UInt32: [Data]] = [:]
        var packetBufferBySerial: [UInt32: Data] = [:]
        var lastGranuleBySerial: [UInt32: Int64] = [:]
        var serialOrder: [UInt32] = []
        var selectedSerial: UInt32?
        var warnings: [String] = []

        while cursor + 27 <= fileLength {
            let page: OggPage
            do {
                page = try readPage(reader: reader, offset: cursor, fileLength: fileLength)
            } catch let error as AudioMetadataError {
                let hasPackets = packetsBySerial.values.contains { !$0.isEmpty }
                if hasPackets && (error.code == .truncatedData || error.code == .invalidHeader) {
                    warnings.append(error.message)
                    break
                }
                throw error
            }
            cursor = page.nextOffset

            if packetsBySerial[page.serial] == nil {
                packetsBySerial[page.serial] = []
                serialOrder.append(page.serial)
            }
            if page.granulePosition > 0 {
                lastGranuleBySerial[page.serial] = page.granulePosition
            }

            var packets = packetsBySerial[page.serial] ?? []
            var packetBuffer = packetBufferBySerial[page.serial] ?? Data()

            var payloadCursor = 0
            for segmentLength in page.segments {
                let len = Int(segmentLength)
                guard payloadCursor + len <= page.payload.count else { break }
                packetBuffer.append(page.payload.subdata(in: payloadCursor ..< payloadCursor + len))
                payloadCursor += len
                if len < 255 {
                    if packets.count < maxPacketsPerSerial {
                        packets.append(packetBuffer)
                    }
                    packetBuffer.removeAll(keepingCapacity: true)
                }
            }

            packetsBySerial[page.serial] = packets
            packetBufferBySerial[page.serial] = packetBuffer

            if selectedSerial == nil,
               let firstPacket = packets.first,
               detectCodec(from: firstPacket) != nil {
                selectedSerial = page.serial
            }

            if let serial = selectedSerial,
               page.serial == serial,
               (page.headerType & 0x04) != 0 {
                break
            }
        }

        if selectedSerial == nil {
            selectedSerial = selectByHint(context.fileHint, packetsBySerial: packetsBySerial)
        }
        if selectedSerial == nil {
            selectedSerial = serialOrder.first(where: { !(packetsBySerial[$0] ?? []).isEmpty })
        }

        guard let serial = selectedSerial,
              let packets = packetsBySerial[serial],
              let firstPacket = packets.first else {
            throw AudioMetadataError(code: .invalidHeader, message: "ogg stream contains no packets")
        }
        let lastGranule = lastGranuleBySerial[serial]

        var detectedFormat: AudioFormat = .ogg
        var sampleRate: Int?
        var channels: Int?
        let bitsPerSample: Int? = nil
        var tags: [String: MetadataTagValue] = [:]
        var bitrate: Int?
        var theoraFPS: Double?
        var theoraGranuleShift: Int?
        var opusPreSkip: Int?

        if firstPacket.count >= 7,
           firstPacket[0] == 0x01,
           String(decoding: firstPacket[1..<7], as: Unicode.ASCII.self) == "vorbis" {
            detectedFormat = .oggVorbis
            if firstPacket.count >= 16 {
                channels = Int(firstPacket[11])
                sampleRate = Int(firstPacket[12]) | (Int(firstPacket[13]) << 8) | (Int(firstPacket[14]) << 16) | (Int(firstPacket[15]) << 24)
            }
            if packets.count > 1, packets[1].count >= 7, packets[1][0] == 0x03 {
                tags = TagParsers.parseVorbisCommentPacket(Data(packets[1].dropFirst(7)))
            }
        } else if firstPacket.count >= 8,
                  String(decoding: firstPacket.prefix(8), as: Unicode.ASCII.self) == "OpusHead" {
            detectedFormat = .oggOpus
            sampleRate = 48_000
            if firstPacket.count >= 10 {
                channels = Int(firstPacket[9])
            }
            if firstPacket.count >= 12 {
                opusPreSkip = Int(firstPacket[10]) | (Int(firstPacket[11]) << 8)
            }
            if packets.count > 1, packets[1].count >= 8,
               String(decoding: packets[1].prefix(8), as: Unicode.ASCII.self) == "OpusTags" {
                tags = TagParsers.parseVorbisCommentPacket(Data(packets[1].dropFirst(8)))
            }
        } else if firstPacket.count >= 8,
                  String(decoding: firstPacket.prefix(8), as: Unicode.ASCII.self) == "Speex   " {
            detectedFormat = .oggSpeex
            if firstPacket.count >= 52 {
                sampleRate = Int(firstPacket[36]) | (Int(firstPacket[37]) << 8) | (Int(firstPacket[38]) << 16) | (Int(firstPacket[39]) << 24)
                channels = Int(firstPacket[48]) | (Int(firstPacket[49]) << 8) | (Int(firstPacket[50]) << 16) | (Int(firstPacket[51]) << 24)
            }
            if packets.count > 1 {
                tags = TagParsers.parseVorbisCommentPacket(packets[1])
            }
        } else if firstPacket.count >= 7,
                  firstPacket[0] == 0x80,
                  String(decoding: firstPacket[1..<7], as: Unicode.ASCII.self) == "theora" {
            detectedFormat = .oggTheora
            if firstPacket.count >= 42 {
                let fpsNumerator = readUInt32BE(firstPacket, at: 22)
                let fpsDenominator = readUInt32BE(firstPacket, at: 26)
                if fpsNumerator > 0, fpsDenominator > 0 {
                    theoraFPS = Double(fpsNumerator) / Double(fpsDenominator)
                }
                bitrate = Int(firstPacket[37]) << 16
                    | (Int(firstPacket[38]) << 8)
                    | Int(firstPacket[39])
                let granuleConfig = (Int(firstPacket[40]) << 8) | Int(firstPacket[41])
                theoraGranuleShift = (granuleConfig >> 5) & 0x1F
            }
            if let commentPacket = packets.first(where: {
                $0.count >= 7 && $0[0] == 0x81 && String(decoding: $0[1..<7], as: Unicode.ASCII.self) == "theora"
            }) {
                tags = TagParsers.parseVorbisCommentPacket(Data(commentPacket.dropFirst(7)))
            }
        } else if firstPacket.count >= 5,
                  firstPacket[0] == 0x7F,
                  String(decoding: firstPacket[1..<5], as: Unicode.ASCII.self) == "FLAC" {
            detectedFormat = .oggFlac
            if let index = firstPacket.range(of: Data("fLaC".utf8))?.lowerBound,
               firstPacket.count >= index + 4 + 4 + 18 {
                let streamInfo = firstPacket.subdata(in: index + 4 + 4 ..< index + 4 + 4 + 18)
                let b10 = UInt64(streamInfo[10])
                let b11 = UInt64(streamInfo[11])
                let b12 = UInt64(streamInfo[12])
                sampleRate = Int((b10 << 12) | (b11 << 4) | (b12 >> 4))
                channels = Int(((b12 >> 1) & 0x07) + 1)
            }
            if packets.count > 1 {
                tags = TagParsers.parseVorbisCommentPacket(packets[1])
            }
        }

        let length: Double?
        if detectedFormat == .oggTheora,
           let granule = lastGranule,
           let fps = theoraFPS,
           let granuleShift = theoraGranuleShift,
           granule >= 0,
           fps > 0 {
            let shift = UInt64(min(granuleShift, 63))
            let position = UInt64(bitPattern: granule)
            let mask = shift > 0 ? ((UInt64(1) << shift) - 1) : 0
            let frames = (position >> shift) + (position & mask)
            length = Double(frames) / fps
        } else if detectedFormat == .oggOpus,
                  let sampleRate,
                  let granule = lastGranule,
                  sampleRate > 0,
                  granule > 0 {
            let preSkip = opusPreSkip ?? 0
            let effectiveSamples = max(0, granule - Int64(preSkip))
            length = effectiveSamples > 0 ? Double(effectiveSamples) / Double(sampleRate) : nil
        } else if let sampleRate, let granule = lastGranule, sampleRate > 0, granule > 0 {
            length = Double(granule) / Double(sampleRate)
        } else {
            length = nil
        }

        if bitrate == nil {
            bitrate = ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: fileLength)
        }
        if let extFormat = normalizeByExtension(context.fileHint), extFormat != .ogg {
            detectedFormat = extFormat
        }

        return ParsedAudioMetadata(
            format: detectedFormat,
            coreInfo: AudioCoreInfo(length: length, bitrate: bitrate, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "OggFamilyParser", warnings: warnings)
        )
    }

    private func detectCodec(from packet: Data) -> AudioFormat? {
        if packet.count >= 7,
           packet[0] == 0x01,
           String(decoding: packet[1..<7], as: Unicode.ASCII.self) == "vorbis" {
            return .oggVorbis
        }
        if packet.count >= 8,
           String(decoding: packet.prefix(8), as: Unicode.ASCII.self) == "OpusHead" {
            return .oggOpus
        }
        if packet.count >= 8,
           String(decoding: packet.prefix(8), as: Unicode.ASCII.self) == "Speex   " {
            return .oggSpeex
        }
        if packet.count >= 7,
           packet[0] == 0x80,
           String(decoding: packet[1..<7], as: Unicode.ASCII.self) == "theora" {
            return .oggTheora
        }
        if packet.count >= 5,
           packet[0] == 0x7F,
           String(decoding: packet[1..<5], as: Unicode.ASCII.self) == "FLAC" {
            return .oggFlac
        }
        return nil
    }

    private func selectByHint(_ hint: String?, packetsBySerial: [UInt32: [Data]]) -> UInt32? {
        guard let hint else { return nil }
        let ext = (hint as NSString).pathExtension.lowercased()
        let target: AudioFormat?
        switch ext {
        case "opus": target = .oggOpus
        case "spx": target = .oggSpeex
        case "oggflac": target = .oggFlac
        case "oggtheora", "ogv": target = .oggTheora
        case "ogg", "oga": target = .oggVorbis
        default: target = nil
        }
        guard let target else { return nil }

        for (serial, packets) in packetsBySerial {
            guard let first = packets.first else { continue }
            if detectCodec(from: first) == target {
                return serial
            }
        }
        return nil
    }

    private func normalizeByExtension(_ hint: String?) -> AudioFormat? {
        let ext = (hint as NSString?)?.pathExtension.lowercased() ?? ""
        switch ext {
        case "opus": return .oggOpus
        case "spx": return .oggSpeex
        case "oggflac": return .oggFlac
        case "oggtheora", "ogv": return .oggTheora
        default: return nil
        }
    }

    private func readPage(reader: WindowedReader, offset: Int64, fileLength: Int64) throws -> OggPage {
        let fixedHeader = try reader.read(at: offset, length: 27)
        guard fixedHeader.count == 27,
              String(decoding: fixedHeader.prefix(4), as: Unicode.ASCII.self) == "OggS" else {
            throw AudioMetadataError(code: .invalidHeader, message: "invalid ogg page", offset: offset)
        }

        let segmentCount = Int(fixedHeader[26])
        let segmentTable = try reader.read(at: offset + 27, length: segmentCount)
        guard segmentTable.count == segmentCount else {
            throw AudioMetadataError(code: .truncatedData, message: "truncated ogg segment table", offset: offset)
        }

        let payloadSize = segmentTable.reduce(0) { $0 + Int($1) }
        let payloadOffset = offset + 27 + Int64(segmentCount)
        let payload = try reader.read(at: payloadOffset, length: payloadSize)
        guard payload.count == payloadSize else {
            throw AudioMetadataError(code: .truncatedData, message: "truncated ogg payload", offset: payloadOffset)
        }

        let granule = Int64(bitPattern: try fixedHeader.toUInt64LE(at: 6))
        let serial = try fixedHeader.toUInt32LE(at: 14)
        let nextOffset = payloadOffset + Int64(payloadSize)
        if nextOffset > fileLength + 1 {
            throw AudioMetadataError(code: .truncatedData, message: "ogg page beyond file end", offset: offset)
        }

        return OggPage(
            offset: offset,
            headerType: fixedHeader[5],
            granulePosition: granule,
            serial: serial,
            segments: Array(segmentTable),
            payload: payload,
            nextOffset: nextOffset
        )
    }

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
