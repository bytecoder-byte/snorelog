import UIKit

/// Draws a `DoctorReport` as a US Letter PDF a person can share with a doctor.
enum DoctorReportPDF {
    static let pageSize = CGSize(width: 612, height: 792) // US Letter in points.

    static func render(_ report: DoctorReport) -> Data {
        // Lay out once to count pages, then again with "Page x of y" filled in.
        let pages = draw(report, totalPages: nil).pages
        return draw(report, totalPages: pages).data
    }

    private static func draw(_ report: DoctorReport, totalPages: Int?) -> (data: Data, pages: Int) {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Snoring summary",
            kCGPDFContextCreator as String: "SnoreLog",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        var pages = 0
        let data = renderer.pdfData { context in
            let writer = PageWriter(context: context, report: report, totalPages: totalPages)
            writer.drawDocument()
            pages = writer.page
        }
        return (data, pages)
    }
}

// MARK: - Layout

private final class PageWriter {
    let context: UIGraphicsPDFRendererContext
    let report: DoctorReport
    let totalPages: Int?

    let margin: CGFloat = 48
    var width: CGFloat { DoctorReportPDF.pageSize.width - margin * 2 }
    var bottom: CGFloat { DoctorReportPDF.pageSize.height - 70 } // Leaves room for the footer.
    var y: CGFloat = 0
    var page = 0

    let accent = UIColor(red: 0.13, green: 0.55, blue: 0.60, alpha: 1)
    let ink = UIColor(white: 0.1, alpha: 1)
    let muted = UIColor(white: 0.42, alpha: 1)
    let rule = UIColor(white: 0.85, alpha: 1)
    let fill = UIColor(white: 0.96, alpha: 1)

    init(context: UIGraphicsPDFRendererContext, report: DoctorReport, totalPages: Int?) {
        self.context = context
        self.report = report
        self.totalPages = totalPages
    }

    func drawDocument() {
        newPage()
        header()
        if report.isEmpty {
            paragraph("No analyzed nights in this period.", font: .systemFont(ofSize: 12), color: muted)
            return
        }
        keyNumbers()
        scoreChart()
        tagTable()
        nightlyLog()
        howToRead()
    }

    // MARK: Pages

    func newPage() {
        context.beginPage()
        page += 1
        y = margin
        footer()
    }

    /// Starts a new page if `height` won't fit on this one. Returns true if it did.
    @discardableResult
    func ensureSpace(_ height: CGFloat) -> Bool {
        guard y + height > bottom else { return false }
        newPage()
        return true
    }

    func footer() {
        let disclaimer = "SnoreLog is a wellness app, not a medical device. It does not diagnose, treat or rule out any condition. Snoring is found by on-device sound recognition and can be affected by room noise, a bed partner or pets."
        let footerTop = DoctorReportPDF.pageSize.height - 58
        let line = UIBezierPath()
        line.move(to: CGPoint(x: margin, y: footerTop - 8))
        line.addLine(to: CGPoint(x: margin + width, y: footerTop - 8))
        rule.setStroke()
        line.lineWidth = 0.5
        line.stroke()

        let pageText = totalPages.map { "Page \(page) of \($0)" } ?? "Page \(page)"
        let pageWidth: CGFloat = 70
        draw(disclaimer, font: .systemFont(ofSize: 7.5), color: muted,
             in: CGRect(x: margin, y: footerTop, width: width - pageWidth - 12, height: 40))
        draw(pageText, font: .systemFont(ofSize: 8), color: muted,
             in: CGRect(x: margin + width - pageWidth, y: footerTop, width: pageWidth, height: 12), alignment: .right)
    }

    // MARK: Sections

