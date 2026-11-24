import Charts
import SwiftData
import SwiftUI

struct NightReportView: View {
    @Bindable var night: SleepSession
    @Environment(\.modelContext) private var context
    @State private var player = ClipPlayer()
    @State private var isAnalyzing = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var isEditingTags = false
    @Query(sort: \SleepSession.startDate, order: .reverse) private var allNights: [SleepSession]

    private var analyzedNights: [SleepSession] { allNights.filter { $0.status == .done } }

    /// This night compared with the analyzed night before it, if there is one.
    private var comparison: NightComparison? {
        let current = night.snapshot
        guard let previous = NightComparison.previous(of: current, in: analyzedNights.map(\.snapshot)) else { return nil }
        return NightComparison(current: current, previous: previous)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                switch night.status {
                case .done:
                    summary
                    if let comparison {
                        ComparisonSection(comparison: comparison)
                        ImpactSection(
                            hints: ImpactHint.hints(
                                for: comparison,
                                history: analyzedNights.map { (factors: $0.factors, score: $0.score) }
                            ),
                            onEditTags: { isEditingTags = true }
                        )
                        .id("impact")
                    } else {
                        factors
                    }
                    chart
                    episodes
                    if night.score >= 40 { healthNote }
                case .pendingAnalysis, .failed, .recording, .analyzing:
                    pending
                }
            }
            .task {
                // Used for screenshots: scroll down to the comparison.
                if DemoData.screen == "compare" {
                    try? await Task.sleep(for: .milliseconds(600))
                    proxy.scrollTo("impact", anchor: .top)
                }
            }
        }
        .sheet(isPresented: $isEditingTags) { EditTagsSheet(night: night) }
        .navigationTitle(night.startDate.formatted(.dateTime.weekday(.wide).day().month()))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }

    // MARK: - Sections

    private var summary: some View {
        Section {
            HStack(spacing: 20) {
                ScoreRing(score: night.score)
                    .frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 10) {
                    Stat(title: "Snoring", value: Formatters.duration(night.snoringSeconds))
                    Stat(title: "Of the night", value: "\(Int(night.snoringPercent.rounded()))%")
                    Stat(title: "Recorded", value: Formatters.duration(night.recordedSeconds))
                }
            }
            .padding(.vertical, 8)
        } footer: {
            Text("Snore score combines how long and how loudly you snored. 0 is a quiet night.")
        }
    }

    private var chart: some View {
        Section("Through the night") {
            Chart {
                ForEach(Array(night.minuteLevels.enumerated()), id: \.offset) { item in
                    AreaMark(
                        x: .value("Time", night.startDate.addingTimeInterval(Double(item.offset) * 60)),
                        y: .value("Loudness", max(0, Double(item.element - night.noiseFloorDB)))
                    )
                    .foregroundStyle(.gray.opacity(0.35))
                    .interpolationMethod(.monotone)
                }
                ForEach(night.sortedEpisodes) { episode in
                    RectangleMark(
                        xStart: .value("Start", episode.startDate(in: night)),
                        xEnd: .value("End", episode.startDate(in: night).addingTimeInterval(max(episode.duration, 60))),
                        yStart: .value("Bottom", 0),
                        yEnd: .value("Top", max(1, Double(episode.peakDB - night.noiseFloorDB)))
                    )
                    .foregroundStyle(by: .value("Intensity", episode.intensity.title))
                }
            }
            .chartForegroundStyleScale([
                SnoreIntensity.quiet.title: Color.teal,
                SnoreIntensity.loud.title: Color.orange,
                SnoreIntensity.epic.title: Color.red,
            ])
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let db = value.as(Double.self) { Text("+\(Int(db)) dB") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .frame(height: 200)
            .padding(.vertical, 8)
        }
    }

    /// Shown when there is no earlier night to compare with.
    private var factors: some View {
        Section("Tagged") {
            if !night.factors.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(night.factors, id: \.self) { factor in
                        Text(factor)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            Button(night.factors.isEmpty ? "Add tags" : "Edit tags", systemImage: "tag") { isEditingTags = true }
                .font(.subheadline)
        }
    }

    private var episodes: some View {
        Section {
            if night.episodes.isEmpty {
                Label("No snoring found. Nice and quiet.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            ForEach(night.sortedEpisodes) { episode in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.startDate(in: night), style: .time)
                            .font(.headline)
                        Text("\(Formatters.duration(episode.duration)) · \(episode.intensity.title)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = episode.clipURL, FileManager.default.fileExists(atPath: url.path) {
                        Button {
                            player.toggle(url)
                        } label: {
                            Image(systemName: player.playingURL == url ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel(player.playingURL == url ? "Stop clip" : "Play clip")
                    }
                }
            }
        } header: {
            Text("Snoring episodes")
        } footer: {
            if !night.episodes.isEmpty {
                Text("Clips are kept for the \(min(30, night.episodes.count)) most notable episodes.")
            }
        }
    }

    private var healthNote: some View {
        Section {
            Label {
                Text("Loud, frequent snoring is common, but it can also be a sign of sleep apnea. If you gasp, stop breathing or feel very tired during the day, talk to a doctor.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "stethoscope")
            }
        }
    }

    private var pending: some View {
        Section {
            if isAnalyzing {
                ProgressView(value: progress) { Text("Finding your snores…") }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(night.status == .failed ? "Analysis didn't finish" : "This night hasn't been analyzed yet")
                        .font(.headline)
                    if let error = night.analysisError ?? errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Analyze now") {
                        Task { await analyze() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func analyze() async {
        isAnalyzing = true
        do {
            try await AnalysisService.analyze(night, in: context) { value in progress = value }
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalyzing = false
    }
}

struct ScoreRing: View {
    var score: Int

    private var color: Color {
        switch score {
        case ..<10: .green
        case ..<25: .teal
        case ..<50: .orange
        default: .red
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(max(score, 1)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("score")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Snore score \(score) out of 100")
    }
}

private struct Stat: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
