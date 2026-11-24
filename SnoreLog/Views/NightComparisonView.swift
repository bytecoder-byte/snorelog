import SwiftData
import SwiftUI

/// "Compared with the night before": how the main numbers moved.
struct ComparisonSection: View {
    var comparison: NightComparison

    var body: some View {
        Section {
            verdictRow
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    Text("Before").gridColumnAlignment(.trailing)
                    Text("This night").gridColumnAlignment(.trailing)
                    Text("")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                MetricRow(
                    title: "Snore score",
                    before: "\(comparison.previous.score)",
                    after: "\(comparison.current.score)",
                    change: Double(comparison.scoreChange),
                    changeText: Self.signed(comparison.scoreChange)
                )
                MetricRow(
                    title: "Snoring",
                    before: Formatters.duration(comparison.previous.snoringSeconds),
                    after: Formatters.duration(comparison.current.snoringSeconds),
                    change: comparison.snoringChange,
                    changeText: (comparison.snoringChange >= 0 ? "+" : "−") + Formatters.duration(abs(comparison.snoringChange)),
                    threshold: 60
                )
                MetricRow(
                    title: "Of the night",
                    before: "\(Int(comparison.previous.snoringPercent.rounded()))%",
                    after: "\(Int(comparison.current.snoringPercent.rounded()))%",
                    change: comparison.percentChange,
                    changeText: Self.signed(Int(comparison.percentChange.rounded())) + "%",
                    threshold: 1
                )
                MetricRow(
                    title: "Loud episodes",
                    before: "\(comparison.previous.loudEpisodeCount)",
                    after: "\(comparison.current.loudEpisodeCount)",
                    change: Double(comparison.loudEpisodeChange),
                    changeText: Self.signed(comparison.loudEpisodeChange)
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text("Compared with \(previousName)")
        }
    }

    /// "Sunday" for a recent night, "12 Nov" for an older one.
    private var previousName: String {
        let gap = comparison.current.startDate.timeIntervalSince(comparison.previous.startDate)
        return gap < 6 * 86_400
            ? comparison.previous.startDate.formatted(.dateTime.weekday(.wide))
            : comparison.previous.startDate.formatted(.dateTime.day().month())
    }

    private var verdictRow: some View {
        let (text, symbol, color): (String, String, Color) = switch comparison.verdict {
        case .better: ("Quieter than the night before", "arrow.down.circle.fill", .green)
        case .worse: ("Louder than the night before", "arrow.up.circle.fill", .orange)
        case .similar: ("About the same as the night before", "equal.circle.fill", .secondary)
        }
        return Label {
            Text(text).font(.headline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : value < 0 ? "−\(abs(value))" : "0"
    }
}

private struct MetricRow: View {
    var title: String
    var before: String
    var after: String
    /// For every metric here, higher means more snoring.
    var change: Double
    var changeText: String
    /// Changes smaller than this are shown as no change.
    var threshold: Double = 1

    private var color: Color {
        if abs(change) < threshold { return .secondary }
        return change > 0 ? .orange : .green
    }

    var body: some View {
        GridRow {
            Text(title)
            Text(before)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(after)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(abs(change) < threshold ? "same" : changeText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
                .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(before) before, \(after) this night")
    }
}

/// "What could have made a difference": tags and timing that changed from the night before.
struct ImpactSection: View {
    var hints: [ImpactHint]
    var onEditTags: () -> Void

    var body: some View {
        Section {
            if hints.isEmpty {
                Text("Your tags and timing were the same as the night before. Some night-to-night change is normal.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(hints) { hint in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(for: hint.effect))
                        .font(.title3)
                        .foregroundStyle(color(for: hint.effect))
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(hint.title).font(.body.weight(.semibold))
                            if let badge = badge(for: hint.kind) {
                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            if hint.fromHealth {
                                Image(systemName: "heart.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.pink)
                                    .accessibilityLabel("From Apple Health")
                            }
                        }
                        Text(hint.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
            Button("Edit this night's tags", systemImage: "tag", action: onEditTags)
                .font(.subheadline)
        } header: {
            Text("What could have made a difference")
        } footer: {
            Text(hints.contains(where: \.fromHealth)
                 ? "Based on your tags, bedtime and Apple Health (marked with a heart). These are possible links, not proof. More nights show your own patterns."
                 : "Based on your tags and bedtime. These are possible links, not proof. Tag more nights to see your own patterns.")
        }
    }

    private func badge(for kind: ImpactHint.Kind) -> String? {
        switch kind {
        case .added: "New this night"
        case .removed: "Not this night"
        case .timing: nil
        }
    }

    private func icon(for effect: ImpactHint.Effect) -> String {
        switch effect {
        case .louder: "speaker.wave.3.fill"
        case .quieter: "speaker.wave.1.fill"
        case .unclear: "clock"
        }
    }

    private func color(for effect: ImpactHint.Effect) -> Color {
        switch effect {
        case .louder: .orange
        case .quieter: .green
        case .unclear: .secondary
        }
    }
}

/// Lets people fix a night's tags after the fact, since it's easy to forget at bedtime.
struct EditTagsSheet: View {
    @Bindable var night: SleepSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var selection: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    FactorPicker(title: "The day before", options: NightFactors.day, selection: $selection)
                    FactorPicker(title: "Anything different that night?", options: NightFactors.factors, selection: $selection)
                    FactorPicker(title: "Remedies tried", options: NightFactors.remedies, selection: $selection)
                }
                .padding()
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        night.factors = selection.sorted()
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { selection = Set(night.factors) }
        .presentationDetents([.medium, .large])
    }
}

/// "Your day": what Apple Health recorded for the day before this night, next to the day before that.
struct DaytimeSection: View {
    var current: DaytimeActivity?
    var previous: DaytimeActivity?
    /// Shown as the first column's heading, for example "Sunday".
    var previousName: String?

    private struct Row: Identifiable {
        var title: String
        var symbol: String
        var value: (DaytimeActivity) -> Double?
        var format: (Double) -> String
        var id: String { title }
    }

    private static let rows: [Row] = [
        Row(title: "Workouts", symbol: "figure.run", value: \.workoutMinutes, format: DaytimeActivity.minutes),
        Row(title: "Strength", symbol: "dumbbell.fill", value: \.strengthMinutes, format: DaytimeActivity.minutes),
        Row(title: "Steps", symbol: "shoeprints.fill", value: \.steps, format: DaytimeActivity.count),
        Row(title: "Water", symbol: "drop.fill", value: \.waterMilliliters, format: DaytimeActivity.liters),
        Row(title: "Caffeine", symbol: "cup.and.saucer.fill", value: \.caffeineMilligrams, format: { "\(Int($0.rounded())) mg" }),
        Row(title: "Alcohol", symbol: "wineglass.fill", value: \.alcoholicDrinks, format: { $0 == 1 ? "1 drink" : "\(DaytimeActivity.count($0)) drinks" }),
    ]

    private var visibleRows: [Row] {
        Self.rows.filter { row in
            [current, previous].contains { day in day.flatMap(row.value).map { $0 > 0 } ?? false }
        }
    }

    var body: some View {
        if !visibleRows.isEmpty {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    if let previousName {
                        GridRow {
                            Text("")
                            Text(previousName).gridColumnAlignment(.trailing)
                            Text("This day").gridColumnAlignment(.trailing)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(visibleRows) { row in
                        GridRow {
                            Label(row.title, systemImage: row.symbol)
                            if previousName != nil {
                                Text(text(for: row, in: previous))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .gridColumnAlignment(.trailing)
                            }
                            Text(text(for: row, in: current))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("Your day", systemImage: "heart.fill")
            } footer: {
                Text("From Apple Health, for the day before each night up to bedtime. A dash means nothing was logged.")
            }
        }
    }

    private func text(for row: Row, in day: DaytimeActivity?) -> String {
        guard let value = day.flatMap(row.value), value > 0 else { return "–" }
        return row.format(value)
    }
}
