import Foundation

// Pure logic with no Apple-framework dependencies, so it is easy to unit test.

/// The numbers from one analyzed night that the comparison needs.
struct NightSnapshot: Equatable {
    var startDate: Date
    var recordedSeconds: TimeInterval
    var snoringSeconds: TimeInterval
    var score: Int
    var episodeCount: Int
    /// Episodes rated loud or very loud.
    var loudEpisodeCount: Int
    var factors: [String]

    var snoringPercent: Double {
        recordedSeconds > 0 ? snoringSeconds / recordedSeconds * 100 : 0
    }
}

/// How one night went compared with the night before it.
struct NightComparison: Equatable {
    enum Verdict: Equatable {
        case better, similar, worse
    }

    var current: NightSnapshot
    var previous: NightSnapshot

    /// Score changes smaller than this count as "about the same".
    static let similarScoreRange = 3

    var scoreChange: Int { current.score - previous.score }
    var snoringChange: TimeInterval { current.snoringSeconds - previous.snoringSeconds }
    var percentChange: Double { current.snoringPercent - previous.snoringPercent }
    var episodeChange: Int { current.episodeCount - previous.episodeCount }
    var loudEpisodeChange: Int { current.loudEpisodeCount - previous.loudEpisodeCount }

    /// Lower scores are better, so a falling score is an improvement.
    var verdict: Verdict {
        if abs(scoreChange) < Self.similarScoreRange { return .similar }
        return scoreChange < 0 ? .better : .worse
    }

    /// Tags used on this night but not the one before.
    var addedFactors: [String] { current.factors.filter { !previous.factors.contains($0) }.sorted() }
    /// Tags used the night before but not on this night.
    var removedFactors: [String] { previous.factors.filter { !current.factors.contains($0) }.sorted() }

    /// Minutes between the two bedtimes, ignoring the date. Positive means a later bedtime.
    var bedtimeShiftMinutes: Int {
        Self.minutesFromNoon(current.startDate) - Self.minutesFromNoon(previous.startDate)
    }

    var recordedChange: TimeInterval { current.recordedSeconds - previous.recordedSeconds }

    /// Minutes since the most recent noon, so 11 PM and 1 AM are 2 hours apart, not 22.
    private static func minutesFromNoon(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return (minutes - 12 * 60 + 24 * 60) % (24 * 60)
    }

    /// The latest night that started before `night`, out of `nights` (in any order).
    static func previous(of night: NightSnapshot, in nights: [NightSnapshot]) -> NightSnapshot? {
        nights
            .filter { $0.startDate < night.startDate }
            .max { $0.startDate < $1.startDate }
    }
}

/// Something that differed from the night before and could have changed the result.
struct ImpactHint: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A tag used this night but not the night before.
        case added
        /// A tag used the night before but not this night.
        case removed
        /// Bedtime or time asleep changed.
        case timing
    }

    /// Which way this would be expected to move the score.
    enum Effect: Equatable {
        case louder, quieter, unclear
    }

    var title: String
    var detail: String
    var kind: Kind
    var effect: Effect

    var id: String { title }

    /// Everyday tags that tend to go with more snoring. Remedies tend to go with less.
    static let usuallyLouder: Set<String> = ["Alcohol", "Congested", "Late meal", "Very tired", "Slept on back", "Smoking"]
    static let usuallyQuieter: Set<String> = ["Side sleeping", "Nasal strip", "Mouth tape", "Anti-snore pillow", "Mouthguard", "Nasal spray"]

    /// A personal pattern is used once a tag has been on this many nights and there are nights without it.
    static let minimumNightsForPattern = 2
    /// Personal differences smaller than this many score points count as "no clear pattern".
    static let minimumPatternDifference = 3.0

    /// Builds the list of differences, most likely to explain the change first.
    /// `history` is every analyzed night's tags and score, used to find personal patterns.
    static func hints(for comparison: NightComparison, history: [(factors: [String], score: Int)]) -> [ImpactHint] {
        let impacts = Dictionary(
            FactorImpact.compute(nights: history).map { ($0.factor, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var hints: [ImpactHint] = []

        for factor in comparison.addedFactors {
            let (effect, detail) = describe(factor: factor, impact: impacts[factor], present: true)
            hints.append(ImpactHint(title: factor, detail: detail, kind: .added, effect: effect))
        }
        for factor in comparison.removedFactors {
            let (effect, detail) = describe(factor: factor, impact: impacts[factor], present: false)
            hints.append(ImpactHint(title: factor, detail: detail, kind: .removed, effect: effect))
        }

        let shift = comparison.bedtimeShiftMinutes
        if abs(shift) >= 45 {
            let amount = Formatters.duration(Double(abs(shift)) * 60)
            hints.append(ImpactHint(
                title: shift > 0 ? "Bed \(amount) later" : "Bed \(amount) earlier",
                detail: "Bedtime changes can affect how deeply you sleep.",
                kind: .timing,
                effect: .unclear
            ))
        }
        let recordedChange = comparison.recordedChange
        if abs(recordedChange) >= 3600 {
            let amount = Formatters.duration(abs(recordedChange))
            hints.append(ImpactHint(
                title: recordedChange > 0 ? "\(amount) longer night" : "\(amount) shorter night",
                detail: recordedChange > 0
                    ? "More time recorded means more time to snore, though the score allows for it."
                    : "Being short on sleep can make the next nights louder.",
                kind: .timing,
                effect: .unclear
            ))
        }

        // Put the hints that match the direction of the change first.
        let expected: Effect? = switch comparison.verdict {
        case .worse: .louder
        case .better: .quieter
        case .similar: nil
        }
        return hints.enumerated().sorted { lhs, rhs in
            let lhsRank = rank(lhs.element.effect, expected: expected)
            let rhsRank = rank(rhs.element.effect, expected: expected)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        .map(\.element)
    }

    private static func rank(_ effect: Effect, expected: Effect?) -> Int {
        guard let expected else { return effect == .unclear ? 1 : 0 }
        if effect == expected { return 0 }
        if effect == .unclear { return 1 }
        return 2
    }

    /// Describes a tag that was added (`present`) or dropped (`!present`) compared with the night before.
    private static func describe(factor: String, impact: FactorImpact?, present: Bool) -> (Effect, String) {
        if let impact, let difference = impact.difference, impact.nightsWith >= minimumNightsForPattern {
            let points = Int(abs(difference).rounded())
            let nights = "\(impact.nightsWith) nights"
            if abs(difference) < minimumPatternDifference {
                return (.unclear, "No clear pattern yet on your \(nights) with it.")
            }
            let louderWith = difference > 0
            let effect: Effect = (louderWith == present) ? .louder : .quieter
            let pattern = louderWith
                ? "Your score averages \(points) higher with it (\(nights))."
                : "Your score averages \(points) lower with it (\(nights))."
            return (effect, pattern)
        }

        if usuallyLouder.contains(factor) {
            return (present ? .louder : .quieter,
                    present ? "Often goes with louder snoring." : "Often goes with louder snoring. You had it the night before.")
        }
        if usuallyQuieter.contains(factor) {
            return (present ? .quieter : .louder,
                    present ? "Helps some people snore less." : "Helps some people snore less. You used it the night before.")
        }
        return (.unclear, "Not enough nights yet to see a pattern.")
    }
}
