import Foundation

public enum AudioFormat: String, CaseIterable, Sendable {
    case mp3
    case id3
    case flac
    case mp4
    case m4a
    case wave
    case aiff
    case asf
    case apev2
    case musepack
    case wavpack
    case tak
    case dsf
    case dsdiff
    case aac
    case ac3
    case eac3
    case ogg
    case oggVorbis
    case oggOpus
    case oggSpeex
    case oggTheora
    case oggFlac
    case trueAudio
    case optimFrog
    case smf
    case monkeysAudio
    case unknown

    public var fileExtensions: [String] {
        switch self {
        case .mp3: return ["mp3"]
        case .id3: return ["id3"]
        case .flac: return ["flac"]
        case .mp4: return ["mp4"]
        case .m4a: return ["m4a", "m4b", "m4p", "3g2"]
        case .wave: return ["wav", "wave"]
        case .aiff: return ["aif", "aiff", "aifc"]
        case .asf: return ["asf", "wma"]
        case .apev2: return ["apev2", "ape"]
        case .musepack: return ["mpc"]
        case .wavpack: return ["wv"]
        case .tak: return ["tak"]
        case .dsf: return ["dsf"]
        case .dsdiff: return ["dff", "dsdiff"]
        case .aac: return ["aac"]
        case .ac3: return ["ac3"]
        case .eac3: return ["eac3"]
        case .ogg: return ["ogg"]
        case .oggVorbis: return ["ogg", "oga"]
        case .oggOpus: return ["opus", "ogg"]
        case .oggSpeex: return ["spx", "ogg"]
        case .oggTheora: return ["oggtheora", "ogv"]
        case .oggFlac: return ["oggflac", "ogg"]
        case .trueAudio: return ["tta"]
        case .optimFrog: return ["ofr", "ofs"]
        case .smf: return ["mid", "smf"]
        case .monkeysAudio: return ["ape"]
        case .unknown: return []
        }
    }
}
