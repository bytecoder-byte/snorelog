import Charts
import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SleepSession.startDate, order: .reverse) private var nights: [SleepSession]
    @State private var showingReport = false

    private var analyzed: [SleepSession] { nights.filter { $0.status == .done } }

    var body: some View {
        NavigationStack {
            List {
                if nights.isEmpty {
                    ContentUnavailableView(
                        "No nights yet",
                        systemImage: "moon.zzz",
                        description: Text("Start a recording from Tonight when you go to bed.")
                    )
                } else {
                    if analyzed.count >= 2 { trend }
                    impact
                    Section("Nights") {
                        ForEach(nights) { night in
                            NavigationLink(value: night) { NightRow(night: night) }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: SleepSession.self) { NightReportView(night: $0) }
            .toolbar {
                if !analyzed.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("PDF report", systemImage: "doc.richtext") { showingReport = true }
                    }
                }
            }
            .sheet(isPresented: $showingReport) { DoctorReportView() }
        }
    }

    private var trend: some View {
        let recent = Array(analyzed.prefix(30))
        let average = Double(recent.map(\.score).reduce(0, +)) / Double(recent.count)
        return Section {
            Chart {
                ForEach(recent) { night in
                    BarMark(
                        x: .value("Night", night.startDate, unit: .day),
                        y: .value("Score", night.score)
                    )
                    .foregroundStyle(.tint)
                }
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
            .chartYScale(domain: 0...max(20, recent.map(\.score).max() ?? 0))
            .frame(height: 160)
            .padding(.vertical, 8)
        } header: {
            Text("Snore score, last \(recent.count) nights")
        } footer: {
            Text("Average \(Int(average.rounded())).")
        }
    }

    @ViewBuilder
    private var impact: some View {
        let impacts = FactorImpact.compute(nights: analyzed.map { (factors: $0.allFactors, score: $0.score) })
            .filter { $0.averageWithout != nil && $0.nightsWith >= 2 }
        if !impacts.isEmpty {
            Section {
                ForEach(impacts) { item in
                    HStack {
                        Text(item.factor)
                        Spacer()
                        if let diff = item.difference {
                            Text(diff > 0 ? "+\(Int(diff.rounded()))" : "\(Int(diff.rounded()))")
                                .monospacedDigit()
                                .foregroundStyle(diff > 0 ? .red : .green)
                        }
                    }
                }
            } header: {
                Text("What seems to matter")
            } footer: {
                Text("Average snore score with each tag (yours, or from Apple Health) compared with nights without it. Shown once a tag is used on 2 or more nights. More nights give a clearer picture.")
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let night = nights[index]
            guard night.status != .recording else { continue } // Don't delete tonight's recording.
            SessionStorage.deleteFolder(for: night.id)
            context.delete(night)
        }
        try? context.save()
    }
}

private struct NightRow: View {
    var night: SleepSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(night.startDate.formatted(.dateTime.weekday(.abbreviated).day().month()))
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if night.status == .done {
                Text("\(night.score)")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var subtitle: String {
        switch night.status {
        case .done: "\(Formatters.duration(night.snoringSeconds)) snoring of \(Formatters.duration(night.recordedSeconds))"
        case .recording: "Recording"
        case .analyzing: "Analyzing"
        case .pendingAnalysis: "Ready to analyze"
        case .failed: "Analysis failed"
        }
    }
}
