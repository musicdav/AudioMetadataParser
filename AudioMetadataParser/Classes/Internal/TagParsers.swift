import Foundation

enum TagParsers {
    static func parseSynchsafeInt(_ bytes: Data) -> Int {
        guard bytes.count >= 4 else { return 0 }
        return (Int(bytes[0] & 0x7F) << 21)
            | (Int(bytes[1] & 0x7F) << 14)
            | (Int(bytes[2] & 0x7F) << 7)
            | Int(bytes[3] & 0x7F)
    }

    static func parseID3v2(
        reader: WindowedReader,
        at offset: Int64 = 0,
        options: ParseOptions = .default
    ) throws -> (tags: [String: MetadataTagValue], size: Int) {
        let header = try reader.read(at: offset, length: 10)
        guard header.count == 10, String(decoding: header.prefix(3), as: Unicode.ASCII.self) == "ID3" else {
            return ([:], 0)
        }

        let version = Int(header[3])
        let tagSize = parseSynchsafeInt(header.subdata(in: 6..<10))
        let fullSize = 10 + tagSize
        let payload = try reader.read(at: offset + 10, length: tagSize)
        if payload.count < tagSize {
            throw AudioMetadataError(code: .truncatedData, message: "truncated id3 payload", offset: offset)
        }

        var tags: [String: MetadataTagValue] = [:]
        var cursor = 0

        while cursor + 10 <= payload.count {
            let frameHeader = payload.subdata(in: cursor ..< cursor + 10)
            if frameHeader.allSatisfy({ $0 == 0 }) {
                break
            }

            let frameID = String(decoding: frameHeader.prefix(4), as: Unicode.ASCII.self)
            guard frameID.range(of: "^[A-Z0-9]{4}$", options: .regularExpression) != nil else {
                break
            }

            let rawSize = frameHeader.subdata(in: 4..<8)
            let frameSize: Int
            if version >= 4 {
                frameSize = parseSynchsafeInt(rawSize)
            } else {
                frameSize = Int(rawSize[0]) << 24 | Int(rawSize[1]) << 16 | Int(rawSize[2]) << 8 | Int(rawSize[3])
            }

            cursor += 10
            if frameSize <= 0 || cursor + frameSize > payload.count {
                break
            }

            let frameData = payload.subdata(in: cursor ..< cursor + frameSize)
            cursor += frameSize

            if frameID.hasPrefix("T") && frameID != "TXXX" {
                if let text = decodeID3TextFrame(frameData) {
                    tags[frameID] = .text(text)
                }
                continue
            }

            if frameID == "TXXX" {
                if let parsed = decodeID3TXXX(frameData) {
                    tags["TXXX:\(parsed.key)"] = .text(parsed.values)
                }
                continue
            }

            if frameID == "COMM" {
                if let parsed = decodeID3COMM(frameData) {
                    tags["COMM:\(parsed.key)"] = .text(parsed.values)
                }
                continue
            }

            if frameID == "APIC" {
                if let digest = digestAPIC(frameData, options: options) {
                    tags["APIC"] = .binary(digest)
                }
            }
        }

        return (tags, fullSize)
    }

    private static func decodeID3TextFrame(_ data: Data) -> [String]? {
        guard !data.isEmpty else { return nil }
        let encoding = data[0]
        let payload = data.dropFirst()
        switch encoding {
        case 0:
            if let text = String(data: Data(payload), encoding: .isoLatin1) {
                return [text.trimmingCharacters(in: .controlCharacters)]
            }
            return nil
        case 1, 2:
            let bytes = Data(payload)
            let text = String(data: bytes, encoding: .utf16) ?? String(data: bytes, encoding: .utf16BigEndian)
            if let text {
                return splitID3MultiValue(text)
            }
        case 3:
            if let text = String(data: payload, encoding: .utf8) {
                return splitID3MultiValue(text)
            }
        default:
            return nil
        }
        return nil
    }

