import Foundation

// Pure logic with no Apple-framework dependencies besides Foundation, so it is easy to unit test.
//
// Wording rule for everything in this file: compare a person only with their own nights,
// never name a condition and never apply a clinical cut-off.

/// How blocked the nose felt at bedtime, from clear (0) to very blocked (3).
enum NoseLevel: Int, CaseIterable, Identifiable {
    case clear = 0, slightly, blocked, veryBlocked

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .clear: "Clear"
        case .slightly: "A bit blocked"
        case .blocked: "Blocked"
        case .veryBlocked: "Very blocked"
        }
    }

    /// The tag this level adds to a night. Clear nights get none, so they are the "without" side
    /// of the comparison. Blocked and very blocked share a tag so a pattern shows up sooner.
    var tag: String? {
        switch self {
        case .clear: nil
        case .slightly: ContextTag.noseSlightly
        case .blocked, .veryBlocked: ContextTag.noseBlocked
        }
    }
}

/// How the person slept, noted in the morning. A phone on the nightstand can't sense this.
enum SleepPosition: String, CaseIterable, Identifiable {
    case back, side, mixed, aid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: "Back"
        case .side: "Side"
        case .mixed: "Mixed"
        case .aid: "Positional aid"
        }
    }

    var tag: String {
        switch self {
        case .back: ContextTag.back
        case .side: ContextTag.side
        case .mixed: ContextTag.mixed
        case .aid: ContextTag.aid
        }
    }
}

/// Outdoor weather at bedtime, from Apple Weather. Every value is optional.
struct NightWeather: Equatable {
    var temperatureCelsius: Double?
    /// 0 to 1.
    var humidity: Double?
    var pressureHectopascals: Double?
    /// Apple's description, for example "Partly Cloudy".
    var condition: String?

    var isEmpty: Bool { temperatureCelsius == nil && humidity == nil && pressureHectopascals == nil && condition == nil }

    // Plain weather bands, not health thresholds.
    static let coldBelowCelsius = 5.0
    static let warmAboveCelsius = 22.0
    static let humidAbove = 0.8
    static let dryBelow = 0.35

    var tags: [String] {
        var tags: [String] = []
        if let temperatureCelsius {
            if temperatureCelsius < Self.coldBelowCelsius { tags.append(ContextTag.cold) }
            if temperatureCelsius > Self.warmAboveCelsius { tags.append(ContextTag.warm) }
        }
        if let humidity {
            if humidity >= Self.humidAbove { tags.append(ContextTag.humid) }
            if humidity < Self.dryBelow { tags.append(ContextTag.dry) }
        }
        return tags
    }
}

/// Names of the tags that come from the nose level, sleep position and weather.
enum ContextTag {
    static let noseSlightly = "Nose a bit blocked"
    static let noseBlocked = "Blocked nose"
    /// Kept so the "Congested" tag on older nights still counts.
    static let legacyCongested = "Congested"

    /// Same name as the old bedtime tag, so older nights keep counting.
    static let back = "Slept on back"
    static let side = "Slept on side"
    static let mixed = "Mixed positions"
    static let aid = "Positional aid"

    static let cold = "Cold night"
    static let warm = "Warm night"
    static let humid = "Humid night"
    static let dry = "Dry air"

    static let nose: Set<String> = [noseSlightly, noseBlocked]
    static let weather: Set<String> = [cold, warm, humid, dry]
}
