import Foundation
import Testing
@testable import SnoreLog

struct NightContextTests {
    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func night(day: Int, score: Int = 10, factors: [String] = [], daytime: DaytimeActivity? = nil,
                       nose: Int? = nil, position: SleepPosition? = nil, weather: NightWeather? = nil,
                       snoring: TimeInterval = 1800, recorded: TimeInterval = 8 * 3600) -> NightSnapshot {
        NightSnapshot(
            startDate: date(day: day, hour: 23), recordedSeconds: recorded, snoringSeconds: snoring,
            score: score, episodeCount: 3, loudEpisodeCount: 0, factors: factors, daytime: daytime,
            noseLevel: nose, sleepPosition: position, weather: weather
        )
    }

    // MARK: Nose, position and weather tags

    @Test func noseLevelsEarnTags() {
        #expect(NoseLevel.clear.tag == nil)
        #expect(night(day: 1, nose: 1).allFactors == ["Nose a bit blocked"])
        #expect(night(day: 1, nose: 2).allFactors == ["Blocked nose"])
        #expect(night(day: 1, nose: 3).allFactors == ["Blocked nose"])
        #expect(night(day: 1, nose: 0).allFactors.isEmpty)
    }

    @Test func congestionFromHealthCountsUntilANoseLevelIsSetByHand() {
        let health = DaytimeActivity(congestionLevel: 2)
        let fromHealth = night(day: 1, daytime: health)
        #expect(fromHealth.allFactors == ["Blocked nose"])
        #expect(fromHealth.isFromHealth("Blocked nose"))

        // The person said their nose was clear: that wins over Health.
        #expect(night(day: 1, daytime: health, nose: 0).allFactors.isEmpty)
        let manual = night(day: 1, daytime: health, nose: 1)
        #expect(manual.allFactors == ["Nose a bit blocked"])
        #expect(!manual.isFromHealth("Nose a bit blocked"))
    }

    @Test func positionTagKeepsTheOldBackSleepingName() {
        #expect(night(day: 1, position: .back).allFactors == ["Slept on back"])
        #expect(night(day: 1, position: .side).allFactors == ["Slept on side"])
        // An older night tagged "Slept on back" by hand and a new one with the position count as the same thing.
        #expect(night(day: 1, factors: ["Slept on back"], position: .back).allFactors == ["Slept on back"])
    }

    @Test func weatherTagsUsePlainWeatherBands() {
        #expect(NightWeather(temperatureCelsius: 2, humidity: 0.9).tags == ["Cold night", "Humid night"])
        #expect(NightWeather(temperatureCelsius: 25, humidity: 0.3).tags == ["Warm night", "Dry air"])
        #expect(NightWeather(temperatureCelsius: 15, humidity: 0.6).tags.isEmpty)
        #expect(NightWeather().isEmpty)
        #expect(night(day: 1, weather: NightWeather(temperatureCelsius: 1)).allFactors == ["Cold night"])
    }

    // MARK: Drinks near bedtime

    @Test func drinksNearBedtimeAddToTheAlcoholTag() {
        let day = DaytimeActivity(alcoholicDrinks: 3, lateAlcoholicDrinks: 2)
        #expect(day.tags == ["Alcohol", "Drinks near bedtime"])
        #expect(day.measurement(for: "Drinks near bedtime") == "2 drinks logged in the 3 hours before bed")
        #expect(DaytimeActivity(alcoholicDrinks: 1, lateAlcoholicDrinks: 0).tags == ["Alcohol"])
        #expect(!DaytimeActivity(lateAlcoholicDrinks: 0).isEmpty)
    }

    @Test func lateAlcoholWindowIsTheLastThreeHoursBeforeBed() {
        let window = DaytimeActivity.lateAlcoholWindow(beforeBedtime: date(day: 10, hour: 23))
        #expect(window.start == date(day: 10, hour: 20))
        #expect(window.end == date(day: 10, hour: 23))
        // Never reaches back past the start of the day.
        let early = DaytimeActivity.lateAlcoholWindow(beforeBedtime: date(day: 10, hour: 1, minute: 30))
        #expect(early.start == date(day: 9, hour: 22, minute: 30))
        let morning = DaytimeActivity.lateAlcoholWindow(beforeBedtime: date(day: 10, hour: 7))
        #expect(morning.start == date(day: 10, hour: 4))
        #expect(morning.start >= DaytimeActivity.window(beforeBedtime: date(day: 10, hour: 7)).start)
    }

    // MARK: Hints

    @Test func alcoholWithBackSleepingGetsAComboHint() {
        let comparison = NightComparison(
            current: night(day: 2, score: 40, factors: ["Alcohol"], position: .back),
            previous: night(day: 1, score: 10, position: .side)
        )
        let hints = ImpactHint.hints(for: comparison, history: [])
        let combo = hints.first { $0.kind == .combination }
        #expect(combo?.title == "Alcohol and back sleeping")
        #expect(combo?.effect == .louder)
        // Side sleeping on the night before points to the louder night too.
        #expect(hints.first { $0.title == "Slept on side" }?.effect == .louder)
    }

