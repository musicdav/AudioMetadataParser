import Foundation

struct ParseContext {
    let fileHint: String?
    let options: ParseOptions
}

protocol FormatParser {
    var format: AudioFormat { get }
    func canParse(header: Data, fileHint: String?) -> Bool
    func parse(reader: WindowedReader, context: ParseContext) throws -> ParsedAudioMetadata
}
