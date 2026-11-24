import SwiftData
import SwiftUI

@main
struct SnoreLogApp: App {
    @State private var recorder = NightRecorder()
    @State private var proStore = ProStore()
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: SleepSession.self, SnoreEpisode.self)
        } catch {
            fatalError("Could not open the database: \(error)")
        }
        AnalysisService.recoverUnfinishedNights(in: container.mainContext)
        DemoData.seedIfNeeded(in: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recorder)
                .environment(proStore)
                .task { await proStore.load() }
        }
        .modelContainer(container)
    }
}
