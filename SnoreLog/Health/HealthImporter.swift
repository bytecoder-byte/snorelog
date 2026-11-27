import Foundation
import HealthKit
import SwiftData

/// Reads the day before each night from Apple Health: workouts, steps, water, caffeine, alcohol
/// and sinus congestion. Also reads weight and blood pressure for the Pro trends. Read-only. SnoreLog never writes to Health, and nothing read here leaves the iPhone.
@MainActor
enum HealthImporter {
    private static let store = HKHealthStore()

    /// False on devices without Health, such as iPad.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.useHealth) }

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .dietaryWater, .dietaryCaffeine, .numberOfAlcoholicBeverages,
            .bodyMass, .bloodPressureSystolic, .bloodPressureDiastolic,
        ]
        for identifier in quantities {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        // Blood pressure is read through its correlation, but permission is asked for the two
        // quantity types above. Asking for the correlation type itself is not allowed.
        if let congestion = HKCategoryType.categoryType(forIdentifier: .sinusCongestion) { types.insert(congestion) }
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
        let readings = (try? context.fetch(FetchDescriptor<BodyReading>(predicate: #Predicate { $0.fromHealth == true }))) ?? []
        for reading in readings { context.delete(reading) }
        try? context.save()
    }

    // MARK: - Weight and blood pressure

    /// How far back weight and blood pressure are read.
    static let bodyHistoryDays = 365

    /// Replaces the weight and blood pressure readings copied from Health with a fresh read.
    /// Readings the person typed in are left alone.
    static func refreshBodyReadings(in context: ModelContext) async {
        guard isEnabled, isAvailable, !DemoData.isEnabled else { return }
        let start = Calendar.current.date(byAdding: .day, value: -bodyHistoryDays, to: .now) ?? .now
        let interval = DateInterval(start: start, end: .now)
        let weights = await weightSamples(in: interval)
        let pressures = await bloodPressureSamples(in: interval)

        let old = (try? context.fetch(FetchDescriptor<BodyReading>(predicate: #Predicate { $0.fromHealth == true }))) ?? []
        for reading in old { context.delete(reading) }
        for reading in weights + pressures { context.insert(reading) }
        try? context.save()
    }

    private static func weightSamples(in interval: DateInterval) async -> [BodyReading] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bodyMass), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        guard let samples = try? await descriptor.result(for: store) else { return [] }
        return samples.map { sample in
            BodyReading(
                date: sample.startDate,
                kind: .weight,
                value: sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                fromHealth: true,
                sourceName: sample.sourceRevision.source.name
            )
        }
    }

    /// Blood pressure is stored in Health as a correlation holding one systolic and one diastolic sample.
    private static func bloodPressureSamples(in interval: DateInterval) async -> [BodyReading] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let correlations: [HKCorrelation] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKCorrelationType(.bloodPressure),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKCorrelation]) ?? [])
            }
            store.execute(query)
        }
        let systolicType = HKQuantityType(.bloodPressureSystolic)
        let diastolicType = HKQuantityType(.bloodPressureDiastolic)
        let mmHg = HKUnit.millimeterOfMercury()
        return correlations.compactMap { correlation in
            guard let systolic = correlation.objects(for: systolicType).first as? HKQuantitySample,
                  let diastolic = correlation.objects(for: diastolicType).first as? HKQuantitySample else { return nil }
            return BodyReading(
                date: correlation.startDate,
                kind: .bloodPressure,
                value: systolic.quantity.doubleValue(for: mmHg),
                secondValue: diastolic.quantity.doubleValue(for: mmHg),
                fromHealth: true,
                sourceName: correlation.sourceRevision.source.name
            )
        }
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

        // Drinks in the last 3 hours before bed.
        let lateAlcohol = DaytimeActivity.lateAlcoholWindow(beforeBedtime: bedtime)
        var lateDrinks: Double?
        if lateAlcohol.duration > 0 {
            lateDrinks = await sum(.numberOfAlcoholicBeverages, unit: .count(), in: lateAlcohol)
        }

        return DaytimeActivity(
            workoutMinutes: workoutMinutes,
            strengthMinutes: strengthMinutes,
            steps: await sum(.stepCount, unit: .count(), in: window),
            waterMilliliters: await sum(.dietaryWater, unit: .literUnit(with: .milli), in: window),
            caffeineMilligrams: await sum(.dietaryCaffeine, unit: .gramUnit(with: .milli), in: window),
            lateCaffeineMilligrams: lateCaffeine,
            alcoholicDrinks: await sum(.numberOfAlcoholicBeverages, unit: .count(), in: window),
            lateAlcoholicDrinks: lateDrinks,
            congestionLevel: await congestionLevel(in: window)
        )
    }

    /// The strongest sinus congestion symptom logged in the interval, on the 0 to 3 scale of `NoseLevel`.
    /// Nil when nothing was logged.
    private static func congestionLevel(in interval: DateInterval) async -> Int? {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sinusCongestion), predicate: predicate)],
            sortDescriptors: []
        )
        guard let samples = try? await descriptor.result(for: store), !samples.isEmpty else { return nil }
        return samples.map { sample -> Int in
            switch HKCategoryValueSeverity(rawValue: sample.value) {
            case .notPresent: 0
            case .mild: 1
            case .moderate: 2
            case .severe: 3
            // "Present" without a severity.
            default: 1
            }
        }.max()
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
