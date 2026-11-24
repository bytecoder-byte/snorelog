import Foundation
import HealthKit
import SwiftData

/// Reads the day before each night from Apple Health: workouts, steps, water, caffeine and alcohol.
/// Read-only. SnoreLog never writes to Health, and nothing read here leaves the iPhone.
@MainActor
enum HealthImporter {
    private static let store = HKHealthStore()

    /// False on devices without Health, such as iPad.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.useHealth) }

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        let quantities: [HKQuantityTypeIdentifier] = [.stepCount, .dietaryWater, .dietaryCaffeine, .numberOfAlcoholicBeverages]
        for identifier in quantities {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        return types
    }

    /// Shows Apple's permission sheet the first time. Health never says which types were
    /// allowed, so data that was not allowed simply looks like no data.
    static func requestAccess() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Reads Health for each night that hasn't been read yet, or was read too early to be complete.
    static func refresh(_ nights: [SleepSession], in context: ModelContext, force: Bool = false) async {
        guard isEnabled, isAvailable, !DemoData.isEnabled else { return }
        var changed = false
        for night in nights where night.status == .done && (force || needsImport(night)) {
            night.daytime = await activity(before: night.startDate)
            night.dayImportedAt = .now
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Removes everything read from Health, for when the person turns it off.
    static func clearImportedData(in context: ModelContext) {
        let nights = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        for night in nights {
            night.daytime = nil
            night.dayImportedAt = nil
        }
        try? context.save()
    }

    /// Water or drinks are often logged later, so read again until half a day after bedtime.
    private static func needsImport(_ night: SleepSession) -> Bool {
        guard let importedAt = night.dayImportedAt else { return true }
        let complete = importedAt > night.startDate.addingTimeInterval(12 * 3600)
        let recentlyRead = Date.now.timeIntervalSince(importedAt) < 10 * 60
        return !complete && !recentlyRead
    }

    // MARK: - Queries

    static func activity(before bedtime: Date) async -> DaytimeActivity {
        let window = DaytimeActivity.window(beforeBedtime: bedtime)
        let (workoutMinutes, strengthMinutes) = await workoutMinutes(in: window)

        // Caffeine from 3 PM onwards, if bedtime is after 3 PM.
        var lateCaffeine: Double?
        if let lateStart = Calendar.current.date(
            bySettingHour: DaytimeActivity.lateCaffeineHour, minute: 0, second: 0, of: window.start
        ), lateStart < window.end {
            lateCaffeine = await sum(.dietaryCaffeine, unit: .gramUnit(with: .milli), in: DateInterval(start: lateStart, end: window.end))
        }

        return DaytimeActivity(
            workoutMinutes: workoutMinutes,
            strengthMinutes: strengthMinutes,
            steps: await sum(.stepCount, unit: .count(), in: window),
            waterMilliliters: await sum(.dietaryWater, unit: .literUnit(with: .milli), in: window),
            caffeineMilligrams: await sum(.dietaryCaffeine, unit: .gramUnit(with: .milli), in: window),
            lateCaffeineMilligrams: lateCaffeine,
            alcoholicDrinks: await sum(.numberOfAlcoholicBeverages, unit: .count(), in: window)
        )
    }

    /// Total of a quantity over the interval, or nil if nothing was logged (or access wasn't given).
    private static func sum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async -> Double? {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        guard let statistics = try? await descriptor.result(for: store),
              let quantity = statistics.sumQuantity() else { return nil }
        return quantity.doubleValue(for: unit)
    }

    /// Minutes of workouts that ended in the interval, and how many of them were strength training.
    private static func workoutMinutes(in interval: DateInterval) async -> (total: Double?, strength: Double?) {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictEndDate)
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [])
        guard let workouts = try? await descriptor.result(for: store), !workouts.isEmpty else { return (nil, nil) }
        let total = workouts.reduce(0) { $0 + $1.duration } / 60
        let strength = workouts
            .filter { strengthTypes.contains($0.workoutActivityType) }
            .reduce(0) { $0 + $1.duration } / 60
        return (total, strength)
    }

    private static let strengthTypes: Set<HKWorkoutActivityType> = [
        .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining,
    ]
}
