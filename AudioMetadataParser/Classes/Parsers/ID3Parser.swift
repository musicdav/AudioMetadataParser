import Foundation

struct ID3Parser: FormatParser {
    let format: AudioFormat = .id3

    func canParse(header: Data, fileHint: String?) -> Bool {
        let ext = (fileHint as NSString?)?.pathExtension.lowercased() ?? ""
        if ext == "id3" {
            return true
        }
        return header.count >= 3 && String(decoding: header.prefix(3), as: Unicode.ASCII.self) == "ID3" && ext != "mp3"
    }

    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata {
        let parsed = try TagParsers.parseID3v2(reader: reader, at: 0, options: context.options)
        if parsed.size == 0 {
            throw AudioMetadataError(code: .invalidHeader, message: "id3 header not found")
        }

        return ParsedAudioMetadata(
            format: .id3,
            coreInfo: AudioCoreInfo(),
            tags: parsed.tags,
            extensions: ["tag_size": .int(parsed.size)],
            diagnostics: ParserDiagnostics(parserName: "ID3Parser")
        )
    }
}
