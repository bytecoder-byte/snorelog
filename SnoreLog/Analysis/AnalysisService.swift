import Foundation
import SwiftData
import UIKit

@MainActor
enum AnalysisService {
    /// Analyzes a recorded night and stores the results on the session.
    static func analyze(
        _ session: SleepSession,
        in context: ModelContext,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let sensitivity = Sensitivity(rawValue: defaults.string(forKey: SettingsKeys.sensitivity) ?? "") ?? .medium
        let keepFull = defaults.bool(forKey: SettingsKeys.keepFullRecordings)
        let analyzer = NightAnalyzer(folder: session.folderURL, sensitivity: sensitivity, keepFullRecordings: keepFull)

        session.status = .analyzing
        session.analysisError = nil
        try? context.save()

        // Ask for extra time in case the person locks the phone while analysis runs.
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Analyze night") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await analyzer.run(progress: progress)
            }.value

            for old in session.episodes { context.delete(old) }
            session.episodes = result.episodes.map {
                SnoreEpisode(
                    offset: $0.offset,
                    duration: $0.duration,
                    confidence: $0.confidence,
                    peakDB: $0.peakDB,
                    intensity: $0.intensity,
                    clipFileName: $0.clipFileName
                )
            }
            session.recordedSeconds = result.recordedSeconds
            session.snoringSeconds = result.snoringSeconds
            session.score = result.score
            session.noiseFloorDB = result.noiseFloorDB
            session.loudestDB = result.loudestDB
            session.minuteLevels = result.minuteLevels
            if session.endDate == nil {
                session.endDate = session.startDate.addingTimeInterval(result.recordedSeconds)
            }
            session.status = .done
            try? context.save()
            // Read the day before from Apple Health, if it's turned on. Never fails the analysis.
            await HealthImporter.refresh([session], in: context)
        } catch {
            session.status = .failed
            session.analysisError = error.localizedDescription
            try? context.save()
            throw error
        }
    }

    /// Call once at launch. A fresh launch is never recording, so a night still marked
    /// "recording" or "analyzing" means the app was closed mid-night. Offer to analyze it.
    static func recoverUnfinishedNights(in context: ModelContext) {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.activeSessionID)
        let recording = SessionStatus.recording.rawValue
        let analyzing = SessionStatus.analyzing.rawValue
        let descriptor = FetchDescriptor<SleepSession>(predicate: #Predicate {
            $0.statusRaw == recording || $0.statusRaw == analyzing
        })
        guard let stuck = try? context.fetch(descriptor) else { return }
        for session in stuck {
            session.status = .pendingAnalysis
        }
        try? context.save()
    }
}

enum SettingsKeys {
    static let sensitivity = "sensitivity"
    static let keepFullRecordings = "keepFullRecordings"
    static let activeSessionID = "activeSessionID"
    static let hasSeenIntro = "hasSeenIntro"
    /// Read daytime activity from Apple Health. Also settable with the launch argument `-useHealth YES`.
    static let useHealth = "useHealth"
}
