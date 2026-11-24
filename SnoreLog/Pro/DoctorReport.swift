import Foundation

// Pure logic with no Apple-framework dependencies besides Foundation, so it is easy to unit test.
// The PDF drawing lives in DoctorReportPDF.swift.

/// How far back the doctor report looks.
enum ReportPeriod: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90
    case all = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .all: "All"
        }
    }
}

/// The numbers that go into the shareable PDF report, worked out from analyzed nights.
/// Wording stays descriptive: it reports what was recorded and never suggests a diagnosis.
struct DoctorReport: Equatable {
    /// Nights in the period, oldest first.
    var nights: [NightSnapshot]
    var period: ReportPeriod
    var generatedAt: Date

    /// A score under this counts as a quiet night. Matches the green band of the score ring.
    static let quietScore = 10

    init(nights: [NightSnapshot], period: ReportPeriod, now: Date = .now, calendar: Calendar = .current) {
        let sorted = nights.sorted { $0.startDate < $1.startDate }
        if period == .all {
            self.nights = sorted
        } else {
            let start = calendar.date(byAdding: .day, value: -period.rawValue, to: calendar.startOfDay(for: now)) ?? now
            self.nights = sorted.filter { $0.startDate >= start }
        }
        self.period = period
        self.generatedAt = now
    }

    var isEmpty: Bool { nights.isEmpty }
    var nightCount: Int { nights.count }
    var firstNight: Date? { nights.first?.startDate }
    var lastNight: Date? { nights.last?.startDate }

    private func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    var averageScore: Double { average(nights.map { Double($0.score) }) }
    var averageSnoringSeconds: TimeInterval { average(nights.map(\.snoringSeconds)) }
    var averageRecordedSeconds: TimeInterval { average(nights.map(\.recordedSeconds)) }
    /// Total snoring divided by total recorded time, so short nights don't count as much as long ones.
    var snoringPercent: Double {
        let recorded = nights.map(\.recordedSeconds).reduce(0, +)
        return recorded > 0 ? nights.map(\.snoringSeconds).reduce(0, +) / recorded * 100 : 0
    }
    var averageLoudEpisodes: Double { average(nights.map { Double($0.loudEpisodeCount) }) }
    var quietNightCount: Int { nights.filter { $0.score < Self.quietScore }.count }
    /// The night with the highest score. The earliest one wins a tie.
    var highestNight: NightSnapshot? {
        nights.reduce(nil) { best, night in
            guard let best else { return night }
            return night.score > best.score ? night : best
        }
    }

    /// Average score of the later half of the period minus the earlier half.
    /// Nil with fewer than 4 nights, where a trend would mean little.
    var scoreTrend: Double? {
        guard nights.count >= 4 else { return nil }
        let half = nights.count / 2
        let early = nights.prefix(half).map { Double($0.score) }
        let late = nights.suffix(nights.count - half).map { Double($0.score) }
        return average(late) - average(early)
    }

    /// Plain-language description of `scoreTrend`.
    var trendDescription: String? {
        guard let trend = scoreTrend else { return nil }
        let points = Int(abs(trend).rounded())
        if points < NightComparison.similarScoreRange { return "About the same through the period." }
        return trend < 0
            ? "Lower in the second half of the period, by \(points) points on average."
            : "Higher in the second half of the period, by \(points) points on average."
    }

    /// Tags used on at least 2 nights, with at least 1 night without them to compare against.
    var tagImpacts: [FactorImpact] {
        FactorImpact.compute(nights: nights.map { (factors: $0.allFactors, score: $0.score) })
            .filter { $0.nightsWith >= 2 && $0.averageWithout != nil }
    }

    /// Suggested file name, for example "SnoreLog report 2026-11-24.pdf".
    var fileName: String {
        let day = generatedAt.formatted(.iso8601.year().month().day())
        return "SnoreLog report \(day).pdf"
    }
}