    func header() {
        draw("SnoreLog", font: .systemFont(ofSize: 10, weight: .semibold), color: accent,
             in: CGRect(x: margin, y: y, width: width, height: 14))
        y += 16
        paragraph("Snoring summary", font: .systemFont(ofSize: 24, weight: .bold), color: ink)
        y += 2

        var subtitle = "\(report.nightCount) \(report.nightCount == 1 ? "night" : "nights") recorded"
        if let first = report.firstNight, let last = report.lastNight {
            subtitle += ", \(dateRange(first, last))"
        }
        subtitle += ". Created \(report.generatedAt.formatted(date: .long, time: .omitted))."
        paragraph(subtitle, font: .systemFont(ofSize: 11), color: muted)
        y += 10

        // Blank lines the person can fill in before handing it over.
        let fieldWidth = (width - 24) / 2
        for (index, label) in ["Name", "Date of birth"].enumerated() {
            let x = margin + CGFloat(index) * (fieldWidth + 24)
            draw(label, font: .systemFont(ofSize: 9), color: muted, in: CGRect(x: x, y: y, width: 80, height: 12))
            let line = UIBezierPath()
            line.move(to: CGPoint(x: x + 70, y: y + 11))
            line.addLine(to: CGPoint(x: x + fieldWidth, y: y + 11))
            line.lineWidth = 0.5
            rule.setStroke()
            line.stroke()
        }
        y += 28
    }

    func keyNumbers() {
        sectionTitle("Overview")
        let highest = report.highestNight
        let tiles: [(String, String)] = [
            ("\(Int(report.averageScore.rounded()))", "Average snore score (0 to 100)"),
            (Formatters.duration(report.averageSnoringSeconds), "Average snoring per night"),
            (String(format: "%.0f%%", report.snoringPercent), "Of recorded time spent snoring"),
            (Formatters.duration(report.averageRecordedSeconds), "Average time recorded per night"),
            ("\(report.quietNightCount) of \(report.nightCount)", "Quiet nights (score under \(DoctorReport.quietScore))"),
            (String(format: "%.1f", report.averageLoudEpisodes), "Loud or very loud episodes per night"),
            (highest.map { "\($0.score)" } ?? "-", highest.map { "Highest score, \(shortDate($0.startDate))" } ?? "Highest score"),
            (report.scoreTrend.map { trendArrow($0) } ?? "-", "Score trend over the period"),
        ]
        let columns = 4
        let gap: CGFloat = 10
        let tileWidth = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let tileHeight: CGFloat = 58
        for (index, tile) in tiles.enumerated() {
            let row = index / columns
            let column = index % columns
            let rect = CGRect(x: margin + CGFloat(column) * (tileWidth + gap),
                              y: y + CGFloat(row) * (tileHeight + gap),
                              width: tileWidth, height: tileHeight)
            fill.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
            draw(tile.0, font: .monospacedDigitSystemFont(ofSize: 18, weight: .semibold), color: ink,
                 in: rect.insetBy(dx: 10, dy: 8))
            draw(tile.1, font: .systemFont(ofSize: 8.5), color: muted,
                 in: CGRect(x: rect.minX + 10, y: rect.minY + 32, width: rect.width - 20, height: 24))
        }
        y += CGFloat((tiles.count + columns - 1) / columns) * (tileHeight + gap)
        if let trend = report.trendDescription {
            paragraph("Snore score trend: \(trend)", font: .systemFont(ofSize: 10), color: muted)
        }
        y += 10
    }

