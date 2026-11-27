import Foundation
import SwiftData

/// Sample nights for screenshots and for trying the app in the simulator, which has no
/// real night to record. Enabled with the launch argument `-demoData`.
/// `-screen report|compare|day|night|history|settings|tonight|paywall|pdf|trends` opens a specific screen.
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
            var position: SleepPosition? = daysAgo % 4 == 0 ? .back : (daysAgo % 3 == 1 ? .side : .mixed)
            var nose: Int? = daysAgo % 6 == 0 ? 2 : (daysAgo % 7 == 0 ? 1 : 0)
            // The last two nights differ, so the report's "compared with the night before" has something to show.
            if daysAgo == 2 { factors = ["Nasal strip"]; position = .side; nose = 0 }
            if daysAgo == 1 { factors = ["Alcohol", DaytimeTag.drinksNearBed, "Late meal"]; position = .back; nose = 2 }
            if daysAgo == 3 { position = nil }
            let alcohol = factors.contains("Alcohol")
            let strip = factors.contains("Nasal strip")

            // What Apple Health would have for the day before.
            let workedOut = daysAgo % 2 == 0
            var day = DaytimeActivity(
                workoutMinutes: workedOut ? Double.random(in: 25...60, using: &generator).rounded() : nil,
                strengthMinutes: workedOut && daysAgo % 4 == 2 ? 30 : nil,
                steps: Double.random(in: 4_000...13_000, using: &generator).rounded(),
                waterMilliliters: Double.random(in: 900...2_600, using: &generator).rounded(),
                caffeineMilligrams: Double.random(in: 80...240, using: &generator).rounded(),
                lateCaffeineMilligrams: nil,
                alcoholicDrinks: alcohol ? 2 : nil,
                lateAlcoholicDrinks: alcohol ? 1 : nil
            )
            if daysAgo == 2 {
                day = DaytimeActivity(workoutMinutes: 52, strengthMinutes: 35, steps: 11_820, waterMilliliters: 2_300,
                                      caffeineMilligrams: 120, lateCaffeineMilligrams: nil, alcoholicDrinks: nil)
            }
            if daysAgo == 1 {
                day = DaytimeActivity(workoutMinutes: nil, strengthMinutes: nil, steps: 4_210, waterMilliliters: 700,
                                      caffeineMilligrams: 260, lateCaffeineMilligrams: 140, alcoholicDrinks: 3,
                                      lateAlcoholicDrinks: 2, congestionLevel: 2)
            }

            let night = SleepSession(startDate: bedtime, factors: factors)
            night.daytime = day
            night.noseLevel = nose
            night.sleepPosition = position
            // What Apple Weather would have said at bedtime: a cold snap in the middle of the fortnight.
            let temperature = 9 + 5 * sin(Double(daysAgo) / 2.2) + Double.random(in: -1.5...1.5, using: &generator)
            night.weather = NightWeather(
                temperatureCelsius: daysAgo == 1 ? 3.5 : (temperature * 10).rounded() / 10,
                humidity: daysAgo == 1 ? 0.86 : (Double.random(in: 0.45...0.9, using: &generator) * 100).rounded() / 100,
                pressureHectopascals: (Double.random(in: 1_004...1_024, using: &generator)).rounded(),
                condition: daysAgo == 1 ? "Cloudy" : ["Clear", "Partly Cloudy", "Cloudy", "Drizzle"].randomElement(using: &generator)
            )
            night.dayImportedAt = bedtime.addingTimeInterval(14 * 3600)
            night.endDate = bedtime.addingTimeInterval(recorded)
            night.recordedSeconds = recorded
            night.noiseFloorDB = -58

            // Background room noise per minute, plus snoring bursts.
            let minutes = Int(recorded / 60)
            var levels = (0..<minutes).map { _ in Float(-58 + Double.random(in: -2...2, using: &generator)) }
            var episodes: [(TimeInterval, TimeInterval, SnoreIntensity)] = []
            var count = Int.random(in: 6...14, using: &generator)
            if alcohol { count += 10 }
            if strip { count -= 4 }
            if position == .back { count += 3 }
            if position == .side { count -= 2 }
            if let nose, nose >= 2 { count += 4 }
            if workedOut { count -= 2 }
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
        seedReadings(in: context, generator: &generator, today: today)
        try? context.save()
    }

    /// Weight and blood pressure for the Pro trends: about 12 weeks of a slowly falling weight,
    /// and a home cuff reading every few days.
    @MainActor
    private static func seedReadings(in context: ModelContext, generator: inout SeededGenerator, today: Date) {
        let calendar = Calendar.current
        for daysAgo in stride(from: 84, through: 1, by: -3) {
            let morning = calendar.date(byAdding: .day, value: -daysAgo, to: today)!.addingTimeInterval(7.5 * 3600)
            let kilograms = 84 - Double(84 - daysAgo) * 0.035 + Double.random(in: -0.4...0.4, using: &generator)
            context.insert(BodyReading(date: morning, kind: .weight, value: (kilograms * 10).rounded() / 10,
                                       fromHealth: true, sourceName: "Smart scale"))
            if daysAgo % 2 == 0 {
                let systolic = 131 - Double(84 - daysAgo) * 0.05 + Double.random(in: -5...5, using: &generator)
                let diastolic = 84 - Double(84 - daysAgo) * 0.03 + Double.random(in: -3...3, using: &generator)
                context.insert(BodyReading(date: morning.addingTimeInterval(600), kind: .bloodPressure,
                                           value: systolic.rounded(), secondValue: diastolic.rounded(),
                                           fromHealth: true, sourceName: "Home cuff"))
            }
        }
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
