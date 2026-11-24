import Testing
import Foundation
@testable import SnoreLog

struct EpisodeBuilderTests {
    private func window(_ start: Double, _ confidence: Double, duration: Double = 1) -> ClassifiedWindow {
        ClassifiedWindow(start: start, duration: duration, snoreConfidence: confidence)
    }

    @Test func mergesSnoresWithinOneBreathCycle() {
        // Snores every 4 seconds for 20 seconds should be one episode.
        let windows = stride(from: 0.0, through: 20, by: 4).map { window($0, 0.9) }
        let episodes = EpisodeBuilder(threshold: 0.5).episodes(from: windows)
        #expect(episodes.count == 1)
        #expect(episodes[0].start == 0)
        #expect(episodes[0].end == 21)
    }

    @Test func splitsEpisodesAfterALongGap() {
        let windows = [window(0, 0.9), window(3, 0.9), window(60, 0.8), window(63, 0.8)]
        let episodes = EpisodeBuilder(threshold: 0.5).episodes(from: windows)
        #expect(episodes.map(\.start) == [0, 60])
    }

    @Test func ignoresWindowsBelowThreshold() {
        let windows = [window(0, 0.2), window(1, 0.3), window(2, 0.4)]
        #expect(EpisodeBuilder(threshold: 0.5).episodes(from: windows).isEmpty)
    }

    @Test func dropsEpisodesShorterThanMinimum() {
        let windows = [window(0, 0.9, duration: 1)]
        #expect(EpisodeBuilder(threshold: 0.5, minDuration: 2).episodes(from: windows).isEmpty)
    }

    @Test func keepsHighestConfidenceAndHandlesUnsortedInput() {
        let windows = [window(4, 0.6), window(0, 0.95), window(2, 0.7)]
        let episodes = EpisodeBuilder(threshold: 0.5).episodes(from: windows)
        #expect(episodes.count == 1)
        #expect(episodes[0].maxConfidence == 0.95)
    }

    @Test func overlappingWindowsDoNotShrinkTheEpisode() {
        let windows = [window(0, 0.9, duration: 3), window(1, 0.9, duration: 1)]
        let episodes = EpisodeBuilder(threshold: 0.5).episodes(from: windows)
        #expect(episodes[0].end == 3)
    }
}

struct NightScoringTests {
    @Test func noiseFloorIsTenthPercentile() {
        let levels: [Float] = (0..<100).map { Float(-100 + $0) }
        #expect(NightScoring.noiseFloor(levels) == -91)
        #expect(NightScoring.noiseFloor([]) == -60)
    }

    @Test func peakFindsLoudestSecondInRange() {
        let levels: [Float] = [-60, -55, -30, -58, -20]
        #expect(NightScoring.peak(levels, from: 1, to: 4) == -30)
        #expect(NightScoring.peak(levels, from: 3, to: 99) == -20)
        #expect(NightScoring.peak(levels, from: 2, to: 2) == -30)
    }

    @Test func downsampleAveragesGroups() {
        #expect(NightScoring.downsample([1, 3, 5, 7, 9], by: 2) == [2, 6, 9])
        #expect(NightScoring.downsample([], by: 60).isEmpty)
    }

    @Test func intensityFromRiseAboveNoiseFloor() {
        #expect(SnoreIntensity.from(peakDB: -50, noiseFloorDB: -55) == .quiet)
        #expect(SnoreIntensity.from(peakDB: -40, noiseFloorDB: -55) == .loud)
        #expect(SnoreIntensity.from(peakDB: -25, noiseFloorDB: -55) == .epic)
    }

    @Test func scoreIsWeightedShareOfNight() {
        // 8 hours, 1 hour of loud snoring: 3600 * 2 / (28800 * 3) = 8.3%.
        let score = NightScoring.score(episodes: [(duration: 3600, intensity: .loud)], recordedSeconds: 28_800)
        #expect(score == 8)
        #expect(NightScoring.score(episodes: [], recordedSeconds: 28_800) == 0)
        #expect(NightScoring.score(episodes: [(duration: 10, intensity: .epic)], recordedSeconds: 0) == 0)
        #expect(NightScoring.score(episodes: [(duration: 99_999, intensity: .epic)], recordedSeconds: 100) == 100)
    }
}

struct FactorImpactTests {
    @Test func comparesNightsWithAndWithoutFactor() {
        let nights: [(factors: [String], score: Int)] = [
            (["Alcohol"], 40),
            (["Alcohol"], 30),
            ([], 10),
            (["Nasal strip"], 5),
        ]
        let impacts = FactorImpact.compute(nights: nights)
        let alcohol = impacts.first { $0.factor == "Alcohol" }
        #expect(alcohol?.nightsWith == 2)
        #expect(alcohol?.averageWith == 35)
        #expect(alcohol?.averageWithout == 7.5)
        // Alcohol has the biggest difference, so it comes first.
        #expect(impacts.first?.factor == "Alcohol")
    }

