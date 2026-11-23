import AVFoundation
import Foundation
import SoundAnalysis

/// Runs Apple's on-device sound classifier over one audio file and collects
/// the "snoring" confidence for each window.
final class SnoreWindowCollector: NSObject, SNResultsObserving {
    private let offset: TimeInterval
    private(set) var windows: [ClassifiedWindow] = []
    private(set) var failure: Error?

    init(offset: TimeInterval) {
        self.offset = offset
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = result.classification(forIdentifier: "snoring")?.confidence ?? 0
        windows.append(ClassifiedWindow(
            start: offset + result.timeRange.start.seconds,
            duration: result.timeRange.duration.seconds,
            snoreConfidence: confidence
        ))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        failure = error
    }

    func requestDidComplete(_ request: SNRequest) {}
}

enum SegmentClassifier {
    static func classify(url: URL, offset: TimeInterval) throws -> [ClassifiedWindow] {
        let analyzer = try SNAudioFileAnalyzer(url: url)
        // The built-in classifier recognizes about 300 sounds, including "snoring".
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.overlapFactor = 0.5
        let collector = SnoreWindowCollector(offset: offset)
        try analyzer.add(request, withObserver: collector)
        analyzer.analyze() // Synchronous. Runs entirely on device.
        if let failure = collector.failure { throw failure }
        return collector.windows
    }
}

enum ClipExporter {
    /// Copies `duration` seconds starting at `start` (seconds within the file) into a new file.
    static func export(from source: URL, start: TimeInterval, duration: TimeInterval, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let sampleRate = format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, start) * sampleRate)
        guard startFrame < input.length else { return }
        let frameCount = AVAudioFrameCount(min(Double(input.length - startFrame), duration * sampleRate))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        input.framePosition = startFrame
        try input.read(into: buffer, frameCount: frameCount)

        let output = try AVAudioFile(
            forWriting: destination,
            settings: RecordingFormat.fileSettings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try output.write(from: buffer)
    }
}

struct AnalyzedEpisode {
    var offset: TimeInterval
    var duration: TimeInterval
    var confidence: Double
    var peakDB: Float
    var intensity: SnoreIntensity
    var clipFileName: String?
}

struct NightAnalysisResult {
    var recordedSeconds: TimeInterval
    var snoringSeconds: TimeInterval
    var score: Int
    var noiseFloorDB: Float
    var loudestDB: Float
    var minuteLevels: [Float]
    var episodes: [AnalyzedEpisode]
}

enum AnalysisError: LocalizedError {
    case noRecording
    case unreadableAudio

    var errorDescription: String? {
        switch self {
        case .noRecording: "No audio was recorded for this night."
        case .unreadableAudio: "The night's audio couldn't be read."
        }
    }
}

struct NightAnalyzer {
    var folder: URL
    var sensitivity: Sensitivity
    var keepFullRecordings: Bool
    /// Keep audio clips for at most this many episodes (the longest and loudest).
    var maxClips = 30
    /// Clip length cap, with a little lead-in before each episode.
    var maxClipSeconds: TimeInterval = 20
    var clipLeadIn: TimeInterval = 1

    func run(progress: @escaping @MainActor (Double) -> Void) async throws -> NightAnalysisResult {
        guard let manifest = try? RecordingManifest.load(from: folder), !manifest.segments.isEmpty else {
            throw AnalysisError.noRecording
        }

        let builder = EpisodeBuilder(threshold: sensitivity.threshold)
        var found: [(episode: DetectedEpisode, segment: RecordingManifest.Segment)] = []
        var readableSegments = 0

        for (index, segment) in manifest.segments.enumerated() {
            let url = folder.appendingPathComponent(segment.fileName)
            // The last file can be unreadable if the app was killed mid-night. Skip it.
            if let windows = try? SegmentClassifier.classify(url: url, offset: segment.startOffset) {
                readableSegments += 1
                // Episodes are built per file so a clip never spans two files.
                found += builder.episodes(from: windows).map { ($0, segment) }
            }
            await progress(Double(index + 1) / Double(manifest.segments.count) * 0.85)
        }
        guard readableSegments > 0 else { throw AnalysisError.unreadableAudio }

        let levels = manifest.levels
        let noiseFloor = NightScoring.noiseFloor(levels)
        var episodes = found.map { item -> (AnalyzedEpisode, RecordingManifest.Segment) in
            let peak = NightScoring.peak(levels, from: item.episode.start, to: item.episode.end)
            let episode = AnalyzedEpisode(
                offset: item.episode.start,
                duration: item.episode.duration,
                confidence: item.episode.maxConfidence,
                peakDB: peak,
                intensity: SnoreIntensity.from(peakDB: peak, noiseFloorDB: noiseFloor),
                clipFileName: nil
            )
            return (episode, item.segment)
        }

        // Keep clips for the most notable episodes.
        let ranked = episodes.indices.sorted {
            let a = episodes[$0].0, b = episodes[$1].0
            return a.duration * Double(a.intensity.rawValue) > b.duration * Double(b.intensity.rawValue)
        }
        for (n, index) in ranked.prefix(maxClips).enumerated() {
            let (episode, segment) = episodes[index]
            let name = "clip-\(Int(episode.offset)).m4a"
            let start = episode.offset - segment.startOffset - clipLeadIn
            let length = min(maxClipSeconds, episode.duration + clipLeadIn * 2)
            do {
                try ClipExporter.export(
                    from: folder.appendingPathComponent(segment.fileName),
                    start: start,
                    duration: length,
                    to: folder.appendingPathComponent(name)
                )
                episodes[index].0.clipFileName = name
            } catch {
                // A missing clip is not fatal. The episode still counts.
            }
            await progress(0.85 + Double(n + 1) / Double(max(1, min(maxClips, ranked.count))) * 0.15)
        }

        if !keepFullRecordings {
            for segment in manifest.segments {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(segment.fileName))
            }
        }

        let final = episodes.map(\.0)
        let recordedSeconds = TimeInterval(levels.count)
        let snoringSeconds = final.reduce(0) { $0 + $1.duration }
        return NightAnalysisResult(
            recordedSeconds: recordedSeconds,
            snoringSeconds: snoringSeconds,
            score: NightScoring.score(episodes: final.map { (duration: $0.duration, intensity: $0.intensity) }, recordedSeconds: recordedSeconds),
            noiseFloorDB: noiseFloor,
            loudestDB: final.map(\.peakDB).max() ?? noiseFloor,
            minuteLevels: NightScoring.downsample(levels, by: 60),
            episodes: final
        )
    }
}
