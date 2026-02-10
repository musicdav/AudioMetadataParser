import Foundation

private struct MP4Atom {
    let type: String
    let offset: Int64
    let size: Int64
    let headerSize: Int64

    var dataOffset: Int64 { offset + headerSize }
    var endOffset: Int64 { offset + size }
}

struct MP4Parser: FormatParser {
    let format: AudioFormat = .mp4

    private let containerAtoms: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "udta", "meta", "ilst", "edts", "moof", "traf"
    ]

    func canParse(header: Data, fileHint: String?) -> Bool {
        if header.count >= 8,
           String(decoding: header[4..<8], as: Unicode.ASCII.self) == "ftyp" {
            return true
        }
        let ext = (fileHint as NSString?)?.pathExtension.lowercased() ?? ""
        return ["m4a", "m4b", "m4p", "mp4", "3g2"].contains(ext)
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        guard let fileLength = reader.length, fileLength > 8 else {
            throw AudioMetadataError(code: .truncatedData, message: "mp4 file too small")
        }

        let topAtoms = try parseAtoms(reader: reader, start: 0, end: fileLength, parentType: nil)

        guard let moov = topAtoms.first(where: { $0.type == "moov" }) else {
            throw AudioMetadataError(code: .invalidHeader, message: "moov atom missing")
        }

        let moovChildren = try parseAtoms(reader: reader, start: moov.dataOffset, end: moov.endOffset, parentType: moov.type)
        let tracks = moovChildren.filter { $0.type == "trak" }

        var length: Double?
        var sampleRate: Int?
        var channels: Int?
        var bitsPerSample: Int?

        for track in tracks {
            let trackChildren = try parseAtoms(reader: reader, start: track.dataOffset, end: track.endOffset, parentType: track.type)
            guard let mdia = trackChildren.first(where: { $0.type == "mdia" }) else { continue }

            let mdiaChildren = try parseAtoms(reader: reader, start: mdia.dataOffset, end: mdia.endOffset, parentType: mdia.type)
            guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }) else { continue }

            let hdlrData = try reader.read(at: hdlr.dataOffset, length: 16)
            guard hdlrData.count >= 12 else { continue }
            let handlerType = String(decoding: hdlrData[8..<12], as: Unicode.ASCII.self)
            if handlerType != "soun" {
                continue
            }

            if let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }) {
                let mdhdData = try reader.read(at: mdhd.dataOffset, length: Int(mdhd.size - mdhd.headerSize))
                if mdhdData.count >= 24 {
                    let version = mdhdData[0]
                    if version == 1, mdhdData.count >= 32 {
                        let timescale = Int(try mdhdData.toUInt32BE(at: 20))
                        let duration = try mdhdData.toUInt64BE(at: 24)
                        if timescale > 0 {
                            length = Double(duration) / Double(timescale)
                        }
                    } else {
                        let timescale = Int(try mdhdData.toUInt32BE(at: 12))
                        let duration = Int64(try mdhdData.toUInt32BE(at: 16))
                        if timescale > 0 {
                            length = Double(duration) / Double(timescale)
                        }
                    }
                }
            }

            if let minf = mdiaChildren.first(where: { $0.type == "minf" }) {
                let minfChildren = try parseAtoms(reader: reader, start: minf.dataOffset, end: minf.endOffset, parentType: minf.type)
                if let stbl = minfChildren.first(where: { $0.type == "stbl" }) {
                    let stblChildren = try parseAtoms(reader: reader, start: stbl.dataOffset, end: stbl.endOffset, parentType: stbl.type)
                    if let stsd = stblChildren.first(where: { $0.type == "stsd" }) {
                        let stsdData = try reader.read(at: stsd.dataOffset, length: Int(stsd.size - stsd.headerSize))
                        if stsdData.count >= 40 {
                            let entryCount = try stsdData.toUInt32BE(at: 4)
                            if entryCount > 0 {
                                let entryOffset = 8
                                if stsdData.count >= entryOffset + 36 {
                                    channels = Int(try stsdData.toUInt16BE(at: entryOffset + 16))
                                    bitsPerSample = Int(try stsdData.toUInt16BE(at: entryOffset + 18))
                                    sampleRate = Int(try stsdData.toUInt32BE(at: entryOffset + 24) >> 16)
                                }
                            }
                        }
                    }
                }
            }

            break
        }

        var tags: [String: MetadataTagValue] = [:]
        if let ilst = try findILST(reader: reader, moov: moov) {
            let parsed = try parseILST(reader: reader, ilst: ilst, options: context.options)
            tags = parsed
        }

        let bitrate = ParserHelpers.bitrate(lengthSeconds: length, fileSizeBytes: fileLength)
        let extFormat = ParserHelpers.extensionFormat(fileHint: context.fileHint)
        let resolvedFormat: AudioFormat = (extFormat == .m4a || extFormat == .mp4) ? extFormat : .mp4

        return ParsedAudioMetadata(
            format: resolvedFormat,
            coreInfo: AudioCoreInfo(length: length, bitrate: bitrate, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample),
            tags: tags,
            extensions: [:],
            diagnostics: ParserDiagnostics(parserName: "MP4Parser")
        )
    }

    private func parseAtoms(reader: WindowedReader, start: Int64, end: Int64, parentType: String?) throws -> [MP4Atom] {
        var atoms: [MP4Atom] = []
        var cursor = start
        let childStartOffset: Int64 = parentType == "meta" ? 4 : 0
        if parentType == "meta" {
            cursor += 4
        }

        while cursor + 8 <= end {
            let atom = try readAtom(reader: reader, offset: cursor, fileEnd: end)
            guard atom.size > 0 else { break }
            if atom.endOffset > end {
                break
            }
            atoms.append(atom)
            if atom.endOffset == cursor {
                break
            }
            cursor = atom.endOffset
        }

        _ = childStartOffset
        return atoms
    }

    private func readAtom(reader: WindowedReader, offset: Int64, fileEnd: Int64) throws -> MP4Atom {
        let head = try reader.read(at: offset, length: 16)
        guard head.count >= 8 else {
            throw AudioMetadataError(code: .truncatedData, message: "atom header truncated", offset: offset)
        }

        var size = Int64(try head.toUInt32BE(at: 0))
        let type = String(decoding: head[4..<8], as: Unicode.ASCII.self)
        var headerSize: Int64 = 8

        if size == 1 {
            guard head.count >= 16 else {
                throw AudioMetadataError(code: .truncatedData, message: "atom 64-bit size truncated", offset: offset)
            }
            size = Int64(try head.toUInt64BE(at: 8))
            headerSize = 16
        } else if size == 0 {
            size = fileEnd - offset
        }

        if size < headerSize {
            throw AudioMetadataError(code: .invalidHeader, message: "atom size smaller than header", offset: offset, context: ["type": type])
        }

        return MP4Atom(type: type, offset: offset, size: size, headerSize: headerSize)
    }

    private func findILST(reader: WindowedReader, moov: MP4Atom) throws -> MP4Atom? {
        let moovChildren = try parseAtoms(reader: reader, start: moov.dataOffset, end: moov.endOffset, parentType: moov.type)
        guard let udta = moovChildren.first(where: { $0.type == "udta" }) else {
            return nil
        }
        let udtaChildren = try parseAtoms(reader: reader, start: udta.dataOffset, end: udta.endOffset, parentType: udta.type)
        guard let meta = udtaChildren.first(where: { $0.type == "meta" }) else {
            return nil
        }
        let metaChildren = try parseAtoms(reader: reader, start: meta.dataOffset, end: meta.endOffset, parentType: meta.type)
        return metaChildren.first(where: { $0.type == "ilst" })
    }

    private func parseILST(
        reader: WindowedReader,
        ilst: MP4Atom,
        options: ParseOptions
    ) throws -> [String: MetadataTagValue] {
        var tags: [String: MetadataTagValue] = [:]
        let items = try parseAtoms(reader: reader, start: ilst.dataOffset, end: ilst.endOffset, parentType: ilst.type)

        for item in items {
            let itemKey = item.type
            let children = try parseAtoms(reader: reader, start: item.dataOffset, end: item.endOffset, parentType: item.type)
            for child in children where child.type == "data" {
                let dataAtom = try reader.read(at: child.offset, length: Int(child.size))
                guard dataAtom.count >= 16 else { continue }

                let dataType = try dataAtom.toUInt32BE(at: 8)
                let payload = dataAtom.subdata(in: 16..<dataAtom.count)

                switch dataType {
                case 0, 1:
                    if let text = String(data: payload, encoding: .utf8), !text.isEmpty {
                        if case let .text(existing)? = tags[itemKey] {
                            tags[itemKey] = .text(existing + [text])
                        } else {
                            tags[itemKey] = .text([text])
                        }
                    }
                case 13, 14:
                    let mime = dataType == 13 ? "image/jpeg" : "image/png"
                    tags[itemKey] = .binary(TagParsers.binaryDigest(payload: payload, mime: mime, options: options))
                case 21:
                    if itemKey == "trkn" || itemKey == "disk" {
                        if payload.count >= 6 {
                            let number = Int(payload[2]) << 8 | Int(payload[3])
                            let total = Int(payload[4]) << 8 | Int(payload[5])
                            tags[itemKey] = .text(["\(number)/\(total)"])
                        }
                    } else if payload.count >= 1 {
                        var value = 0
                        for byte in payload {
                            value = (value << 8) | Int(byte)
                        }
                        if itemKey == "cpil" {
                            tags[itemKey] = .bool(value != 0)
                        } else {
                            tags[itemKey] = .int(value)
                        }
                    }
                default:
                    if !payload.isEmpty {
                        tags[itemKey] = .binary(TagParsers.binaryDigest(payload: payload, mime: nil, options: options))
                    }
                }
            }
        }

        return tags
    }
}