    private static func decodeID3TXXX(_ data: Data) -> (key: String, values: [String])? {
        guard !data.isEmpty else { return nil }
        let encoding = data[0]
        let payload = data.dropFirst()
        let decoded: String?
        switch encoding {
        case 0:
            decoded = String(data: Data(payload), encoding: .isoLatin1)
        case 1, 2:
            decoded = String(data: payload, encoding: .utf16) ?? String(data: payload, encoding: .utf16BigEndian)
        case 3:
            decoded = String(data: payload, encoding: .utf8)
        default:
            decoded = nil
        }
        guard let decoded else { return nil }
        let parts = decoded.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return nil }
        let values = parts.dropFirst().isEmpty ? [""] : Array(parts.dropFirst())
        return (first, values)
    }

    private static func decodeID3COMM(_ data: Data) -> (key: String, values: [String])? {
        guard data.count >= 4 else { return nil }
        let encoding = data[0]
        let body = data.dropFirst(4)
        let decoded: String?
        switch encoding {
        case 0:
            decoded = String(data: Data(body), encoding: .isoLatin1)
        case 1, 2:
            decoded = String(data: body, encoding: .utf16) ?? String(data: body, encoding: .utf16BigEndian)
        case 3:
            decoded = String(data: body, encoding: .utf8)
        default:
            decoded = nil
        }
        guard let decoded else { return nil }
        let parts = decoded.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        guard let desc = parts.first else { return nil }
        let text = parts.dropFirst().joined(separator: " ")
        return (desc, [text])
    }

    private static func digestAPIC(_ data: Data, options: ParseOptions) -> BinaryDigest? {
        guard data.count > 4 else { return nil }
        let encoding = data[0]
        var cursor = 1

        guard let mimeEnd = data[cursor...].firstIndex(of: 0) else { return nil }
        let mimeRaw = data[cursor..<mimeEnd]
        let mime = String(data: mimeRaw, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines)
        cursor = mimeEnd + 1

        // picture type
        guard cursor < data.count else { return nil }
        cursor += 1

        // description (terminated string depending on text encoding)
        guard let descriptionEnd = findDescriptionEnd(data: data, start: cursor, encoding: encoding) else { return nil }
        cursor = descriptionEnd

        guard cursor < data.count else { return nil }
        let payload = data.subdata(in: cursor..<data.count)
        guard !payload.isEmpty else { return nil }

        let normalizedMime = (mime?.isEmpty ?? true) ? nil : mime
        return binaryDigest(payload: payload, mime: normalizedMime, options: options)
    }

    private static func findDescriptionEnd(data: Data, start: Int, encoding: UInt8) -> Int? {
        guard start <= data.count else { return nil }

        switch encoding {
        case 0, 3:
            guard start < data.count else { return nil }
            guard let end = data[start...].firstIndex(of: 0) else { return nil }
            return end + 1
        case 1, 2:
            guard start + 1 < data.count else { return nil }
            var index = start
            while index + 1 < data.count {
                if data[index] == 0 && data[index + 1] == 0 {
                    return index + 2
                }
                index += 1
            }
            return nil
        default:
            guard start < data.count else { return nil }
            guard let end = data[start...].firstIndex(of: 0) else { return nil }
            return end + 1
        }
    }

    private static func splitID3MultiValue(_ text: String) -> [String] {
        text.split(separator: "\u{0}", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .controlCharacters) }
            .filter { !$0.isEmpty }
    }

    static func parseVorbisCommentPacket(_ packet: Data) -> [String: MetadataTagValue] {
        var tags: [String: MetadataTagValue] = [:]
        guard packet.count >= 8 else { return tags }
        var cursor = 0

        func readUInt32LE() -> UInt32? {
            guard cursor + 4 <= packet.count else { return nil }
            let value = UInt32(packet[cursor])
                | (UInt32(packet[cursor + 1]) << 8)
                | (UInt32(packet[cursor + 2]) << 16)
                | (UInt32(packet[cursor + 3]) << 24)
            cursor += 4
            return value
        }

        guard let vendorLength = readUInt32LE() else { return tags }
        guard cursor + Int(vendorLength) <= packet.count else { return tags }
        cursor += Int(vendorLength)

        guard let commentCount = readUInt32LE() else { return tags }
        for _ in 0..<commentCount {
            guard let len = readUInt32LE() else { break }
            guard cursor + Int(len) <= packet.count else { break }
            let chunk = packet.subdata(in: cursor ..< cursor + Int(len))
            cursor += Int(len)
            guard let text = String(data: chunk, encoding: .utf8),
                  let idx = text.firstIndex(of: "=") else {
                continue
            }
            let key = String(text[..<idx]).uppercased()
            let value = String(text[text.index(after: idx)...])
            if case let .text(values)? = tags[key] {
                tags[key] = .text(values + [value])
            } else {
                tags[key] = .text([value])
            }
        }

        return tags
    }

    static func parseAPEv2Footer(
        reader: WindowedReader,
        options: ParseOptions = .default
    ) throws -> [String: MetadataTagValue] {
        guard let totalLength = reader.length, totalLength >= 32 else {
            return [:]
        }
        let footer = try reader.read(at: totalLength - 32, length: 32)
        guard footer.count == 32,
              String(decoding: footer.prefix(8), as: Unicode.ASCII.self) == "APETAGEX" else {
            return [:]
        }

        let size = Int(try footer.toUInt32LE(at: 12))
        let itemCount = Int(try footer.toUInt32LE(at: 16))
        guard size >= 32, size <= Int(totalLength), itemCount >= 0, itemCount <= 512 else {
            return [:]
        }

        let start = totalLength - Int64(size)
        let payload = try reader.read(at: start, length: size)
        guard payload.count == size else {
            return [:]
        }

        var tags: [String: MetadataTagValue] = [:]
        var cursor = 0
        while cursor + 32 <= payload.count && tags.count < itemCount {
            if String(decoding: payload[cursor..<min(cursor + 8, payload.count)], as: Unicode.ASCII.self) == "APETAGEX" {
                break
            }

            guard cursor + 8 <= payload.count else { break }
            let valueSize = Int(try payload.toUInt32LE(at: cursor))
            let flags = Int(try payload.toUInt32LE(at: cursor + 4))
            cursor += 8

            let keyStart = cursor
            while cursor < payload.count && payload[cursor] != 0 {
                cursor += 1
            }
            guard cursor < payload.count else { break }
            let key = String(decoding: payload[keyStart..<cursor], as: Unicode.UTF8.self)
            cursor += 1

            guard valueSize >= 0, cursor + valueSize <= payload.count else { break }
            let valueData = payload.subdata(in: cursor..<cursor + valueSize)
            cursor += valueSize

            let valueType = (flags >> 1) & 0x3
            if valueType == 0 {
                let text = String(data: valueData, encoding: .utf8) ?? ""
                tags[key] = .text(text.split(separator: "\u{0}").map(String.init))
            } else {
                tags[key] = .binary(binaryDigest(payload: valueData, mime: nil, options: options))
            }
        }

        return tags
    }

    static func binaryDigest(payload: Data, mime: String?, options: ParseOptions) -> BinaryDigest {
        let shouldEmbed = options.includeBinaryData && payload.count <= options.maxBinaryTagBytes
        return BinaryDigest(
            size: payload.count,
            mime: mime,
            sha256: Crypto.sha256Hex(payload),
            data: shouldEmbed ? payload : nil
        )
    }
}
