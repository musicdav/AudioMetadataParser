import Foundation

public enum AudioMetadataErrorCode: String, Sendable {
    case unsupportedFormat
    case invalidHeader
    case truncatedData
    case inconsistentContainer
    case invalidTagPayload
    case ioFailure
    case internalInvariant
}

public struct AudioMetadataError: Error, Sendable, LocalizedError, Equatable {
    public let code: AudioMetadataErrorCode
    public let message: String
    public let offset: Int64?
    public let context: [String: String]

    public init(
        code: AudioMetadataErrorCode,
        message: String,
        offset: Int64? = nil,
        context: [String: String] = [:]
    ) {
        self.code = code
        self.message = message
        self.offset = offset
        self.context = context
    }

    public var errorDescription: String? {
        var parts = ["[\(code.rawValue)] \(message)"]
        if let offset {
            parts.append("offset=\(offset)")
        }
        if !context.isEmpty {
            parts.append("context=\(context)")
        }
        return parts.joined(separator: " ")
    }
}
