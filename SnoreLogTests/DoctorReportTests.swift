import CoreGraphics
import Foundation
import Testing
@testable import SnoreLog

struct DoctorReportTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_795_000_000) // A fixed day in late 2026.

    private func night(daysAgo: Int, score: Int, snoring: TimeInterval = 1800, recorded: TimeInterval = 7 * 3600,
                       loud: Int = 0, factors: [String] = []) -> NightSnapshot {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
            .addingTimeInterval(23 * 3600)
        return NightSnapshot(startDate: start, recordedSeconds: recorded, snoringSeconds: snoring, score: score,
                             episodeCount: loud + 3, loudEpisodeCount: loud, factors: factors)
    }

    @Test func keepsOnlyNightsInThePeriodOldestFirst() {
        let nights = [night(daysAgo: 2, score: 10), night(daysAgo: 40, score: 50), night(daysAgo: 5, score: 20)]
        let report = DoctorReport(nights: nights, period: .week, now: now, calendar: calendar)
        #expect(report.nights.map(\.score) == [20, 10])
        #expect(DoctorReport(nights: nights, period: .all, now: now, calendar: calendar).nightCount == 3)
    }

    @Test func averagesAndCounts() {
        let nights = [
            night(daysAgo: 1, score: 5, snoring: 600, loud: 0),
            night(daysAgo: 2, score: 30, snoring: 3000, loud: 4),
            night(daysAgo: 3, score: 40, snoring: 2400, loud: 2),
        ]
        let report = DoctorReport(nights: nights, period: .month, now: now, calendar: calendar)
        #expect(report.averageScore == 25)
        #expect(report.averageSnoringSeconds == 2000)
        #expect(report.quietNightCount == 1)
        #expect(report.averageLoudEpisodes == 2)
        #expect(report.highestNight?.score == 40)
        // 6000 s of snoring over 21 h recorded.
        #expect(abs(report.snoringPercent - 6000.0 / (21 * 3600) * 100) < 0.0001)
    }

    @Test func trendNeedsFourNightsAndComparesHalves() {
        let three = (1...3).map { night(daysAgo: $0, score: 20) }
        #expect(DoctorReport(nights: three, period: .all, now: now, calendar: calendar).scoreTrend == nil)

        // Oldest two nights score 40, newest two score 20: the later half is 20 points lower.
        let four = [night(daysAgo: 4, score: 40), night(daysAgo: 3, score: 40),
                    night(daysAgo: 2, score: 20), night(daysAgo: 1, score: 20)]
        let report = DoctorReport(nights: four, period: .all, now: now, calendar: calendar)
        #expect(report.scoreTrend == -20)
        #expect(report.trendDescription?.hasPrefix("Lower") == true)
    }

    @Test func tagTableNeedsTwoNightsWithAndOneWithout() {
        let nights = [
            night(daysAgo: 1, score: 40, factors: ["Alcohol"]),
            night(daysAgo: 2, score: 50, factors: ["Alcohol", "Nasal strip"]),
            night(daysAgo: 3, score: 10),
        ]
        let report = DoctorReport(nights: nights, period: .all, now: now, calendar: calendar)
        #expect(report.tagImpacts.map(\.factor) == ["Alcohol"])
        #expect(report.tagImpacts.first?.difference == 35)
    }

    @Test func avoidsMedicalWording() {
        let nights = (1...6).map { night(daysAgo: $0, score: $0 * 10, factors: ["Alcohol"]) }
        let report = DoctorReport(nights: nights, period: .all, now: now, calendar: calendar)
        let text = [report.trendDescription ?? "", report.fileName].joined(separator: " ").lowercased()
        #expect(!text.contains("apnea"))
        #expect(!text.contains("diagnos"))
    }

    @Test func rendersAMultiPagePDFForManyNights() throws {
        let nights = (1...80).map { night(daysAgo: $0, score: ($0 * 7) % 70, loud: $0 % 4,
                                          factors: $0 % 3 == 0 ? ["Alcohol", "Slept on back"] : ["Nasal strip"]) }
        let report = DoctorReport(nights: nights, period: .quarter, now: now, calendar: calendar)
        let data = DoctorReportPDF.render(report)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages >= 2)
    }

    @Test func rendersAnEmptyReport() throws {
        let data = DoctorReportPDF.render(DoctorReport(nights: [], period: .week, now: now, calendar: calendar))
        let document = try #require(CGPDFDocument(try #require(CGDataProvider(data: data as CFData))))
        #expect(document.numberOfPages == 1)
    }
}
