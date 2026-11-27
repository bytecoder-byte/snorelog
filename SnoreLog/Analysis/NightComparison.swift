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
    /// The day before this night, from Apple Health. Nil when Health isn't used.
    var daytime: DaytimeActivity? = nil
    /// 0 to 3, see `NoseLevel`. Nil when not noted.
    var noseLevel: Int? = nil
    var sleepPosition: SleepPosition? = nil
    var weather: NightWeather? = nil

    /// Manual tags, the nose, position and weather tags, and the tags earned from Health data, without duplicates.
    var allFactors: [String] {
        NightSnapshot.combine(factors + contextTags, healthTags)
    }

    /// Tags from the nose level, sleep position and weather noted for this night.
    var contextTags: [String] {
        [noseLevel.flatMap { NoseLevel(rawValue: $0)?.tag }, sleepPosition?.tag].compactMap { $0 } + (weather?.tags ?? [])
    }

    /// Tags earned from Health data. A nose level set by hand replaces the one from Health.
    var healthTags: [String] {
        let tags = daytime?.tags ?? []
        return noseLevel == nil ? tags : tags.filter { !ContextTag.nose.contains($0) }
    }

    static func combine(_ manual: [String], _ health: [String]) -> [String] {
        var seen = Set<String>()
        return (manual + health).filter { seen.insert($0).inserted }
    }

    /// True when a tag came from Health data rather than only from a manual tag.
    func isFromHealth(_ tag: String) -> Bool {
        !factors.contains(tag) && !contextTags.contains(tag) && healthTags.contains(tag)
    }

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

    /// Tags (manual or from Health) on this night but not the one before.
    var addedFactors: [String] { current.allFactors.filter { !previous.allFactors.contains($0) }.sorted() }
    /// Tags (manual or from Health) on the night before but not this night.
    var removedFactors: [String] { previous.allFactors.filter { !current.allFactors.contains($0) }.sorted() }

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
        /// Two tags on this night that are known to add up, such as alcohol and back sleeping.
        case combination
    }

    /// Which way this would be expected to move the score.
    enum Effect: Equatable {
        case louder, quieter, unclear
    }

    var title: String
    var detail: String
    var kind: Kind
    var effect: Effect
    /// The tag came from Apple Health data, not a manual tag.
    var fromHealth = false

    var id: String { title }

    /// Everyday tags that tend to go with more snoring. Remedies tend to go with less.
    static let usuallyLouder: Set<String> = [
        "Alcohol", ContextTag.legacyCongested, "Late meal", "Very tired", ContextTag.back, "Smoking", DaytimeTag.lowWater,
        DaytimeTag.drinksNearBed, ContextTag.noseSlightly, ContextTag.noseBlocked,
    ]
    static let usuallyQuieter: Set<String> = [
        "Side sleeping", "Nasal strip", "Mouth tape", "Anti-snore pillow", "Mouthguard", "Nasal spray",
        ContextTag.side, ContextTag.aid,
    ]

    /// What is generally said about daytime tags whose effect on snoring varies from person to person.
    static let daytimeNotes: [String: String] = [
        DaytimeTag.exercise: "Activity can change how deeply you sleep.",
        DaytimeTag.strength: "Activity can change how deeply you sleep.",
        DaytimeTag.activeDay: "Activity can change how deeply you sleep.",
        DaytimeTag.lateCaffeine: "Caffeine late in the day can make sleep lighter.",
        ContextTag.mixed: "You moved between positions.",
        ContextTag.cold: "Outdoor weather can change the air in your bedroom.",
        ContextTag.warm: "Outdoor weather can change the air in your bedroom.",
        ContextTag.humid: "Outdoor weather can change the air in your bedroom.",
        ContextTag.dry: "Outdoor weather can change the air in your bedroom.",
    ]

    /// Specific wording for added tags, instead of the generic "Often goes with louder snoring".
    static let addedNotes: [String: String] = [
        DaytimeTag.drinksNearBed: "In sleep-lab studies, snoring rose most in the first hours after drinking.",
        ContextTag.noseBlocked: "A blocked nose often goes with louder snoring.",
        ContextTag.noseSlightly: "A blocked nose often goes with louder snoring.",
        ContextTag.side: "Many people snore less on their side.",
    ]

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
            let measured = comparison.current.isFromHealth(factor) ? comparison.current.daytime?.measurement(for: factor) : nil
            hints.append(ImpactHint(
                title: factor,
                detail: [measured.map { "\($0) that day." }, detail].compactMap { $0 }.joined(separator: " "),
                kind: .added,
                effect: effect,
                fromHealth: comparison.current.isFromHealth(factor)
            ))
        }
        for factor in comparison.removedFactors {
            let (effect, detail) = describe(factor: factor, impact: impacts[factor], present: false)
            let measured = comparison.previous.isFromHealth(factor) ? comparison.previous.daytime?.measurement(for: factor) : nil
            hints.append(ImpactHint(
                title: factor,
                detail: [measured.map { "The day before: \($0)." }, detail].compactMap { $0 }.joined(separator: " "),
                kind: .removed,
                effect: effect,
                fromHealth: comparison.previous.isFromHealth(factor)
            ))
        }

        // Alcohol and back sleeping: the effect of drinking was larger on the back in sleep-lab studies.
        // Only when part of the pair is new this night, since hints are about what changed.
        let tags = comparison.current.allFactors
        let pair: Set<String> = [ContextTag.back, DaytimeTag.alcohol, DaytimeTag.drinksNearBed]
        if tags.contains(ContextTag.back),
           tags.contains(DaytimeTag.alcohol) || tags.contains(DaytimeTag.drinksNearBed),
           comparison.addedFactors.contains(where: { pair.contains($0) }) {
            hints.append(ImpactHint(
                title: "Alcohol and back sleeping",
                detail: "Both on the same night. In sleep-lab studies, alcohol's effect on snoring was larger on the back.",
                kind: .combination,
                effect: .louder
            ))
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
            let note = addedNotes[factor] ?? "Often goes with louder snoring."
            return (present ? .louder : .quieter,
                    present ? note : "\(note) You had it the night before.")
        }
        if usuallyQuieter.contains(factor) {
            let note = addedNotes[factor] ?? "Helps some people snore less."
            return (present ? .quieter : .louder,
                    present ? note : "\(note) You used it the night before.")
        }
        if let note = daytimeNotes[factor] {
            return (.unclear, note + " Not enough nights yet to see your own pattern.")
        }
        return (.unclear, "Not enough nights yet to see a pattern.")
    }
}