    @Test func factorOnEveryNightHasNoComparison() {
        let impacts = FactorImpact.compute(nights: [(factors: ["Mouth tape"], score: 12)])
        #expect(impacts.first?.averageWithout == nil)
        #expect(impacts.first?.difference == nil)
    }
}

struct FormatterTests {
    @Test func formatsDurations() {
        #expect(Formatters.duration(45) == "45s")
        #expect(Formatters.duration(125) == "2m")
        #expect(Formatters.duration(3 * 3600 + 20 * 60) == "3h 20m")
        #expect(Formatters.duration(2 * 3600) == "2h")
    }
}

struct NightComparisonTests {
    private func night(
        hour: Int, minute: Int = 0, day: Int = 1, score: Int, snoringMinutes: Double = 30,
        recordedHours: Double = 8, loud: Int = 0, factors: [String] = []
    ) -> NightSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        return NightSnapshot(
            startDate: date, recordedSeconds: recordedHours * 3600, snoringSeconds: snoringMinutes * 60,
            score: score, episodeCount: loud + 3, loudEpisodeCount: loud, factors: factors
        )
    }

    @Test func picksTheLatestEarlierNight() {
        let current = night(hour: 23, day: 10, score: 20)
        let nights = [night(hour: 23, day: 7, score: 1), night(hour: 23, day: 9, score: 2), current, night(hour: 23, day: 11, score: 3)]
        #expect(NightComparison.previous(of: current, in: nights)?.score == 2)
        #expect(NightComparison.previous(of: nights[0], in: nights) == nil)
    }

    @Test func verdictTreatsSmallChangesAsSimilar() {
        let before = night(hour: 23, day: 1, score: 20)
        #expect(NightComparison(current: night(hour: 23, day: 2, score: 22), previous: before).verdict == .similar)
        #expect(NightComparison(current: night(hour: 23, day: 2, score: 30), previous: before).verdict == .worse)
        #expect(NightComparison(current: night(hour: 23, day: 2, score: 10), previous: before).verdict == .better)
    }

    @Test func findsAddedAndRemovedTags() {
        let comparison = NightComparison(
            current: night(hour: 23, day: 2, score: 30, factors: ["Alcohol", "Nasal strip"]),
            previous: night(hour: 23, day: 1, score: 10, factors: ["Nasal strip", "Side sleeping"])
        )
        #expect(comparison.addedFactors == ["Alcohol"])
        #expect(comparison.removedFactors == ["Side sleeping"])
    }

    @Test func bedtimeShiftWrapsAroundMidnight() {
        // 11 PM one night, 1 AM the next: two hours later, not 22 hours earlier.
        let comparison = NightComparison(current: night(hour: 1, day: 3, score: 10), previous: night(hour: 23, day: 1, score: 10))
        #expect(comparison.bedtimeShiftMinutes == 120)
        let earlier = NightComparison(current: night(hour: 22, minute: 30, day: 2, score: 10), previous: night(hour: 23, day: 1, score: 10))
        #expect(earlier.bedtimeShiftMinutes == -30)
    }

    @Test func hintsMatchingTheChangeComeFirst() {
        let comparison = NightComparison(
            current: night(hour: 1, day: 3, score: 35, factors: ["Alcohol"]),
            previous: night(hour: 23, day: 1, score: 12, factors: ["Nasal strip"])
        )
        let hints = ImpactHint.hints(for: comparison, history: [])
        // Both point to a louder night, then the later bedtime, which has no clear direction.
        #expect(hints.map(\.title) == ["Alcohol", "Nasal strip", "Bed 2h later"])
        #expect(hints[0].kind == .added && hints[0].effect == .louder)
        #expect(hints[1].kind == .removed && hints[1].effect == .louder)
        #expect(hints[2].effect == .unclear)
    }

    @Test func personalPatternOverridesGeneralKnowledge() {
        // For this person, nights with a nasal strip have been louder, so dropping it points to quieter.
        let history: [(factors: [String], score: Int)] = [
            (["Nasal strip"], 30), (["Nasal strip"], 34), ([], 10), ([], 14),
        ]
        let comparison = NightComparison(
            current: night(hour: 23, day: 2, score: 8),
            previous: night(hour: 23, day: 1, score: 30, factors: ["Nasal strip"])
        )
        let hint = ImpactHint.hints(for: comparison, history: history).first
        #expect(hint?.effect == .quieter)
        #expect(hint?.detail == "Your score averages 20 higher with it (2 nights).")
    }

    @Test func noHintsWhenNothingChanged() {
        let comparison = NightComparison(
            current: night(hour: 23, day: 2, score: 15, factors: ["Alcohol"]),
            previous: night(hour: 23, minute: 20, day: 1, score: 10, factors: ["Alcohol"])
        )
        #expect(ImpactHint.hints(for: comparison, history: []).isEmpty)
    }
}
