import Charts
import SwiftData
import SwiftUI

/// Weekly snoring next to weight and blood pressure, over weeks and months. Needs SnoreLog Pro.
///
/// Wording and design rule: show readings as recorded, credited to where they came from.
/// No categories, no target lines and no good/bad colors.
struct BodyTrendsView: View {
    @Environment(ProStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \SleepSession.startDate) private var sessions: [SleepSession]
    @Query(sort: \BodyReading.date, order: .reverse) private var readings: [BodyReading]
    @AppStorage(SettingsKeys.useHealth) private var useHealth = false
    @State private var days = 90
    @State private var addingKind: BodyValue.Kind?

    private var start: Date { Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now }
    private var nights: [NightSnapshot] { sessions.filter { $0.status == .done }.map(\.snapshot) }
    private var values: [BodyValue] { readings.map(\.asValue).filter { $0.date >= start } }
    private var weeks: [BodyTrendWeek] { BodyTrends.weeks(nights: nights, readings: values, since: start) }
    private var weights: [BodyValue] { values.filter { $0.kind == .weight }.sorted { $0.date < $1.date } }
    private var pressures: [BodyValue] { values.filter { $0.kind == .bloodPressure }.sorted { $0.date < $1.date } }

    var body: some View {
        if store.isPro {
            content
        } else {
            PaywallView(reason: "Weight and blood pressure trends are part of SnoreLog Pro.")
        }
    }

