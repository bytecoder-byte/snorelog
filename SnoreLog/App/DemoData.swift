import Foundation
import SwiftData

/// Sample nights for screenshots and for trying the app in the simulator, which has no
/// real night to record. Enabled with the launch argument `-demoData`.
/// `-screen report|compare|history|settings|tonight|paywall|pdf` opens a specific screen.
/// `-proUnlocked` turns SnoreLog Pro on without buying it.
enum DemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-demoData") }

    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-screen"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        guard isEnabled else { return }
        let existing = (try? context.fetchCount(FetchDescriptor<SleepSession>())) ?? 0
        guard existing == 0 else { return }

        var generator = SeededGenerator(seed: 42)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        for daysAgo in (1...14).reversed() {
            var bedtime = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
                .addingTimeInterval(23 * 3600 + Double.random(in: -1800...1800, using: &generator))
            if daysAgo == 1 { bedtime = calendar.date(byAdding: .day, value: -1, to: today)!.addingTimeInterval(23.75 * 3600) }
            if daysAgo == 2 { bedtime = calendar.date(byAdding: .day, value: -2, to: today)!.addingTimeInterval(22.75 * 3600) }
            let hours = Double.random(in: 6.5...8.2, using: &generator)
            let recorded = hours * 3600
            var factors: [String] = []
            if daysAgo % 5 == 0 { factors.append("Alcohol") }
            if daysAgo % 3 == 0 { factors.append("Nasal strip") }
            if daysAgo % 4 == 0 { factors.append("Slept on back") }
            // The last two nights differ, so the report's "compared with the night before" has something to show.
            if daysAgo == 2 { factors = ["Nasal strip", "Side sleeping"] }
            if daysAgo == 1 { factors = ["Alcohol", "Late meal", "Slept on back"] }
            let alcohol = factors.contains("Alcohol")
            let strip = factors.contains("Nasal strip")

            let night = SleepSession(startDate: bedtime, factors: factors)
            night.endDate = bedtime.addingTimeInterval(recorded)
            night.recordedSeconds = recorded
            night.noiseFloorDB = -58

            // Background room noise per minute, plus snoring bursts.
            let minutes = Int(recorded / 60)
            var levels = (0..<minutes).map { _ in Float(-58 + Double.random(in: -2...2, using: &generator)) }
            var episodes: [(TimeInterval, TimeInterval, SnoreIntensity)] = []
            let count = Int.random(in: 6...14, using: &generator) + (alcohol ? 10 : 0) - (strip ? 4 : 0) + (factors.contains("Slept on back") ? 3 : 0)
            for _ in 0..<max(2, count) {
                let start = Double.random(in: 900...(recorded - 900), using: &generator)
                let duration = Double.random(in: 30...(alcohol ? 900 : 420), using: &generator)
                let intensity: SnoreIntensity = alcohol
                    ? [.loud, .epic, .epic].randomElement(using: &generator)!
                    : [.quiet, .quiet, .loud].randomElement(using: &generator)!
                episodes.append((start, duration, intensity))
                let rise: Float = intensity == .epic ? 28 : intensity == .loud ? 16 : 8
                for minute in Int(start / 60)...min(minutes - 1, Int((start + duration) / 60)) {
                    levels[minute] = max(levels[minute], -58 + rise + Float(Double.random(in: -3...3, using: &generator)))
                }
            }
            night.minuteLevels = levels
            night.episodes = episodes.map { start, duration, intensity in
                let rise: Float = intensity == .epic ? 28 : intensity == .loud ? 16 : 8
                return SnoreEpisode(offset: start, duration: duration, confidence: 0.8, peakDB: -58 + rise, intensity: intensity, clipFileName: nil)
            }
            night.snoringSeconds = episodes.reduce(0) { $0 + $1.1 }
            night.score = NightScoring.score(episodes: episodes.map { (duration: $0.1, intensity: $0.2) }, recordedSeconds: recorded)
            night.loudestDB = night.episodes.map(\.peakDB).max() ?? -58
            night.status = .done
            context.insert(night)
        }
        try? context.save()
    }
}

/// Small deterministic random generator so demo data looks the same every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
