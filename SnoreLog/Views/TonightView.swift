import AVFoundation
import SwiftData
import SwiftUI

struct TonightView: View {
    @Environment(NightRecorder.self) private var recorder
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.activeSessionID) private var activeSessionID = ""
    @AppStorage(SettingsKeys.useHealth) private var useHealth = false

    @State private var selectedFactors: Set<String> = []
    @State private var isAnalyzing = false
    @State private var progress: Double = 0
    @State private var finishedNight: SleepSession?
    @State private var errorMessage: String?
    @State private var showMicDenied = false
    @State private var isDimmed = false

    var body: some View {
        NavigationStack {
            Group {
                if isAnalyzing {
                    AnalyzingView(progress: progress)
                } else if recorder.state == .idle {
                    setup
                } else {
                    RecordingView(onStop: { Task { await stopAndAnalyze() } }, onDim: { isDimmed = true })
                }
            }
            .navigationTitle("Tonight")
            .navigationDestination(item: $finishedNight) { night in
                NightReportView(night: night)
            }
        }
        .fullScreenCover(isPresented: $isDimmed) {
            DimmedView { isDimmed = false }
        }
        .alert("Microphone access is off", isPresented: $showMicDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SnoreLog needs the microphone to hear snoring. Audio stays on your iPhone.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                FactorPicker(title: "Anything different tonight?", options: NightFactors.factors, selection: $selectedFactors)
                FactorPicker(title: "Trying a remedy?", options: NightFactors.remedies, selection: $selectedFactors)
                FactorPicker(
                    title: "How was your day?",
                    note: useHealth ? "Apple Health fills these in after the night. Tag anything it misses." : nil,
                    options: NightFactors.day,
                    selection: $selectedFactors
                )

                VStack(alignment: .leading, spacing: 8) {
                    Label("Put your phone on the nightstand, within about 1 m of your head.", systemImage: "iphone")
                    Label("Plug it in. A full night uses a lot of battery.", systemImage: "battery.100.bolt")
                    Label("You can lock the screen. Recording keeps going.", systemImage: "lock")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button {
                    Task { await start() }
                } label: {
                    Label("Start sleeping", systemImage: "moon.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            showMicDenied = true
            return
        }
        let night = SleepSession(factors: selectedFactors.sorted())
        context.insert(night)
        try? context.save()
        do {
            try recorder.start(in: night.folderURL)
            activeSessionID = night.id.uuidString
        } catch {
            context.delete(night)
            try? context.save()
            errorMessage = error.localizedDescription
        }
    }

    private func stopAndAnalyze() async {
        recorder.stop()
        guard let night = activeNight() else { return }
        activeSessionID = ""
        night.endDate = .now
        selectedFactors = []
        isAnalyzing = true
        progress = 0
        do {
            try await AnalysisService.analyze(night, in: context) { value in progress = value }
            finishedNight = night
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalyzing = false
    }

    private func activeNight() -> SleepSession? {
        guard let id = UUID(uuidString: activeSessionID) else { return nil }
        let descriptor = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}

// MARK: - Subviews

private struct RecordingView: View {
    @Environment(NightRecorder.self) private var recorder
    var onStop: () -> Void
    var onDim: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Text(Formatters.duration(recorder.recordedSeconds))
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()
            LevelMeter(level: recorder.currentLevel)
                .frame(height: 12)
                .padding(.horizontal, 40)
            if recorder.state == .interrupted {
                Label("Paused by another app. Recording resumes when it ends.", systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text("Listening. Sleep well.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dim screen", systemImage: "moon", action: onDim)
                .buttonStyle(.bordered)
            Button(action: onStop) {
                Text("I'm awake").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
        .padding(.bottom)
    }
}

struct LevelMeter: View {
    var level: Float

    var body: some View {
        // Map roughly -70...-10 dBFS onto 0...1.
        let fraction = CGFloat(min(1, max(0, (level + 70) / 60)))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: geo.size.width * fraction)
            }
        }
        .animation(.easeOut(duration: 0.3), value: fraction)
        .accessibilityLabel("Sound level")
    }
}

private struct AnalyzingView: View {
    var progress: Double

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress)
                .padding(.horizontal, 40)
            Text("Finding your snores…")
                .font(.headline)
            Text("This runs on your iPhone and can take a minute or two for a full night.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

private struct DimmedView: View {
    var onWake: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                TimelineView(.everyMinute) { context in
                    Text(context.date, style: .time)
                        .font(.system(size: 40, weight: .ultraLight, design: .rounded))
                }
                Text("Recording · tap to wake")
                    .font(.caption)
            }
            .foregroundStyle(.white.opacity(0.25))
        }
        .onTapGesture(perform: onWake)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

struct FactorPicker: View {
    var title: String
    var note: String? = nil
    var options: [String]
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let note {
                Label(note, systemImage: "heart.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let isOn = selection.contains(option)
                    Button {
                        if isOn { selection.remove(option) } else { selection.insert(option) }
                    } label: {
                        Text(option)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
