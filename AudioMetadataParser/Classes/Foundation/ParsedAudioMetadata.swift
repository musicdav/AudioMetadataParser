import Foundation

public struct AudioCoreInfo: Sendable, Equatable {
    public var length: Double?
    public var bitrate: Int?
    public var sampleRate: Int?
    public var channels: Int?
    public var bitsPerSample: Int?

    public init(
        length: Double? = nil,
        bitrate: Int? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        bitsPerSample: Int? = nil
    ) {
        self.length = length
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }
}

public struct BinaryDigest: Sendable, Equatable {
    public var size: Int
    public var mime: String?
    public var sha256: String
    public var data: Data?

    public init(size: Int, mime: String? = nil, sha256: String, data: Data? = nil) {
        self.size = size
        self.mime = mime
        self.sha256 = sha256
        self.data = data
    }
}

public enum MetadataTagValue: Sendable, Equatable {
    case text([String])
    case int(Int)
    case double(Double)
    case bool(Bool)
    case binary(BinaryDigest)
}

public struct ParserDiagnostics: Sendable, Equatable {
    public var parserName: String
    public var bytesRead: Int
    public var warnings: [String]
    public var context: [String: String]

    public init(
        parserName: String,
        bytesRead: Int = 0,
        warnings: [String] = [],
        context: [String: String] = [:]
    ) {
        self.parserName = parserName
        self.bytesRead = bytesRead
        self.warnings = warnings
        self.context = context
    }
}

public struct ParsedAudioMetadata: Sendable, Equatable {
    public var format: AudioFormat
    public var coreInfo: AudioCoreInfo
    public var tags: [String: MetadataTagValue]
    public var extensions: [String: MetadataTagValue]
    public var diagnostics: ParserDiagnostics

    public init(
        format: AudioFormat,
        coreInfo: AudioCoreInfo,
        tags: [String: MetadataTagValue] = [:],
        extensions: [String: MetadataTagValue] = [:],
        diagnostics: ParserDiagnostics
    ) {
        self.format = format
        self.coreInfo = coreInfo
        self.tags = tags
        self.extensions = extensions
        self.diagnostics = diagnostics
    }

    public var coverArtCandidates: [BinaryDigest] {
        var results: [BinaryDigest] = []

        let preferredKeys = ["APIC", "PICTURE", "covr", "Cover Art (Front)", "METADATA_BLOCK_PICTURE"]
        for key in preferredKeys {
            if let tag = tags[key], case let .binary(value) = tag {
                results.append(value)
            }
        }

        if results.isEmpty {
            for (_, value) in tags {
                if case let .binary(binary) = value {
                    results.append(binary)
                }
            }
        }

        return results
    }

    public var primaryCoverArt: BinaryDigest? {
        coverArtCandidates.first
    }
}
