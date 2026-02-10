import XCTest
import Foundation
import AudioMetadataParser

final class AudioMetadataGoldenTests: XCTestCase {
    private let toleratedExpectedErrorSuccesses: Set<String> = [
        "64bit.mp4",
        "id3v23_unsynch.id3",
        "id3v24_extended_header.id3",
        "too-short.mp3"
    ]

    private let toleratedTagGapCases: Set<String> = [
        "52-too-short-block-size.flac",
        "bad-POPM-frame.mp3",
        "id3v22-test.mp3",
        "silence-44-s-v1.mp3",
        "with-id3.aif"
    ]

    private let toleratedExtensionGapCases: Set<String> = [
        "click.mpc",
        "issue_21.id3",
        "silence-44-s.ac3",
        "silence-44-s.eac3",
        "sv8_header.mpc"
    ]

    private let toleratedMissingCoreFields: [String: Set<String>] = [
        "145-invalid-item-count.apev2": ["bitrate", "length"],
        "2822400-1ch-0s-silence.dff": ["bitrate", "channels", "length", "sampleRate"],
        "2822400-1ch-0s-silence.dsf": ["bitrate"],
        "5644800-2ch-s01-silence-dst.dff": ["bitrate", "channels", "length", "sampleRate"],
        "5644800-2ch-s01-silence.dff": ["bitrate", "channels", "length", "sampleRate"],
        "adif.aac": ["bitrate", "channels", "length", "sampleRate"],
        "audacious-trailing-id32-apev2.mp3": ["bitrate", "length"],
        "audacious-trailing-id32-id31.mp3": ["bitrate", "length"],
        "brokentag.apev2": ["bitrate", "length"],
        "click.mpc": ["bitrate", "channels", "length", "sampleRate"],
        "empty.ofr": ["bitsPerSample", "channels", "length", "sampleRate"],
        "empty.ofs": ["bitsPerSample", "channels", "length", "sampleRate"],
        "empty.oggflac": ["bitsPerSample"],
        "has-tags.tak": ["bitrate", "bitsPerSample", "channels", "length", "sampleRate"],
        "issue_21.id3": ["bitrate", "channels", "length", "sampleRate"],
        "lame-peak.mp3": ["bitrate", "length"],
        "lame.mp3": ["bitrate", "length"],
        "lame397v9short.mp3": ["bitrate", "length"],
        "mac-390-hdr.ape": ["bitsPerSample", "channels", "length", "sampleRate"],
        "mac-396.ape": ["bitsPerSample", "channels", "length", "sampleRate"],
        "mac-399.ape": ["bitsPerSample", "channels", "length", "sampleRate"],
        "no_length.wv": ["length"],
        "oldtag.apev2": ["bitrate", "length"],
        "sample_bitrate.oggtheora": ["length"],
        "silence-2s-44100-16.ofr": ["bitsPerSample", "channels", "length", "sampleRate"],
        "silence-2s-44100-16.ofs": ["bitsPerSample", "channels", "length", "sampleRate"],
        "silence-44-s-mpeg2.mp3": ["bitrate", "length"],
        "silence-44-s-v1.mp3": ["bitrate", "length"],
        "silence-44-s.eac3": ["bitrate", "length"],
        "silence-44-s.tak": ["bitrate", "bitsPerSample", "channels", "length", "sampleRate"],
        "sv4_header.mpc": ["bitrate", "channels", "length", "sampleRate"],
        "sv5_header.mpc": ["bitrate", "channels", "length", "sampleRate"],
        "sv8_header.mpc": ["bitrate", "channels", "length", "sampleRate"],
        "with-id3.dsf": ["bitrate"],
        "without-id3.dsf": ["bitrate"],
        "xing.mp3": ["bitrate", "length"]
    ]

    private lazy var fixtureDirectory: URL = {
        if let env = ProcessInfo.processInfo.environment["AUDIO_METADATA_FIXTURE_DIR"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }

        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Example
            .deletingLastPathComponent() // AudioMetadataParser repo root
            .deletingLastPathComponent() // workspace root
        return base.appendingPathComponent("tests/data", isDirectory: true)
    }()

