import Foundation

// Pure logic with no Apple-framework dependencies, so it is easy to unit test.

/// What happened during the day before a night, read from Apple Health.
/// Every value is optional: nil means Health had nothing for it (or access was not given),
/// which is different from zero.
struct DaytimeActivity: Equatable {
    /// All workouts that ended that day, strength training included.
    var workoutMinutes: Double?
    /// The part of `workoutMinutes` that was strength training.
    var strengthMinutes: Double?
    var steps: Double?
    var waterMilliliters: Double?
    var caffeineMilligrams: Double?
    /// Caffeine logged from 3 PM onwards.
    var lateCaffeineMilligrams: Double?
    var alcoholicDrinks: Double?
    /// The part of `alcoholicDrinks` logged in the last 3 hours before bed.
    var lateAlcoholicDrinks: Double? = nil
    /// The strongest sinus congestion symptom logged in Health that day, on the 0 to 3 scale of `NoseLevel`.
    var congestionLevel: Int? = nil

    var isEmpty: Bool {
        [workoutMinutes, strengthMinutes, steps, waterMilliliters, caffeineMilligrams, lateCaffeineMilligrams, alcoholicDrinks, lateAlcoholicDrinks]
            .allSatisfy { $0 == nil } && congestionLevel == nil
    }

    // Thresholds for turning numbers into tags.
    static let exerciseMinutes = 20.0
    static let strengthMinutesThreshold = 10.0
    static let activeDaySteps = 10_000.0
    static let lowWaterMilliliters = 1_000.0
    static let lateCaffeineThreshold = 50.0
    /// Caffeine logged at or after this hour counts as late.
    static let lateCaffeineHour = 15
    /// Drinks logged this close to bedtime count as "near bedtime". Sleep-lab studies found
    /// alcohol's effect on snoring is strongest in the first hours after drinking.
    static let lateAlcoholHours = 3.0

    /// The tags this day earns. They use the same names as the manual "Your day" tags,
    /// so a manual tag and a Health reading count as the same thing.
    var tags: [String] {
        var tags: [String] = []
        if let workoutMinutes, workoutMinutes >= Self.exerciseMinutes { tags.append(DaytimeTag.exercise) }
        if let strengthMinutes, strengthMinutes >= Self.strengthMinutesThreshold { tags.append(DaytimeTag.strength) }
        if let steps, steps >= Self.activeDaySteps { tags.append(DaytimeTag.activeDay) }
        // Only when some water was logged: no water data at all says nothing about drinking.
        if let waterMilliliters, waterMilliliters > 0, waterMilliliters < Self.lowWaterMilliliters { tags.append(DaytimeTag.lowWater) }
        if let lateCaffeineMilligrams, lateCaffeineMilligrams >= Self.lateCaffeineThreshold { tags.append(DaytimeTag.lateCaffeine) }
        if let alcoholicDrinks, alcoholicDrinks >= 1 { tags.append(DaytimeTag.alcohol) }
        if let lateAlcoholicDrinks, lateAlcoholicDrinks >= 1 { tags.append(DaytimeTag.drinksNearBed) }
        if let congestionLevel, let tag = NoseLevel(rawValue: min(3, max(0, congestionLevel)))?.tag { tags.append(tag) }
        return tags
    }

    /// The measured value behind a tag, for example "45 min of workouts". Nil when the tag
    /// did not come from Health data (or the number is missing).
    func measurement(for tag: String) -> String? {
        switch tag {
        case DaytimeTag.exercise, DaytimeTag.strength:
            guard let workoutMinutes, workoutMinutes > 0 else { return nil }
            if let strengthMinutes, strengthMinutes > 0 {
                return "\(Self.minutes(workoutMinutes)) of workouts, \(Self.minutes(strengthMinutes)) strength"
            }
            return "\(Self.minutes(workoutMinutes)) of workouts"
        case DaytimeTag.activeDay:
            return steps.map { "\(Self.count($0)) steps" }
        case DaytimeTag.lowWater:
            return waterMilliliters.map { "\(Self.liters($0)) of water logged" }
        case DaytimeTag.lateCaffeine:
            return lateCaffeineMilligrams.map { "\(Int($0.rounded())) mg of caffeine after 3 PM" }
        case DaytimeTag.alcohol:
            return alcoholicDrinks.map { $0 == 1 ? "1 drink logged" : "\(Self.count($0)) drinks logged" }
        case DaytimeTag.drinksNearBed:
            return lateAlcoholicDrinks.map {
                ($0 == 1 ? "1 drink" : "\(Self.count($0)) drinks") + " logged in the 3 hours before bed"
            }
        case ContextTag.noseSlightly, ContextTag.noseBlocked:
            return congestionLevel.flatMap { NoseLevel(rawValue: min(3, max(0, $0))) }
                .map { "Sinus congestion logged in Health (\($0.title.lowercased()))" }
        default:
            return nil
        }
    }

    static func minutes(_ value: Double) -> String { Formatters.duration(value * 60) }
    static func count(_ value: Double) -> String { Int(value.rounded()).formatted(.number) }
    static func liters(_ value: Double) -> String { (value / 1000).formatted(.number.precision(.fractionLength(1))) + " L" }

    /// The part of the day before a night that counts: from the start of that day until bedtime.
    /// The last `lateAlcoholHours` of the window before bed.
    static func lateAlcoholWindow(beforeBedtime bedtime: Date, calendar: Calendar = .current) -> DateInterval {
        let day = Self.window(beforeBedtime: bedtime, calendar: calendar)
        let start = max(day.start, bedtime.addingTimeInterval(-lateAlcoholHours * 3600))
        return DateInterval(start: min(start, day.end), end: day.end)
    }

    /// Bedtimes before 6 AM belong to the day before (going to bed at 1 AM ends Tuesday, not Wednesday).
    static func window(beforeBedtime bedtime: Date, calendar: Calendar = .current) -> DateInterval {
        var day = calendar.startOfDay(for: bedtime)
        if calendar.component(.hour, from: bedtime) < 6 {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return DateInterval(start: day, end: max(day, bedtime))
    }
}

/// Names of the daytime tags. Manual tags and Health readings share these.
enum DaytimeTag {
    static let exercise = "Exercise"
    static let strength = "Strength training"
    static let activeDay = "Active day"
    static let lowWater = "Low water"
    static let lateCaffeine = "Late caffeine"
    /// The same tag as the bedtime one, so logging a drink in Health and tagging it don't double count.
    static let alcohol = "Alcohol"
    /// Drinks in the last 3 hours before bed. Added on top of "Alcohol", so both comparisons work.
    static let drinksNearBed = "Drinks near bedtime"

    /// Shown in the "Your day" picker for people who don't use Apple Health, or want to add to it.
    static let manual = [exercise, strength, activeDay, lowWater, lateCaffeine]
}
