import Foundation

struct FormatProbe {
    struct Candidate {
        let format: AudioFormat
        let score: Int
    }

    static func probe(header: Data, fileHint: String?) -> [Candidate] {
        let ext = (fileHint as NSString?)?.pathExtension.lowercased() ?? ""
        var scores: [AudioFormat: Int] = [:]

        func bump(_ format: AudioFormat, _ score: Int) {
            scores[format, default: 0] += score
        }

        if header.count >= 3, header.prefix(3) == Data([0x49, 0x44, 0x33]) { bump(.mp3, 80); bump(.id3, 60) }
        if header.count >= 4, header.prefix(4) == Data("fLaC".utf8) { bump(.flac, 100) }
        if header.count >= 12,
           String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "RIFF",
           String(decoding: header[8..<12], as: Unicode.ASCII.self) == "WAVE" {
            bump(.wave, 100)
        }
        if header.count >= 12,
           String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "FORM",
           String(decoding: header[8..<12], as: Unicode.ASCII.self) == "AIFF" ||
           String(decoding: header[8..<12], as: Unicode.ASCII.self) == "AIFC" {
            bump(.aiff, 100)
        }
        if header.count >= 8,
           String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "OggS" {
            bump(.ogg, 60)
        }
        if header.count >= 8,
           header[4] == 0x66, header[5] == 0x74, header[6] == 0x79, header[7] == 0x70 {
            bump(.mp4, 95)
            bump(.m4a, 95)
        }

        if header.count >= 16 {
            let asfMagic = Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C])
            if header.prefix(16) == asfMagic { bump(.asf, 100) }
        }

        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "wvpk" { bump(.wavpack, 100) }
        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "MPCK" { bump(.musepack, 100) }
        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "MAC " { bump(.monkeysAudio, 100) }
        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "TTA1" { bump(.trueAudio, 100) }
        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "DSD " { bump(.dsf, 100) }
        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "FRM8" { bump(.dsdiff, 100) }
        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "MThd" { bump(.smf, 100) }
        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "OFR " { bump(.optimFrog, 100) }
        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "tBaK" { bump(.tak, 100) }
        if header.count >= 4 && String(decoding: header.prefix(4), as: Unicode.ASCII.self) == "APET" { bump(.apev2, 90) }

        if header.count >= 4 && header[0] == 0xFF && (header[1] & 0xF0) == 0xF0 {
            bump(.aac, 65)
            bump(.mp3, 30)
        }
        if header.count >= 4 && header[0] == 0x0B && header[1] == 0x77 {
            bump(.ac3, 100)
            bump(.eac3, 100)
        }

        for format in AudioFormat.allCases where format.fileExtensions.contains(ext) {
            bump(format, 25)
        }

        return scores.map { Candidate(format: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.format.rawValue < rhs.format.rawValue
                }
                return lhs.score > rhs.score
            }
    }
}
