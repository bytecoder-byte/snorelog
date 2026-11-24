import Foundation

// Pure logic with no Apple-framework dependencies, so it is easy to unit test.

/// One classifier window: how confident the model is that this slice of audio is snoring.
struct ClassifiedWindow: Equatable {
    /// Seconds from the start of the night's recording.
    var start: TimeInterval
    var duration: TimeInterval
    var snoreConfidence: Double

    var end: TimeInterval { start + duration }
}

/// A run of snoring: individual snores close together are merged into one episode.
struct DetectedEpisode: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var maxConfidence: Double

    var duration: TimeInterval { end - start }
}

enum Sensitivity: String, CaseIterable, Identifiable, Codable {
    case low, medium, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var detail: String {
        switch self {
        case .low: "Only clear, confident snores. Fewer false alarms."
        case .medium: "A balance that suits most bedrooms."
        case .high: "Catches soft snoring, but may pick up other noises."
        }
    }

    /// Minimum "snoring" confidence from the classifier to count a window.
    /// These are starting guesses and should be tuned with real recordings.
    var threshold: Double {
        switch self {
        case .low: 0.7
        case .medium: 0.5
        case .high: 0.3
        }
    }
}

enum SnoreIntensity: Int, Codable, CaseIterable, Comparable {
    case quiet = 1
    case loud = 2
    case epic = 3

    var title: String {
        switch self {
        case .quiet: "Quiet"
        case .loud: "Loud"
        case .epic: "Very loud"
        }
    }

    static func < (lhs: SnoreIntensity, rhs: SnoreIntensity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Intensity from how far the snore's peak rises above the room's background noise.
    static func from(peakDB: Float, noiseFloorDB: Float) -> SnoreIntensity {
        let rise = peakDB - noiseFloorDB
        if rise >= 25 { return .epic }
        if rise >= 12 { return .loud }
        return .quiet
    }
}

struct EpisodeBuilder {
    var threshold: Double = Sensitivity.medium.threshold
    /// Snores separated by up to this many seconds belong to the same episode
    /// (a typical breath cycle is 3 to 6 seconds).
    var maxGap: TimeInterval = 8
    /// Episodes shorter than this are treated as noise.
    var minDuration: TimeInterval = 2

    func episodes(from windows: [ClassifiedWindow]) -> [DetectedEpisode] {
        let hits = windows
            .filter { $0.snoreConfidence >= threshold }
            .sorted { $0.start < $1.start }

        var result: [DetectedEpisode] = []
        for window in hits {
            if var last = result.last, window.start - last.end <= maxGap {
                last.end = max(last.end, window.end)
                last.maxConfidence = max(last.maxConfidence, window.snoreConfidence)
                result[result.count - 1] = last
            } else {
                result.append(DetectedEpisode(start: window.start, end: window.end, maxConfidence: window.snoreConfidence))
            }
        }
        return result.filter { $0.duration >= minDuration }
    }
}

enum NightScoring {
    /// Background noise level: the 10th percentile of the per-second levels.
    static func noiseFloor(_ levels: [Float]) -> Float {
        guard !levels.isEmpty else { return -60 }
        let sorted = levels.sorted()
        let index = Int(Double(sorted.count - 1) * 0.1)
        return sorted[index]
    }

    /// Loudest per-second level within [start, end) seconds.
    static func peak(_ levels: [Float], from start: TimeInterval, to end: TimeInterval) -> Float {
        guard !levels.isEmpty else { return -80 }
        let lower = max(0, min(levels.count - 1, Int(start.rounded(.down))))
        let upper = max(lower, min(levels.count - 1, Int(end.rounded(.up)) - 1))
        return levels[lower...upper].max() ?? -80
    }

    /// Averages consecutive values in groups of `size` (for example per-second to per-minute).
    static func downsample(_ levels: [Float], by size: Int) -> [Float] {
        guard size > 0, !levels.isEmpty else { return [] }
        return stride(from: 0, to: levels.count, by: size).map { start in
            let chunk = levels[start..<min(start + size, levels.count)]
            return chunk.reduce(0, +) / Float(chunk.count)
        }
    }

    /// Snore score from 0 to 100: share of the night spent snoring, weighted by loudness.
    /// 100 would mean very loud snoring for the whole night. This formula is a first guess.
    static func score(episodes: [(duration: TimeInterval, intensity: SnoreIntensity)], recordedSeconds: TimeInterval) -> Int {
        guard recordedSeconds > 0 else { return 0 }
        let weighted = episodes.reduce(0.0) { $0 + $1.duration * Double($1.intensity.rawValue) }
        let maxWeighted = recordedSeconds * Double(SnoreIntensity.epic.rawValue)
        return min(100, Int((weighted / maxWeighted * 100).rounded()))
    }
}

/// Compares nights with and without a factor (for example "Alcohol" or "Nasal strip").
struct FactorImpact: Identifiable, Equatable {
    var factor: String
    var nightsWith: Int
    var averageWith: Double
    var averageWithout: Double?

    var id: String { factor }
    /// Positive means nights with this factor had a higher (worse) score.
    var difference: Double? { averageWithout.map { averageWith - $0 } }

    static func compute(nights: [(factors: [String], score: Int)]) -> [FactorImpact] {
        let allFactors = Set(nights.flatMap(\.factors))
        return allFactors.map { factor in
            let with = nights.filter { $0.factors.contains(factor) }.map { Double($0.score) }
            let without = nights.filter { !$0.factors.contains(factor) }.map { Double($0.score) }
            return FactorImpact(
                factor: factor,
                nightsWith: with.count,
                averageWith: with.reduce(0, +) / Double(with.count),
                averageWithout: without.isEmpty ? nil : without.reduce(0, +) / Double(without.count)
            )
        }
        .sorted { abs($0.difference ?? 0) > abs($1.difference ?? 0) }
    }
}

enum Formatters {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}
