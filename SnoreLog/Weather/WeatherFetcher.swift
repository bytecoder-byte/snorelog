import CoreLocation
import SwiftData
import SwiftUI
import WeatherKit

/// Fills in the outdoor weather at bedtime from Apple Weather, when the person turns it on.
///
/// Needs the WeatherKit capability on the App ID (and the entitlement in SnoreLog.entitlements),
/// plus location permission while the app is open. The location is rounded to about 1 km
/// before it is sent to Apple Weather, and it is not stored.
@MainActor
enum WeatherFetcher {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.autoWeather) }

    /// Asks for location access if it hasn't been decided yet. Returns false if it's denied.
    static func requestAccess() async -> Bool {
        await LocationOnce.shared.requestAuthorization()
    }

    /// Reads the current weather and stores it on the night. Fails quietly: weather is a nice extra.
    static func fill(_ night: SleepSession, in context: ModelContext) async {
        guard isEnabled, !DemoData.isEnabled, night.weather == nil else { return }
        guard let location = await LocationOnce.shared.current() else { return }
        // Round to 2 decimal places (about 1 km). Plenty for weather, and kinder to privacy.
        let rounded = CLLocation(
            latitude: (location.coordinate.latitude * 100).rounded() / 100,
            longitude: (location.coordinate.longitude * 100).rounded() / 100
        )
        do {
            let current = try await WeatherService.shared.weather(for: rounded, including: .current)
            night.weather = NightWeather(
                temperatureCelsius: current.temperature.converted(to: .celsius).value,
                humidity: current.humidity,
                pressureHectopascals: current.pressure.converted(to: .hectopascals).value,
                condition: current.condition.description
            )
            try? context.save()
        } catch {
            // No weather this night. Most often the WeatherKit capability isn't set up yet.
        }
    }

    static func temperatureText(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}

/// One location fix at a time, using the coarse accuracy weather needs.
@MainActor
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    static let shared = LocationOnce()

    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuations: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    private var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    func requestAuthorization() async -> Bool {
        switch manager.authorizationStatus {
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        default:
            return isAuthorized
        }
    }

    func current() async -> CLLocation? {
        guard isAuthorized else { return nil }
        return await withCheckedContinuation { continuation in
            locationContinuations.append(continuation)
            if locationContinuations.count == 1 { manager.requestLocation() }
        }
    }

    private func finish(_ location: CLLocation?) {
        let waiting = locationContinuations
        locationContinuations = []
        waiting.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined, let continuation = self.authorizationContinuation else { return }
            self.authorizationContinuation = nil
            continuation.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}

/// Apple Weather's logo and a link to its data sources. Apple requires both wherever its weather is shown.
struct WeatherAttributionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var attribution: WeatherAttribution?

    var body: some View {
        HStack(spacing: 8) {
            if let attribution {
                AsyncImage(url: colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Text(attribution.serviceName)
                }
                .frame(height: 12)
                Link("Data sources", destination: attribution.legalPageURL)
            } else {
                Text("Weather from Apple Weather")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .task {
            guard !DemoData.isEnabled else { return }
            attribution = try? await WeatherService.shared.attribution
        }
    }
}
