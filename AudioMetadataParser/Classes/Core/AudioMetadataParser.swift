import Foundation

public actor AudioMetadataParser {
    private let options: ParseOptions
    private let limiter: ParseTaskLimiter
    private let registry = ParserRegistry()

    public init(options: ParseOptions = .default) {
        self.options = options
        self.limiter = ParseTaskLimiter(limit: options.maxConcurrentTasks)
    }

    public func parse(url: URL) async throws -> ParsedAudioMetadata {
        let source = try FileByteSource(url: url)
        return try await parse(source: source, fileHint: url.lastPathComponent)
    }

    public func parse(data: Data, fileHint: String? = nil) async throws -> ParsedAudioMetadata {
        let source = DataByteSource(data: data, fileHint: fileHint)
        return try await parse(source: source, fileHint: fileHint)
    }

    public func parse(stream: InputStream, fileHint: String? = nil) async throws -> ParsedAudioMetadata {
        let source = try StreamByteSource(stream: stream, fileHint: fileHint)
        return try await parse(source: source, fileHint: fileHint)
    }

    private func parse(source: any ByteSource, fileHint: String?) async throws -> ParsedAudioMetadata {
        try await limiter.withPermit {
            let reader = WindowedReader(source: source, windowSize: self.options.windowSize, maxReadBytes: self.options.maxReadBytes)
            let header = try reader.read(at: 0, length: 4096)
            guard let parser = self.registry.resolve(header: header, fileHint: fileHint) else {
                throw AudioMetadataError(code: .unsupportedFormat, message: "unable to resolve parser", context: ["hint": fileHint ?? ""])
            }

            var result = try parser.parse(reader: reader, context: ParseContext(fileHint: fileHint, options: self.options))
            result.diagnostics.bytesRead = reader.bytesRead
            return result
        }
    }
}