    func scoreChart() {
        let chartHeight: CGFloat = 140
        ensureSpace(chartHeight + 60)
        sectionTitle("Snore score by night")

        let labelWidth: CGFloat = 26
        let plot = CGRect(x: margin + labelWidth, y: y + 6, width: width - labelWidth, height: chartHeight)
        let maxScore = max(20, report.nights.map(\.score).max() ?? 0)
        let top = CGFloat(min(100, ((maxScore + 9) / 10) * 10))

        // Grid lines and labels.
        let steps = 5 // top is a multiple of 10, so labels stay whole numbers.
        for step in 0...steps {
            let value = top * CGFloat(step) / CGFloat(steps)
            let lineY = plot.maxY - plot.height * value / top
            let line = UIBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: lineY))
            line.addLine(to: CGPoint(x: plot.maxX, y: lineY))
            line.lineWidth = 0.5
            rule.setStroke()
            line.stroke()
            draw("\(Int(value))", font: .systemFont(ofSize: 7.5), color: muted,
                 in: CGRect(x: margin, y: lineY - 5, width: labelWidth - 6, height: 10), alignment: .right)
        }

        // One bar per night.
        let count = report.nights.count
        let slot = plot.width / CGFloat(count)
        let barWidth = max(1.5, min(18, slot * 0.7))
        for (index, night) in report.nights.enumerated() {
            let height = max(1, plot.height * CGFloat(night.score) / top)
            let rect = CGRect(x: plot.minX + slot * CGFloat(index) + (slot - barWidth) / 2,
                              y: plot.maxY - height, width: barWidth, height: height)
            scoreColor(night.score).setFill()
            UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight],
                         cornerRadii: CGSize(width: min(2, barWidth / 2), height: 2)).fill()
        }

        // Average line.
        let averageY = plot.maxY - plot.height * CGFloat(report.averageScore) / top
        let average = UIBezierPath()
        average.move(to: CGPoint(x: plot.minX, y: averageY))
        average.addLine(to: CGPoint(x: plot.maxX, y: averageY))
        average.lineWidth = 1
        average.setLineDash([4, 3], count: 2, phase: 0)
        muted.setStroke()
        average.stroke()

        // Date labels: first, middle and last night.
        let labelIndexes = Array(Set([0, count / 2, count - 1])).sorted()
        for index in labelIndexes {
            let centerX = plot.minX + slot * (CGFloat(index) + 0.5)
            let rect = CGRect(x: min(max(margin, centerX - 40), margin + width - 80), y: plot.maxY + 4, width: 80, height: 12)
            draw(shortDate(report.nights[index].startDate), font: .systemFont(ofSize: 7.5), color: muted,
                 in: rect, alignment: .center)
        }
        y = plot.maxY + 20
        paragraph("Dashed line: average score. Green under 10, teal under 25, orange under 50, red 50 and above.",
                  font: .systemFont(ofSize: 8.5), color: muted)
        y += 12
    }

    func tagTable() {
        let impacts = report.tagImpacts
        guard !impacts.isEmpty else { return }
        ensureSpace(80)
        sectionTitle("Tags and average snore score")
        paragraph("Tags chosen before sleeping, plus any read from Apple Health. These show associations in their own nights, not causes.",
                  font: .systemFont(ofSize: 9), color: muted)
        y += 6

        let columns: [(String, CGFloat, NSTextAlignment)] = [
            ("Tag", 0.34, .left), ("Nights", 0.14, .right), ("With tag", 0.17, .right),
            ("Without", 0.17, .right), ("Difference", 0.18, .right),
        ]
        let rows = impacts.map { item -> [String] in
            let diff = item.difference ?? 0
            let diffText = diff > 0 ? "+\(Int(diff.rounded()))" : "\(Int(diff.rounded()))"
            return [item.factor, "\(item.nightsWith)", "\(Int(item.averageWith.rounded()))",
                    "\(Int((item.averageWithout ?? 0).rounded()))", diffText]
        }
        table(columns: columns, rows: rows)
        y += 14
    }

    func nightlyLog() {
        ensureSpace(80)
        sectionTitle("Night by night")
        let columns: [(String, CGFloat, NSTextAlignment)] = [
            ("Night of", 0.15, .left), ("Bedtime", 0.10, .left), ("Recorded", 0.11, .right),
            ("Snoring", 0.10, .right), ("Share", 0.08, .right), ("Score", 0.08, .right),
            ("Loud", 0.07, .right), ("Tags", 0.31, .left),
        ]
        // Newest first, the way people usually read a log.
        let rows = report.nights.reversed().map { night -> [String] in
            [
                night.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                night.startDate.formatted(date: .omitted, time: .shortened),
                Formatters.duration(night.recordedSeconds),
                Formatters.duration(night.snoringSeconds),
                String(format: "%.0f%%", night.snoringPercent),
                "\(night.score)",
                "\(night.loudEpisodeCount)",
                night.allFactors.isEmpty ? "-" : night.allFactors.joined(separator: ", "),
            ]
        }
        table(columns: columns, rows: rows)
        y += 14
    }

    func howToRead() {
        let text = """
        Snore score: the share of the recorded night spent snoring, weighted by loudness, from 0 (quiet) to 100. \
        Snoring: total time in snoring episodes. Share: snoring time divided by time recorded. \
        Loud: episodes at least 12 dB above the room's background noise.
        """
        ensureSpace(70)
        sectionTitle("How to read this")
        paragraph(text, font: .systemFont(ofSize: 9), color: muted)
    }

    // MARK: Building blocks

    func sectionTitle(_ text: String) {
        ensureSpace(30)
        paragraph(text, font: .systemFont(ofSize: 13, weight: .semibold), color: ink)
        y += 4
    }

    func table(columns: [(String, CGFloat, NSTextAlignment)], rows: [[String]]) {
        let font = UIFont.systemFont(ofSize: 8.5)
        let headerFont = UIFont.systemFont(ofSize: 8, weight: .semibold)
        let padding: CGFloat = 4
        let widths = columns.map { width * $0.1 }

        func header() {
            var x = margin
            for (index, column) in columns.enumerated() {
                draw(column.0.uppercased(), font: headerFont, color: muted,
                     in: CGRect(x: x + padding, y: y, width: widths[index] - padding * 2, height: 12), alignment: column.2)
                x += widths[index]
            }
            y += 14
            hairline()
        }

        header()
        for (rowIndex, row) in rows.enumerated() {
            let heights = row.enumerated().map { index, text in
                height(of: text, font: font, width: widths[index] - padding * 2)
            }
            let rowHeight = (heights.max() ?? 10) + 7
            if ensureSpace(rowHeight) { header() }
            if rowIndex.isMultiple(of: 2) {
                fill.setFill()
                UIBezierPath(rect: CGRect(x: margin, y: y, width: width, height: rowHeight)).fill()
            }
            var x = margin
            for (index, text) in row.enumerated() {
                draw(text, font: font, color: ink,
                     in: CGRect(x: x + padding, y: y + 3.5, width: widths[index] - padding * 2, height: rowHeight),
                     alignment: columns[index].2)
                x += widths[index]
            }
            y += rowHeight
        }
        hairline()
    }

    func hairline() {
        let line = UIBezierPath()
        line.move(to: CGPoint(x: margin, y: y))
        line.addLine(to: CGPoint(x: margin + width, y: y))
        line.lineWidth = 0.5
        rule.setStroke()
        line.stroke()
    }

    /// Draws wrapped text at the current position and moves down past it.
    func paragraph(_ text: String, font: UIFont, color: UIColor) {
        let textHeight = height(of: text, font: font, width: width)
        ensureSpace(textHeight)
        draw(text, font: font, color: color, in: CGRect(x: margin, y: y, width: width, height: textHeight + 2))
        y += textHeight + 4
    }

    func attributes(font: UIFont, color: UIColor, alignment: NSTextAlignment = .left) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    func height(of text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font: font, color: ink), context: nil)
        return ceil(rect.height)
    }

    func draw(_ text: String, font: UIFont, color: UIColor, in rect: CGRect, alignment: NSTextAlignment = .left) {
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes(font: font, color: color, alignment: alignment), context: nil)
    }

    // MARK: Formatting

    func scoreColor(_ score: Int) -> UIColor {
        switch score {
        case ..<10: UIColor(red: 0.20, green: 0.66, blue: 0.33, alpha: 1)
        case ..<25: UIColor(red: 0.19, green: 0.62, blue: 0.66, alpha: 1)
        case ..<50: UIColor(red: 0.95, green: 0.58, blue: 0.13, alpha: 1)
        default: UIColor(red: 0.86, green: 0.25, blue: 0.22, alpha: 1)
        }
    }

    func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    func dateRange(_ first: Date, _ last: Date) -> String {
        let format = Date.FormatStyle().month(.abbreviated).day().year()
        return Calendar.current.isDate(first, inSameDayAs: last)
            ? first.formatted(format)
            : "\(first.formatted(format)) to \(last.formatted(format))"
    }

    func trendArrow(_ trend: Double) -> String {
        let points = Int(trend.rounded())
        if abs(points) < NightComparison.similarScoreRange { return "Steady" }
        return points < 0 ? "Down \(-points)" : "Up \(points)"
    }
}
