import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.sensitivity) private var sensitivity: Sensitivity = .medium
    @AppStorage(SettingsKeys.keepFullRecordings) private var keepFullRecordings = false
    @State private var storageText = ""
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sensitivity", selection: $sensitivity) {
                        ForEach(Sensitivity.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Detection")
                } footer: {
                    Text(sensitivity.detail + " Applies to nights analyzed from now on.")
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
                    Text("SnoreLog uses Apple's on-device sound recognition to find snoring. It is not a medical device and does not diagnose sleep apnea or any other condition. If you are worried about your sleep or breathing, talk to a doctor.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: refreshStorage)
            .confirmationDialog("Delete all nights and recordings?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive, action: deleteAll)
            } message: {
                Text("This can't be undone.")
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
