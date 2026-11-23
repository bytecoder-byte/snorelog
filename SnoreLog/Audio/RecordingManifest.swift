import AVFoundation
import Foundation

/// Written into each night's folder while recording, so a night can still be analyzed
/// if the app is closed or crashes before the person taps Stop.
struct RecordingManifest: Codable {
    struct Segment: Codable, Equatable {
        var fileName: String
        /// Seconds from the start of the night's recording timeline.
        var startOffset: TimeInterval
    }

    var segments: [Segment] = []
    /// Loudest 100 ms level within each second, in dBFS. One entry per recorded second.
    var levels: [Float] = []

    static let fileName = "manifest.json"

    static func load(from folder: URL) throws -> RecordingManifest {
        let data = try Data(contentsOf: folder.appendingPathComponent(fileName))
        return try JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    func save(to folder: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

enum RecordingFormat {
    /// 16 kHz mono is plenty for snoring and keeps a full night to a few tens of MB of AAC.
    static let sampleRate: Double = 16_000

    static let processing = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    /// Length of each audio file. Short files limit what is lost if the app is killed mid-night.
    static let segmentSeconds: TimeInterval = 600
}
