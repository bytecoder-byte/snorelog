import Foundation

// Pure logic with no Apple-framework dependencies besides Foundation, so it is easy to unit test.
//
// Weight and blood pressure change over weeks and months, not from one night to the next,
// so they are shown as slow trends next to a weekly snoring average. Values are shown as
// recorded: no categories, no target lines, no colors that suggest good or bad.

/// One weight or blood pressure reading, from Apple Health or typed in by the person.
struct BodyValue: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case weight
        case bloodPressure
    }

    var id: String
    var date: Date
    var kind: Kind
    /// Kilograms for weight, systolic mmHg for blood pressure.
    var value: Double
    /// Diastolic mmHg for blood pressure. Nil for weight.
    var secondValue: Double?
    /// Where it came from, for example "Withings" or "Entered by you".
    var source: String

    /// "128/82" style text for blood pressure.
    var pressureText: String {
        "\(Int(value.rounded()))/\(Int((secondValue ?? 0).rounded()))"
    }
}

/// A week of nights next to the weight and blood pressure readings from the same week.
struct BodyTrendWeek: Equatable, Identifiable {
    var weekStart: Date
    var nightCount: Int
    /// Total snoring divided by total recorded time that week. Nil without nights.
    var snoringPercent: Double?
    var averageWeight: Double?
    var averageSystolic: Double?
    var averageDiastolic: Double?
    var pressureReadingCount: Int

    var id: Date { weekStart }
    var isEmpty: Bool { nightCount == 0 && averageWeight == nil && averageSystolic == nil }
}

enum BodyTrends {
    /// Groups nights and readings into calendar weeks, oldest first. Weeks with nothing at all are left out.
    static func weeks(nights: [NightSnapshot], readings: [BodyValue], since start: Date? = nil,
                      calendar: Calendar = .current) -> [BodyTrendWeek] {
        func weekStart(_ date: Date) -> Date {
            calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }
        let nights = nights.filter { start == nil || $0.startDate >= start! }
        let readings = readings.filter { start == nil || $0.date >= start! }
        let nightsByWeek = Dictionary(grouping: nights) { weekStart($0.startDate) }
        let readingsByWeek = Dictionary(grouping: readings) { weekStart($0.date) }

        return Set(nightsByWeek.keys).union(readingsByWeek.keys).sorted().map { week in
            let weekNights = nightsByWeek[week] ?? []
            let weekReadings = readingsByWeek[week] ?? []
            let recorded = weekNights.map(\.recordedSeconds).reduce(0, +)
            let snoring = weekNights.map(\.snoringSeconds).reduce(0, +)
            let weights = weekReadings.filter { $0.kind == .weight }.map(\.value)
            let pressures = weekReadings.filter { $0.kind == .bloodPressure }
            return BodyTrendWeek(
                weekStart: week,
                nightCount: weekNights.count,
                snoringPercent: recorded > 0 ? snoring / recorded * 100 : nil,
                averageWeight: average(weights),
                averageSystolic: average(pressures.map(\.value)),
                averageDiastolic: average(pressures.compactMap(\.secondValue)),
                pressureReadingCount: pressures.count
            )
        }
    }

    /// Latest minus earliest weight in the readings, with the dates, or nil with fewer than 2 weights.
    static func weightChange(_ readings: [BodyValue]) -> (change: Double, from: Date, to: Date)? {
        let weights = readings.filter { $0.kind == .weight }.sorted { $0.date < $1.date }
        guard let first = weights.first, let last = weights.last, weights.count >= 2 else { return nil }
        return (last.value - first.value, first.date, last.date)
    }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
