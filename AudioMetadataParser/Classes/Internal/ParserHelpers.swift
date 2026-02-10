import Foundation

enum ParserHelpers {
    static func bitrate(lengthSeconds: Double?, fileSizeBytes: Int64?) -> Int? {
        guard let lengthSeconds, lengthSeconds > 0, let fileSizeBytes, fileSizeBytes > 0 else {
            return nil
        }
        return Int((Double(fileSizeBytes) * 8.0) / lengthSeconds)
    }

    static func textTag(_ value: String?) -> MetadataTagValue? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return .text([trimmed])
    }

    static func extensionFormat(fileHint: String?) -> AudioFormat {
        guard let fileHint else { return .unknown }
        let ext = (fileHint as NSString).pathExtension.lowercased()
        for format in AudioFormat.allCases where format.fileExtensions.contains(ext) {
            return format
        }
        return .unknown
    }
}
