import SwiftData
import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.sensitivity) private var sensitivity: Sensitivity = .medium
    @AppStorage(SettingsKeys.keepFullRecordings) private var keepFullRecordings = false
    @AppStorage(SettingsKeys.useHealth) private var useHealth = false
    @AppStorage(SettingsKeys.autoWeather) private var autoWeather = false
    @State private var healthError: String?
    @State private var weatherError: String?
    @State private var storageText = ""
    @State private var confirmDeleteAll = false
    @Environment(ProStore.self) private var store
    @State private var showingPaywall = false
    @State private var showingReport = false
    @State private var showingTrends = false
    @State private var showingManageSubscriptions = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                proSection

                Section {
                    Picker("Sensitivity", selection: $sensitivity) {
                        ForEach(Sensitivity.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Detection")
                } footer: {
                    Text(sensitivity.detail + " Applies to nights analyzed from now on.")
                }

                if HealthImporter.isAvailable {
                    Section {
                        Toggle(isOn: Binding(get: { useHealth }, set: setUseHealth)) {
                            Label {
                                Text("Use Apple Health")
                            } icon: {
                                Image(systemName: "heart.fill").foregroundStyle(.pink)
                            }
                        }
                        if let healthError {
                            Text(healthError).font(.footnote).foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Your day")
                    } footer: {
                        Text("Reads workouts, strength training, steps, water, caffeine, alcohol and sinus congestion from the day before each night, so reports can show what might have made a difference. With Pro it also reads weight and blood pressure from your scale or cuff. SnoreLog only reads from Health, never writes to it, and the data stays on your iPhone. Choose what it can read in the Health app. Without Health, you can tag your day by hand.")
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { autoWeather }, set: setAutoWeather)) {
                        Label {
                            Text("Automatic weather")
                        } icon: {
                            Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor)
                        }
                    }
                    if let weatherError {
                        Text(weatherError).font(.footnote).foregroundStyle(.orange)
                    }
                    if autoWeather { WeatherAttributionView() }
                } header: {
                    Text("Weather")
                } footer: {
                    Text("Notes the outdoor temperature and humidity when you start a night, so you can see patterns across your own nights. Your approximate location (rounded to about 1 km) is sent to Apple Weather when you start a night. It is not stored.")
                }

                Section {
                    Toggle("Keep full recordings", isOn: $keepFullRecordings)
                    LabeledContent("Storage used", value: storageText)
                } header: {
                    Text("Recordings")
                } footer: {
                    Text("When off, only short snore clips are kept after analysis. Full recordings take roughly 30 to 60 MB a night. Audio never leaves your iPhone and is excluded from backups.")
                }

                Section {
                    Button("Delete all nights", role: .destructive) { confirmDeleteAll = true }
                }

                Section("About") {
                    Text("SnoreLog uses Apple's on-device sound recognition to find snoring. It is not a medical device and does not diagnose any condition. If you're concerned about your snoring or sleep, talking to a healthcare professional may be helpful.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: refreshStorage)
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .sheet(isPresented: $showingReport) { DoctorReportView() }
            .sheet(isPresented: $showingTrends) { BodyTrendsView() }
            .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
            .alert("Restore purchases", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(restoreMessage ?? "")
            }
            .confirmationDialog("Delete all nights and recordings?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive, action: deleteAll)
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private var proSection: some View {
        Section {
            if store.isPro {
                LabeledContent("SnoreLog Pro", value: store.activePlanName ?? "Active")
                if store.activePlanName == "Yearly" || store.activePlanName == "Monthly" {
                    Button("Manage subscription") { showingManageSubscriptions = true }
                }
            } else {
                Button {
                    showingPaywall = true
                } label: {
                    Label("Upgrade to SnoreLog Pro", systemImage: "moon.stars.fill")
                }
            }
            Button {
                showingReport = true
            } label: {
                HStack {
                    Label("PDF report for your doctor", systemImage: "doc.richtext")
                    Spacer()
                    if !store.isPro { ProBadge() }
                }
            }
            Button {
                showingTrends = true
            } label: {
                HStack {
                    Label("Weight & blood pressure", systemImage: "chart.xyaxis.line")
                    Spacer()
                    if !store.isPro { ProBadge() }
                }
            }
            if !store.isPro {
                Button("Restore purchases") {
                    Task {
                        do {
                            try await store.restore()
                            restoreMessage = store.isPro ? "SnoreLog Pro is unlocked." : "No earlier SnoreLog Pro purchase was found for this Apple ID."
                        } catch {
                            restoreMessage = error.localizedDescription
                        }
                    }
                }
            }
        } header: {
            Text("SnoreLog Pro")
        } footer: {
            Text("Everything else in SnoreLog stays free.")
        }
    }

    private func setUseHealth(_ on: Bool) {
        healthError = nil
        guard on else {
            useHealth = false
            HealthImporter.clearImportedData(in: context)
            return
        }
        Task {
            do {
                try await HealthImporter.requestAccess()
                useHealth = true
                // Fill in the days before nights already recorded.
                let nights = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
                await HealthImporter.refresh(nights, in: context, force: true)
                await HealthImporter.refreshBodyReadings(in: context)
            } catch {
                healthError = "Couldn't connect to Apple Health: \(error.localizedDescription)"
            }
        }
    }

    private func setAutoWeather(_ on: Bool) {
        weatherError = nil
        guard on else {
            autoWeather = false
            return
        }
        Task {
            if await WeatherFetcher.requestAccess() {
                autoWeather = true
            } else {
                weatherError = "Location access is off for SnoreLog. Turn it on in Settings > Privacy & Security > Location Services to use automatic weather."
            }
        }
    }

    private func refreshStorage() {
        storageText = ByteCountFormatter.string(fromByteCount: SessionStorage.totalBytes(), countStyle: .file)
    }

    private func deleteAll() {
        let nights = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        for night in nights where night.status != .recording {
            SessionStorage.deleteFolder(for: night.id)
            context.delete(night)
        }
        try? context.save()
        refreshStorage()
    }
}