    private var content: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $days) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                snoringSection
                weightSection
                pressureSection
                readingsSection
                Section {
                    Text("SnoreLog doesn't measure weight or blood pressure. These come from your scale or cuff through Apple Health, or from what you type in, and are shown as recorded. Snoring tends to change over weeks and months along with weight, so slow trends say more than single nights. In one large study, people who snored more often tended to have higher blood pressure. If you're concerned about your snoring or sleep, talking to a healthcare professional may be helpful.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About these charts")
                }
            }
            .navigationTitle("Weight & blood pressure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Weight", systemImage: "scalemass") { addingKind = .weight }
                        Button("Blood pressure", systemImage: "heart.text.square") { addingKind = .bloodPressure }
                    } label: {
                        Label("Add reading", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $addingKind) { kind in AddReadingSheet(kind: kind) }
            .task { await HealthImporter.refreshBodyReadings(in: context) }
        }
    }

    // MARK: - Sections

    private var snoringSection: some View {
        let points = weeks.filter { $0.snoringPercent != nil }
        return Section {
            if points.isEmpty {
                Text("No analyzed nights in this period.").foregroundStyle(.secondary)
            } else {
                Chart(points) { week in
                    BarMark(x: .value("Week", week.weekStart, unit: .weekOfYear),
                            y: .value("Snoring", week.snoringPercent ?? 0))
                        .foregroundStyle(.tint)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let percent = value.as(Double.self) { Text("\(Int(percent))%") } }
                    }
                }
                .chartXScale(domain: start...Date.now)
                .frame(height: 150)
                .padding(.vertical, 6)
            }
        } header: {
            Text("Share of the night snoring, by week")
        } footer: {
            Text("Total snoring time divided by time recorded, for each week.")
        }
    }

    private var weightSection: some View {
        Section {
            if weights.isEmpty {
                emptyText("weight")
            } else {
                Chart(weights) { reading in
                    LineMark(x: .value("Date", reading.date), y: .value("Weight", displayWeight(reading.value)))
                        .foregroundStyle(.gray)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", reading.date), y: .value("Weight", displayWeight(reading.value)))
                        .foregroundStyle(.gray)
                        .symbolSize(18)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXScale(domain: start...Date.now)
                .frame(height: 150)
                .padding(.vertical, 6)
            }
        } header: {
            Text("Weight (\(Self.usesPounds ? "lb" : "kg"))")
        } footer: {
            if let change = BodyTrends.weightChange(weights) {
                Text("\(BodyFormat.weight(abs(change.change), signed: change.change)) from \(change.from.formatted(.dateTime.month(.abbreviated).day())) to \(change.to.formatted(.dateTime.month(.abbreviated).day())).")
            }
        }
    }

    private var pressureSection: some View {
        Section {
            if pressures.isEmpty {
                emptyText("blood pressure")
            } else {
                Chart {
                    ForEach(pressures) { reading in
                        LineMark(x: .value("Date", reading.date), y: .value("mmHg", reading.value), series: .value("Reading", "Systolic"))
                            .foregroundStyle(by: .value("Reading", "Systolic"))
                        PointMark(x: .value("Date", reading.date), y: .value("mmHg", reading.value))
                            .foregroundStyle(by: .value("Reading", "Systolic"))
                            .symbolSize(18)
                        if let diastolic = reading.secondValue {
                            LineMark(x: .value("Date", reading.date), y: .value("mmHg", diastolic), series: .value("Reading", "Diastolic"))
                                .foregroundStyle(by: .value("Reading", "Diastolic"))
                            PointMark(x: .value("Date", reading.date), y: .value("mmHg", diastolic))
                                .foregroundStyle(by: .value("Reading", "Diastolic"))
                                .symbolSize(18)
                        }
                    }
                }
                // Neutral colors on purpose: no reading is marked as good or bad.
                .chartForegroundStyleScale(["Systolic": Color.indigo, "Diastolic": Color.gray])
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXScale(domain: start...Date.now)
                .frame(height: 170)
                .padding(.vertical, 6)
            }
        } header: {
            Text("Blood pressure (mmHg)")
        } footer: {
            if let latest = pressures.last {
                Text("Latest: \(latest.pressureText) on \(latest.date.formatted(.dateTime.month(.abbreviated).day())). \(pressures.count) \(pressures.count == 1 ? "reading" : "readings") in this period.")
            }
        }
    }

    private var readingsSection: some View {
        let recent = readings.filter { $0.date >= start }.prefix(30)
        return Section("Readings") {
            if recent.isEmpty {
                Text("No readings yet. Tap + to add one.").foregroundStyle(.secondary)
            }
            ForEach(Array(recent)) { reading in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.kind == .weight ? BodyFormat.weight(reading.value) : "\(reading.asValue.pressureText) mmHg")
                            .monospacedDigit()
                        Text(reading.sourceText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(reading.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .deleteDisabled(reading.fromHealth)
            }
            .onDelete { offsets in
                let items = Array(recent)
                for index in offsets where !items[index].fromHealth { context.delete(items[index]) }
                try? context.save()
            }
        }
    }

    private func emptyText(_ name: String) -> some View {
        Text(useHealth
             ? "No \(name) readings in this period. Apple Health shows nothing here when there's no supported device or permission isn't given."
             : "No \(name) readings in this period. Tap + to add one, or turn on Apple Health in Settings.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    static var usesPounds: Bool { Locale.current.measurementSystem == .us }

    private func displayWeight(_ kilograms: Double) -> Double {
        Self.usesPounds ? Measurement(value: kilograms, unit: UnitMass.kilograms).converted(to: .pounds).value : kilograms
    }
}

extension BodyValue.Kind: Identifiable {
    var id: String { rawValue }
}

enum BodyFormat {
    /// "72.4 kg" or "159.6 lb", following the person's region. `signed` adds "+" or "−" from its sign.
    static func weight(_ kilograms: Double, signed: Double? = nil) -> String {
        let text = Measurement(value: kilograms, unit: UnitMass.kilograms)
            .formatted(.measurement(width: .abbreviated, usage: .personWeight, numberFormatStyle: .number.precision(.fractionLength(1))))
        guard let signed else { return text }
        return (signed >= 0 ? "+" : "−") + text
    }
}

/// Type in a weight or blood pressure reading.
private struct AddReadingSheet: View {
    var kind: BodyValue.Kind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var date = Date.now
    @State private var weight: Double?
    @State private var systolic: Int?
    @State private var diastolic: Int?

    private var isValid: Bool {
        switch kind {
        case .weight: (weight ?? 0) > 0
        case .bloodPressure: (systolic ?? 0) > 0 && (diastolic ?? 0) > 0
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch kind {
                    case .weight:
                        LabeledContent("Weight (\(BodyTrendsView.usesPounds ? "lb" : "kg"))") {
                            TextField("0", value: $weight, format: .number.precision(.fractionLength(0...1)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    case .bloodPressure:
                        LabeledContent("Systolic (top)") {
                            TextField("mmHg", value: $systolic, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Diastolic (bottom)") {
                            TextField("mmHg", value: $diastolic, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    DatePicker("Taken", selection: $date, in: ...Date.now)
                } footer: {
                    Text(kind == .weight
                         ? "Saved in SnoreLog only, not in Apple Health."
                         : "From your home cuff. Saved in SnoreLog only, not in Apple Health.")
                }
            }
            .navigationTitle(kind == .weight ? "Add weight" : "Add blood pressure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        switch kind {
        case .weight:
            guard let weight else { return }
            let kilograms = BodyTrendsView.usesPounds
                ? Measurement(value: weight, unit: UnitMass.pounds).converted(to: .kilograms).value
                : weight
            context.insert(BodyReading(date: date, kind: .weight, value: kilograms, fromHealth: false))
        case .bloodPressure:
            guard let systolic, let diastolic else { return }
            context.insert(BodyReading(date: date, kind: .bloodPressure, value: Double(systolic),
                                       secondValue: Double(diastolic), fromHealth: false))
        }
        try? context.save()
        dismiss()
    }
}