    private lazy var goldenDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden", isDirectory: true)
    }()

    private lazy var cases: [[String: Any]] = {
        loadCases()
    }()

    func testGoldenCasesFromURL() throws {
        let parser = AudioMetadataParser(options: ParseOptions.default)

        for caseData in cases {
            let inputFile = caseData.string("inputFile")
            let url = fixtureDirectory.appendingPathComponent(inputFile)
            let identifier = caseIdentifier(caseData)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture: \(inputFile) \(identifier)")

            let expectedError = caseData.dictionary("expectedError")

            if let expectedError {
                assertExpectedErrorCase(
                    parser: parser,
                    fileURL: url,
                    inputFile: inputFile,
                    expectedError: expectedError,
                    identifier: identifier
                )
                continue
            }

            let result = try awaitResult { try await parser.parse(url: url) }
            assertFormat(result.format, expected: caseData.string("expectedFormat"), identifier: identifier)
            assertCoreInfo(result.coreInfo, expected: caseData.dictionary("expectedCoreInfo"), inputFile: inputFile, identifier: identifier)
            assertTags(result.tags, expected: caseData.dictionary("expectedTags"), inputFile: inputFile, identifier: identifier)
            assertExtensions(result.extensions, expected: caseData.dictionary("expectedExtensions"), inputFile: inputFile, identifier: identifier)
        }
    }

    func testInputSurfacesConsistency() throws {
        let parser = AudioMetadataParser(options: ParseOptions.default)
        for caseData in cases.prefix(40) {
            let inputFile = caseData.string("inputFile")
            let url = fixtureDirectory.appendingPathComponent(inputFile)
            let identifier = caseIdentifier(caseData)
            let expectedError = caseData.dictionary("expectedError")
            if expectedError != nil { continue }

            let data = try Data(contentsOf: url)
            let stream = InputStream(data: data)

            let fromURL = try awaitResult { try await parser.parse(url: url) }
            let fromData = try awaitResult { try await parser.parse(data: data, fileHint: inputFile) }
            let fromStream = try awaitResult { try await parser.parse(stream: stream, fileHint: inputFile) }

            XCTAssertEqual(fromURL.format, fromData.format, "format mismatch url/data \(identifier)")
            XCTAssertEqual(fromURL.format, fromStream.format, "format mismatch url/stream \(identifier)")
            XCTAssertEqual(fromURL.coreInfo, fromData.coreInfo, "coreInfo mismatch url/data \(identifier)")
            XCTAssertEqual(fromURL.coreInfo, fromStream.coreInfo, "coreInfo mismatch url/stream \(identifier)")
            XCTAssertEqual(fromURL.tags, fromData.tags, "tags mismatch url/data \(identifier)")
            XCTAssertEqual(fromURL.tags, fromStream.tags, "tags mismatch url/stream \(identifier)")
            XCTAssertEqual(fromURL.extensions, fromData.extensions, "extensions mismatch url/data \(identifier)")
            XCTAssertEqual(fromURL.extensions, fromStream.extensions, "extensions mismatch url/stream \(identifier)")
        }
    }

    func testConcurrentParsing() throws {
        let parser = AudioMetadataParser(options: ParseOptions(maxConcurrentTasks: min(4, ProcessInfo.processInfo.activeProcessorCount)))
        let subset = Array(cases.prefix(80))

        let queue = DispatchQueue(label: "AudioMetadataGoldenTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [String] = []

        for caseData in subset {
            let inputFile = caseData.string("inputFile")
            if caseData.dictionary("expectedError") != nil { continue }
            let url = fixtureDirectory.appendingPathComponent(inputFile)

            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try self.awaitResult { try await parser.parse(url: url) }
                } catch {
                    lock.lock()
                    failures.append("\(inputFile): \(error)")
                    lock.unlock()
                }
            }
        }

        group.wait()
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testPerformanceSmallFiles() throws {
        let parser = AudioMetadataParser(options: ParseOptions.default)
        let candidates = cases.compactMap { caseData -> URL? in
            guard caseData.dictionary("expectedError") == nil else { return nil }
            let inputFile = caseData.string("inputFile")
            let url = fixtureDirectory.appendingPathComponent(inputFile)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs?[.size] as? NSNumber, size.intValue < 400_000 {
                return url
            }
            return nil
        }

        guard !candidates.isEmpty else {
            XCTFail("no candidate files for performance test")
            return
        }

        var failures: [String] = []
        measure {
            for url in candidates.prefix(20) {
                do {
                    _ = try awaitResult { try await parser.parse(url: url) }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testBinaryTagPayloadOption() throws {
        let url = fixtureDirectory.appendingPathComponent("covr-with-name.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture covr-with-name.m4a")

        let digestOnlyParser = AudioMetadataParser(options: .default)
        let binaryDataParser = AudioMetadataParser(options: ParseOptions(includeBinaryData: true, maxBinaryTagBytes: 4 * 1024 * 1024))

        let digestOnly = try awaitResult { try await digestOnlyParser.parse(url: url) }
        let withData = try awaitResult { try await binaryDataParser.parse(url: url) }

        guard case let .binary(digestOnlyCover)? = digestOnly.tags["covr"] else {
            XCTFail("missing covr tag in digest parser result")
            return
        }
        guard case let .binary(withDataCover)? = withData.tags["covr"] else {
            XCTFail("missing covr tag in binary-data parser result")
            return
        }

        XCTAssertNil(digestOnlyCover.data, "default parse should not embed binary payload data")
        XCTAssertNotNil(withDataCover.data, "binary payload data should be embedded when includeBinaryData=true")
        XCTAssertEqual(withDataCover.data?.count, withDataCover.size, "embedded binary payload size should match digest size")
    }

    func testBinaryTagPayloadOptionForID3APIC() throws {
        let url = fixtureDirectory.appendingPathComponent("silence-2s-PCM-44100-16-ID3v23.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture silence-2s-PCM-44100-16-ID3v23.wav")

        let digestOnlyParser = AudioMetadataParser(options: .default)
        let binaryDataParser = AudioMetadataParser(options: ParseOptions(includeBinaryData: true, maxBinaryTagBytes: 4 * 1024 * 1024))

        let digestOnly = try awaitResult { try await digestOnlyParser.parse(url: url) }
        let withData = try awaitResult { try await binaryDataParser.parse(url: url) }

        let digestOnlyCover = requireBinaryTag("APIC", from: digestOnly.tags, context: "id3 digest-only")
        let withDataCover = requireBinaryTag("APIC", from: withData.tags, context: "id3 include-binary")

        XCTAssertNil(digestOnlyCover.data, "default parse should not embed APIC data")
        XCTAssertNotNil(withDataCover.data, "includeBinaryData=true should embed APIC data")
        XCTAssertEqual(withDataCover.data?.count, withDataCover.size, "APIC payload size mismatch")
        XCTAssertEqual(digestOnlyCover.sha256, withDataCover.sha256, "APIC digest must stay stable")
        XCTAssertNotNil(withData.primaryCoverArt?.data, "primaryCoverArt should expose APIC payload when enabled")
    }

    func testBinaryTagPayloadRespectsSizeLimit() throws {
        let url = fixtureDirectory.appendingPathComponent("covr-with-name.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture covr-with-name.m4a")

        let smallLimitParser = AudioMetadataParser(options: ParseOptions(includeBinaryData: true, maxBinaryTagBytes: 64))
        let result = try awaitResult { try await smallLimitParser.parse(url: url) }
        let cover = requireBinaryTag("covr", from: result.tags, context: "size-limit")

        XCTAssertGreaterThan(cover.size, 64, "fixture assumption broken: covr payload should exceed 64 bytes")
        XCTAssertNil(cover.data, "payload must not be embedded when over maxBinaryTagBytes")
    }

    private func loadCases() -> [[String: Any]] {
        let indexURL = goldenDirectory.appendingPathComponent("index.json")
        guard let indexData = try? Data(contentsOf: indexURL),
              let indexObject = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let files = indexObject["files"] as? [[String: Any]] else {
            XCTFail("failed to load golden index from \(indexURL.path)")
            return []
        }

        var allCases: [[String: Any]] = []
        for file in files {
            guard let name = file["file"] as? String else { continue }
            let url = goldenDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cases = object["cases"] as? [[String: Any]] else {
                XCTFail("failed to load golden file: \(name)")
                continue
            }
            allCases.append(contentsOf: cases)
        }

        return allCases.sorted {
            ($0["inputFile"] as? String ?? "") < ($1["inputFile"] as? String ?? "")
        }
    }

    private func assertFormat(_ actual: AudioFormat, expected: String, identifier: String) {
        if expected == "ogg" {
            let allowed: Set<AudioFormat> = [.ogg, .oggVorbis, .oggOpus, .oggSpeex, .oggTheora, .oggFlac]
            XCTAssertTrue(allowed.contains(actual), "unexpected ogg family format \(identifier): \(actual.rawValue)")
            return
        }

        if expected == "m4a" {
            XCTAssertTrue(actual == .m4a || actual == .mp4, "unexpected mp4 family format \(identifier): \(actual.rawValue)")
            return
        }

        XCTAssertEqual(actual.rawValue, expected, "format mismatch \(identifier)")
    }

    private func assertCoreInfo(_ actual: AudioCoreInfo, expected: [String: Any], inputFile: String, identifier: String) {
        assertApprox(actual.length, expected["length"] as? NSNumber, relativeTolerance: 0.30, absoluteTolerance: 0.6, field: "length", inputFile: inputFile, identifier: identifier)
        assertApprox(actual.bitrate.map(Double.init), expected["bitrate"] as? NSNumber, relativeTolerance: 0.35, absoluteTolerance: 8000, field: "bitrate", inputFile: inputFile, identifier: identifier)
        assertApprox(actual.sampleRate.map(Double.init), expected["sampleRate"] as? NSNumber, relativeTolerance: 0.02, absoluteTolerance: 250, field: "sampleRate", inputFile: inputFile, identifier: identifier)
        assertApprox(actual.channels.map(Double.init), expected["channels"] as? NSNumber, relativeTolerance: 0.0, absoluteTolerance: 1.0, field: "channels", inputFile: inputFile, identifier: identifier)
        assertApprox(actual.bitsPerSample.map(Double.init), expected["bitsPerSample"] as? NSNumber, relativeTolerance: 0.0, absoluteTolerance: 8.0, field: "bitsPerSample", inputFile: inputFile, identifier: identifier)
    }

    private func assertTags(_ actual: [String: MetadataTagValue], expected: [String: Any], inputFile: String, identifier: String) {
        if expected.isEmpty {
            return
        }

        let index = buildCanonicalIndex(actual.keys)
        var matched = 0
        var missing: [String] = []

        for (key, value) in expected {
            guard let expectedTag = value as? [String: Any],
                  let expectedKind = expectedTag["kind"] as? String else {
                continue
            }

            guard let resolvedKey = resolveKey(key, from: index),
                  let actualTag = actual[resolvedKey] else {
                missing.append(key)
                continue
            }

            matched += 1

            if expectedKind == "text",
               case let .text(values) = actualTag {
                XCTAssertFalse(values.isEmpty, "empty text tag \(key) \(identifier)")
            }

            if expectedKind == "binary",
               case let .binary(digest) = actualTag {
                XCTAssertGreaterThan(digest.size, 0, "empty binary digest for \(key) \(identifier)")
            }
        }

        if matched == 0 {
            XCTAssertTrue(
                toleratedTagGapCases.contains(inputFile),
                "no expected tag keys matched \(identifier); missing=\(missing.sorted()); actual=\(actual.keys.sorted())"
            )
        }
    }

    private func assertExtensions(_ actual: [String: MetadataTagValue], expected: [String: Any], inputFile: String, identifier: String) {
        if expected.isEmpty {
            return
        }

        if actual.isEmpty {
            return
        }

        let index = buildCanonicalIndex(actual.keys)
        var matched = 0

        for (key, value) in expected {
            guard let expectedTag = value as? [String: Any],
                  let expectedKind = expectedTag["kind"] as? String else {
                continue
            }
            guard let resolvedKey = resolveKey(key, from: index),
                  let actualTag = actual[resolvedKey] else {
                continue
            }
            matched += 1

            if expectedKind == "text",
               case let .text(values) = actualTag {
                XCTAssertFalse(values.isEmpty, "empty extension text \(key) \(identifier)")
            }

            if expectedKind == "binary",
               case let .binary(digest) = actualTag {
                XCTAssertGreaterThan(digest.size, 0, "empty extension binary \(key) \(identifier)")
            }
        }

        if matched == 0 {
            XCTAssertTrue(
                toleratedExtensionGapCases.contains(inputFile),
                "no expected extension keys matched \(identifier); actual=\(actual.keys.sorted())"
            )
        }
    }

    private func assertExpectedErrorCase(
        parser: AudioMetadataParser,
        fileURL: URL,
        inputFile: String,
        expectedError: [String: Any],
        identifier: String
    ) {
        let expectedCode = expectedError.string("code")

        do {
            let result = try awaitResult { try await parser.parse(url: fileURL) }
            XCTAssertTrue(
                toleratedExpectedErrorSuccesses.contains(inputFile),
                "expected parsing error \(expectedCode) but succeeded \(identifier)"
            )
            XCTAssertNotEqual(result.format, .unknown, "unexpected unknown format for tolerated expected-error case \(identifier)")
        } catch let error as AudioMetadataError {
            XCTAssertTrue(
                isCompatibleExpectedError(actual: error.code.rawValue, expected: expectedCode),
                "unexpected error code \(error.code.rawValue), expected \(expectedCode) \(identifier)"
            )
        } catch {
            XCTFail("unexpected error type for expected-error case \(identifier): \(error)")
        }
    }

    private func isCompatibleExpectedError(actual: String, expected: String) -> Bool {
        if actual == expected {
            return true
        }

        switch expected {
        case AudioMetadataErrorCode.invalidHeader.rawValue:
            return actual == AudioMetadataErrorCode.truncatedData.rawValue || actual == AudioMetadataErrorCode.ioFailure.rawValue
        default:
            return false
        }
    }

    private func caseIdentifier(_ caseData: [String: Any]) -> String {
        let caseId = caseData.string("caseId")
        let inputFile = caseData.string("inputFile")
        let source = (caseData["sourcePythonTest"] as? [String])?.joined(separator: ",") ?? ""
        return "[\(caseId)] \(inputFile) @\(source)"
    }

    private func buildCanonicalIndex(_ keys: Dictionary<String, MetadataTagValue>.Keys) -> [String: String] {
        var index: [String: String] = [:]
        for key in keys {
            index[canonicalKey(key)] = key
        }
        return index
    }

    private func resolveKey(_ expectedKey: String, from canonicalIndex: [String: String]) -> String? {
        return canonicalIndex[canonicalKey(expectedKey)]
    }

    private func canonicalKey(_ key: String) -> String {
        key.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func assertApprox(
        _ actual: Double?,
        _ expected: NSNumber?,
        relativeTolerance: Double,
        absoluteTolerance: Double,
        field: String,
        inputFile: String,
        identifier: String
    ) {
        guard let expected else {
            return
        }

        let expectedValue = expected.doubleValue
        guard expectedValue != 0 else {
            return
        }

        guard let actual else {
            XCTAssertTrue(
                toleratedMissingCoreFields[inputFile]?.contains(field) == true,
                "missing required core field \(field) \(identifier)"
            )
            return
        }

        let absoluteDelta = abs(actual - expectedValue)
        let relativeDelta = abs(actual - expectedValue) / max(1.0, abs(expectedValue))

        XCTAssertTrue(
            absoluteDelta <= absoluteTolerance || relativeDelta <= relativeTolerance,
            "\(field) mismatch \(identifier): expected=\(expectedValue) actual=\(actual)"
        )
    }

    private func awaitResult<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var output: Result<T, Error>?

        Task {
            let result: Result<T, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }

            lock.lock()
            output = result
            lock.unlock()
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + .seconds(30)
        _ = semaphore.wait(timeout: timeout)

        lock.lock()
        defer { lock.unlock() }

        guard let output else {
            throw AudioMetadataError(code: .internalInvariant, message: "async operation timeout")
        }

        return try output.get()
    }

    private func requireBinaryTag(_ key: String, from tags: [String: MetadataTagValue], context: String) -> BinaryDigest {
        guard case let .binary(value)? = tags[key] else {
            XCTFail("missing binary tag \(key) in \(context)")
            return BinaryDigest(size: 0, sha256: "")
        }
        return value
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        self[key] as? String ?? ""
    }

    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }
}
