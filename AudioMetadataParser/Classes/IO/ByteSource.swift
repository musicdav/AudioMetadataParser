import Foundation

protocol ByteSource: Sendable {
    var length: Int64? { get }
    var nameHint: String? { get }
    func read(at offset: Int64, length: Int) throws -> Data
}

final class FileByteSource: ByteSource {
    let length: Int64?
    let nameHint: String?

    private let fileHandle: FileHandle

    init(url: URL) throws {
        do {
            self.fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AudioMetadataError(code: .ioFailure, message: "failed to open file", context: ["path": url.path])
        }

        self.nameHint = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? NSNumber {
            self.length = size.int64Value
        } else {
            self.length = nil
        }
    }

    func read(at offset: Int64, length: Int) throws -> Data {
        if length <= 0 {
            return Data()
        }
        do {
            try fileHandle.seek(toOffset: UInt64(max(0, offset)))
            return try fileHandle.read(upToCount: length) ?? Data()
        } catch {
            throw AudioMetadataError(
                code: .ioFailure,
                message: "failed to read file",
                offset: offset,
                context: ["length": String(length)]
            )
        }
    }

    deinit {
        try? fileHandle.close()
    }
}

struct DataByteSource: ByteSource {
    let payload: Data
    let nameHint: String?

    init(data: Data, fileHint: String? = nil) {
        self.payload = data
        self.nameHint = fileHint
    }

    var length: Int64? {
        Int64(payload.count)
    }

    func read(at offset: Int64, length: Int) throws -> Data {
        guard offset >= 0 else {
            throw AudioMetadataError(code: .ioFailure, message: "negative offset", offset: offset)
        }
        if length <= 0 || offset >= Int64(payload.count) {
            return Data()
        }
        let lower = Int(offset)
        let upper = min(payload.count, lower + length)
        return payload.subdata(in: lower ..< upper)
    }
}

struct StreamByteSource: ByteSource {
    let nameHint: String?
    private let payload: Data

    init(stream: InputStream, fileHint: String?) throws {
        self.nameHint = fileHint
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            if count < 0 {
                throw AudioMetadataError(
                    code: .ioFailure,
                    message: "failed to read stream",
                    context: ["reason": stream.streamError?.localizedDescription ?? "unknown"]
                )
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        self.payload = data
    }

    var length: Int64? {
        Int64(payload.count)
    }

    func read(at offset: Int64, length: Int) throws -> Data {
        try DataByteSource(data: payload, fileHint: nameHint).read(at: offset, length: length)
    }
}
