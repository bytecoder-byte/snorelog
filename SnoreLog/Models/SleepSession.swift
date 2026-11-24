import Foundation
import SwiftData

enum SessionStatus: String, Codable {
    case recording
    /// Recording ended (or the app was closed) but the night has not been analyzed yet.
    case pendingAnalysis
    case analyzing
    case done
    case failed
}

@Model
final class SleepSession {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var endDate: Date?
    var statusRaw: String
    /// Things the person tagged before sleeping, for example "Alcohol" or "Nasal strip".
    var factors: [String]

    var recordedSeconds: Double
    var snoringSeconds: Double
    var score: Int
    var noiseFloorDB: Float
    var loudestDB: Float
    /// Average level per minute, for the night chart.
    var minuteLevels: [Float]
    var analysisError: String?

    // The day before this night, read from Apple Health (all optional, so older nights migrate cleanly).
    var dayWorkoutMinutes: Double?
    var dayStrengthMinutes: Double?
    var daySteps: Double?
    var dayWaterMilliliters: Double?
    var dayCaffeineMilligrams: Double?
    var dayLateCaffeineMilligrams: Double?
    var dayAlcoholicDrinks: Double?
    /// Drinks logged in the 3 hours before bed.
    var dayLateAlcoholicDrinks: Double?
    /// Strongest sinus congestion symptom logged in Health that day, 0 to 3.
    var dayCongestionLevel: Int?
    /// When Health was last read for this night. Nil means never.
    var dayImportedAt: Date?

    /// How blocked the nose felt at bedtime, 0 (clear) to 3. Nil when not noted.
    var noseLevel: Int?
    /// How the person slept, noted in the morning. Raw value of `SleepPosition`.
    var sleepPositionRaw: String?

    // Outdoor weather at bedtime, from Apple Weather, when automatic weather is on.
    var weatherTemperatureCelsius: Double?
    var weatherHumidity: Double?
    var weatherPressureHectopascals: Double?
    var weatherCondition: String?

    @Relationship(deleteRule: .cascade, inverse: \SnoreEpisode.session)
    var episodes: [SnoreEpisode] = []

    init(startDate: Date = .now, factors: [String] = []) {
        self.id = UUID()
        self.startDate = startDate
        self.statusRaw = SessionStatus.recording.rawValue
        self.factors = factors
        self.recordedSeconds = 0
        self.snoringSeconds = 0
        self.score = 0
        self.noiseFloorDB = -60
        self.loudestDB = -80
        self.minuteLevels = []
    }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var snoringPercent: Double {
        recordedSeconds > 0 ? snoringSeconds / recordedSeconds * 100 : 0
    }

    var sortedEpisodes: [SnoreEpisode] {
        episodes.sorted { $0.offset < $1.offset }
    }

    var folderURL: URL { SessionStorage.folder(for: id) }

    var sleepPosition: SleepPosition? {
        get { sleepPositionRaw.flatMap(SleepPosition.init(rawValue:)) }
        set { sleepPositionRaw = newValue?.rawValue }
    }

    var weather: NightWeather? {
        get {
            let weather = NightWeather(
                temperatureCelsius: weatherTemperatureCelsius,
                humidity: weatherHumidity,
                pressureHectopascals: weatherPressureHectopascals,
                condition: weatherCondition
            )
            return weather.isEmpty ? nil : weather
        }
        set {
            weatherTemperatureCelsius = newValue?.temperatureCelsius
            weatherHumidity = newValue?.humidity
            weatherPressureHectopascals = newValue?.pressureHectopascals
            weatherCondition = newValue?.condition
        }
    }
}

@Model
final class SnoreEpisode {
    /// Seconds from the start of the recording.
    var offset: Double
    var duration: Double
    var confidence: Double
    var peakDB: Float
    var intensityRaw: Int
    /// File name of a short audio clip inside the session folder, if one was kept.
    var clipFileName: String?
    var session: SleepSession?

    init(offset: Double, duration: Double, confidence: Double, peakDB: Float, intensity: SnoreIntensity, clipFileName: String?) {
        self.offset = offset
        self.duration = duration
        self.confidence = confidence
        self.peakDB = peakDB
        self.intensityRaw = intensity.rawValue
        self.clipFileName = clipFileName
    }

    var intensity: SnoreIntensity { SnoreIntensity(rawValue: intensityRaw) ?? .quiet }

    func startDate(in session: SleepSession) -> Date {
        session.startDate.addingTimeInterval(offset)
    }

    var clipURL: URL? {
        guard let clipFileName, let session else { return nil }
        return session.folderURL.appendingPathComponent(clipFileName)
    }
}

enum SessionStorage {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Nights", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func deleteFolder(for id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    static func totalBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Tags people can add before sleeping, so the app can show what seems to help.
enum NightFactors {
    /// About the day: filled in from Apple Health when it's on, or tagged by hand.
    static let day = DaytimeTag.manual
    /// "Congested" became the nose picker and "Slept on back" the morning position question.
    static let factors = ["Alcohol", DaytimeTag.drinksNearBed, "Late meal", "Very tired", "Smoking"]
    static let remedies = ["Side sleeping", "Nasal strip", "Mouth tape", "Anti-snore pillow", "Mouthguard", "Nasal spray"]
}

extension SleepSession {
    /// The numbers the night-to-night comparison needs.
    var snapshot: NightSnapshot {
        NightSnapshot(
            startDate: startDate,
            recordedSeconds: recordedSeconds,
            snoringSeconds: snoringSeconds,
            score: score,
            episodeCount: episodes.count,
            loudEpisodeCount: episodes.filter { $0.intensity >= .loud }.count,
            factors: factors,
            daytime: daytime,
            noseLevel: noseLevel,
            sleepPosition: sleepPosition,
            weather: weather
        )
    }

    /// The Health readings for the day before, or nil if there are none.
    var daytime: DaytimeActivity? {
        get {
            let activity = DaytimeActivity(
                workoutMinutes: dayWorkoutMinutes,
                strengthMinutes: dayStrengthMinutes,
                steps: daySteps,
                waterMilliliters: dayWaterMilliliters,
                caffeineMilligrams: dayCaffeineMilligrams,
                lateCaffeineMilligrams: dayLateCaffeineMilligrams,
                alcoholicDrinks: dayAlcoholicDrinks,
                lateAlcoholicDrinks: dayLateAlcoholicDrinks,
                congestionLevel: dayCongestionLevel
            )
            return activity.isEmpty ? nil : activity
        }
        set {
            dayWorkoutMinutes = newValue?.workoutMinutes
            dayStrengthMinutes = newValue?.strengthMinutes
            daySteps = newValue?.steps
            dayWaterMilliliters = newValue?.waterMilliliters
            dayCaffeineMilligrams = newValue?.caffeineMilligrams
            dayLateCaffeineMilligrams = newValue?.lateCaffeineMilligrams
            dayAlcoholicDrinks = newValue?.alcoholicDrinks
            dayLateAlcoholicDrinks = newValue?.lateAlcoholicDrinks
            dayCongestionLevel = newValue?.congestionLevel
        }
    }

    /// Manual tags, nose, position and weather tags, plus tags earned from Health data.
    var allFactors: [String] { snapshot.allFactors }
}
