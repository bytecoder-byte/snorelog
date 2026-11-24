import SwiftData
import SwiftUI

struct ContentView: View {
    @AppStorage(SettingsKeys.hasSeenIntro) private var hasSeenIntro = false
    @State private var tab = DemoData.screen ?? "tonight"
    @Query(sort: \SleepSession.startDate, order: .reverse) private var nights: [SleepSession]

    var body: some View {
        if DemoData.screen == "paywall" {
            // Used for screenshots.
            PaywallView()
        } else if DemoData.screen == "pdf" {
            DoctorReportView()
        } else if DemoData.screen == "report" || DemoData.screen == "compare", let latest = nights.first {
            // Used for screenshots: open the latest night's report directly.
            NavigationStack { NightReportView(night: latest) }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            TonightView()
                .tabItem { Label("Tonight", systemImage: "moon.zzz.fill") }
                .tag("tonight")
            HistoryView()
                .tabItem { Label("History", systemImage: "chart.bar.fill") }
                .tag("history")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag("settings")
        }
        .sheet(isPresented: Binding(get: { !hasSeenIntro }, set: { if !$0 { hasSeenIntro = true } })) {
            IntroView { hasSeenIntro = true }
                .interactiveDismissDisabled()
        }
    }
}
