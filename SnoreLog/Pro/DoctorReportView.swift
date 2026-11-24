import PDFKit
import SwiftData
import SwiftUI

/// Builds the PDF report for a chosen period, shows a preview and shares it.
/// Needs SnoreLog Pro; shows the paywall otherwise.
struct DoctorReportView: View {
    @Environment(ProStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SleepSession.startDate, order: .reverse) private var nights: [SleepSession]
    @Query(sort: \BodyReading.date) private var readings: [BodyReading]
    @Environment(\.modelContext) private var context
    @State private var period: ReportPeriod = .month
    @State private var fileURL: URL?
    @State private var pdfData: Data?

    private var report: DoctorReport {
        DoctorReport(nights: nights.filter { $0.status == .done }.map(\.snapshot), period: period,
                     readings: readings.map(\.asValue))
    }

    var body: some View {
        if store.isPro {
            content
        } else {
            PaywallView(reason: "The PDF report for your doctor is part of SnoreLog Pro.")
        }
    }

    private var content: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Period", selection: $period) {
                    ForEach(ReportPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                if report.isEmpty {
                    ContentUnavailableView(
                        "No nights in this period",
                        systemImage: "doc.text",
                        description: Text("Analyzed nights show up here. Try a longer period.")
                    )
                } else if let pdfData {
                    PDFPreview(data: pdfData)
                        .background(Color(.secondarySystemBackground))
                }
                Spacer(minLength: 0)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let fileURL, !report.isEmpty {
                        ShareLink(item: fileURL) {
                            Label("Share PDF", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    Text("This report describes your recorded nights. It is not a diagnosis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("PDF report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: TaskKey(period: period, count: nights.count, readingCount: readings.count)) { generate() }
            .task { await HealthImporter.refreshBodyReadings(in: context) }
        }
    }

    private struct TaskKey: Equatable {
        var period: ReportPeriod
        var count: Int
        var readingCount: Int
    }

    private func generate() {
        let report = report
        guard !report.isEmpty else {
            pdfData = nil
            fileURL = nil
            return
        }
        let data = DoctorReportPDF.render(report)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(report.fileName)
        do {
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            fileURL = nil
        }
        pdfData = data

        // Screenshots: also save a copy CI can pull out of the simulator.
        if DemoData.screen == "pdf" {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? data.write(to: docs.appendingPathComponent("SnoreLog-report-demo.pdf"), options: .atomic)
        }
    }
}

private struct PDFPreview: UIViewRepresentable {
    var data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.shownData != data else { return }
        context.coordinator.shownData = data
        view.document = PDFDocument(data: data)
    }

    final class Coordinator {
        var shownData: Data?
    }
}
