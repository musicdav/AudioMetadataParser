import Foundation

struct ParserRegistry {
    let parsers: [FormatParser]

    init() {
        self.parsers = [
            ID3Parser(),
            MP3Parser(),
            FLACParser(),
            MP4Parser(),
            WaveParser(),
            AIFFParser(),
            OggFamilyParser(),
            ASFParser(),
            APEv2Parser(),
            AACParser(),
            AC3Parser(),
            WavPackParser(),
            MusepackParser(),
            TAKParser(),
            DSFParser(),
            DSDIFFParser(),
            TrueAudioParser(),
            OptimFROGParser(),
            SMFParser(),
            MonkeysAudioParser(),
            FallbackSignatureParser()
        ]
    }

    func resolve(header: Data, fileHint: String?) -> FormatParser? {
        let candidates = FormatProbe.probe(header: header, fileHint: fileHint)
        if candidates.isEmpty {
            return nil
        }

        let preferredFormats = candidates.map(\ .format)
        for format in preferredFormats {
            if let parser = parsers.first(where: { $0.format == format && $0.canParse(header: header, fileHint: fileHint) }) {
                return parser
            }
        }

        return parsers.first { $0.canParse(header: header, fileHint: fileHint) }
    }
}
