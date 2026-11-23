import Testing
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
    }
}