    @Test func noComboHintWhenNothingChanged() {
        let same = night(day: 1, factors: ["Alcohol"], position: .back)
        var next = same
        next.startDate = date(day: 2, hour: 23)
        #expect(ImpactHint.hints(for: NightComparison(current: next, previous: same), history: []).isEmpty)
    }

    @Test func blockedNoseHintUsesSpecificWording() {
        let comparison = NightComparison(current: night(day: 2, score: 30, nose: 3), previous: night(day: 1, score: 10, nose: 0))
        let hint = ImpactHint.hints(for: comparison, history: []).first
        #expect(hint?.title == "Blocked nose")
        #expect(hint?.effect == .louder)
        #expect(hint?.detail == "A blocked nose often goes with louder snoring.")
    }

    // MARK: Weight and blood pressure

    private func reading(day: Int, _ kind: BodyValue.Kind, _ value: Double, _ second: Double? = nil) -> BodyValue {
        BodyValue(id: "\(day)-\(kind)-\(value)", date: date(day: day, hour: 7), kind: kind, value: value,
                  secondValue: second, source: "Test")
    }

    @Test func groupsNightsAndReadingsByWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2 // Monday. 2026-11-02 is a Monday.
        let nights = [
            night(day: 2, snoring: 3600, recorded: 8 * 3600),
            night(day: 3, snoring: 1800, recorded: 4 * 3600),
            night(day: 10, snoring: 0, recorded: 8 * 3600),
        ]
        let readings = [
            reading(day: 4, .weight, 80), reading(day: 5, .weight, 82),
            reading(day: 4, .bloodPressure, 130, 80), reading(day: 6, .bloodPressure, 120, 70),
            reading(day: 20, .weight, 79),
        ]
        let weeks = BodyTrends.weeks(nights: nights, readings: readings, calendar: calendar)
        #expect(weeks.count == 3)
        // 5400 s of snoring over 12 h.
        #expect(abs((weeks[0].snoringPercent ?? 0) - 12.5) < 0.0001)
        #expect(weeks[0].nightCount == 2)
        #expect(weeks[0].averageWeight == 81)
        #expect(weeks[0].averageSystolic == 125)
        #expect(weeks[0].averageDiastolic == 75)
        #expect(weeks[0].pressureReadingCount == 2)
        #expect(weeks[1].snoringPercent == 0)
        #expect(weeks[1].averageWeight == nil)
        // A week with readings but no nights.
        #expect(weeks[2].nightCount == 0)
        #expect(weeks[2].snoringPercent == nil)
        #expect(weeks[2].averageWeight == 79)
    }

    @Test func weightChangeIsLatestMinusEarliest() {
        let readings = [reading(day: 9, .weight, 81), reading(day: 1, .weight, 84), reading(day: 5, .bloodPressure, 120, 80)]
        let change = BodyTrends.weightChange(readings)
        #expect(change?.change == -3)
        #expect(change?.from == date(day: 1, hour: 7))
        #expect(BodyTrends.weightChange([reading(day: 1, .weight, 80)]) == nil)
    }

    @Test func reportKeepsReadingsInThePeriod() {
        let now = date(day: 20, hour: 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let report = DoctorReport(
            nights: [night(day: 18)],
            period: .week,
            readings: [reading(day: 1, .weight, 80), reading(day: 17, .bloodPressure, 128, 82), reading(day: 19, .weight, 79)],
            now: now,
            calendar: calendar
        )
        #expect(report.readings.map(\.value) == [128, 79])
        #expect(report.pressureReadings.first?.pressureText == "128/82")
        #expect(!report.bodyWeeks.isEmpty)
        #expect(DoctorReport(nights: [night(day: 18)], period: .week, now: now, calendar: calendar).bodyWeeks.isEmpty)
    }

    @Test func pdfIncludesReadingsWithoutCrashing() {
        let now = date(day: 20, hour: 12)
        let readings = (1...19).map { reading(day: $0, .bloodPressure, 120 + Double($0), 80) }
        let report = DoctorReport(nights: (10...19).map { night(day: $0) }, period: .month, readings: readings, now: now)
        let data = DoctorReportPDF.render(report)
        #expect(data.count > 1000)
    }

    // MARK: Wording

    @Test func generatedWordingAvoidsConditionNames() {
        let banned = ["apnea", "apnoea", "hypertension", "abnormal", "desaturation", "breathing pause", "ahi"]
        var texts: [String] = []
        texts += ImpactHint.addedNotes.values
        texts += ImpactHint.daytimeNotes.values
        texts += NoseLevel.allCases.map(\.title) + SleepPosition.allCases.map(\.title)
        let comparison = NightComparison(
            current: night(day: 2, score: 40, factors: ["Alcohol", "Drinks near bedtime"], nose: 2, position: .back,
                           weather: NightWeather(temperatureCelsius: 1, humidity: 0.9)),
            previous: night(day: 1, score: 10, position: .side)
        )
        texts += ImpactHint.hints(for: comparison, history: []).flatMap { [$0.title, $0.detail] }
        for text in texts {
            let lower = text.lowercased()
            let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
            for term in banned {
                let found = term.contains(" ") ? lower.contains(term) : words.contains(term)
                #expect(!found, "\"\(text)\" contains \"\(term)\"")
            }
        }
    }
}
