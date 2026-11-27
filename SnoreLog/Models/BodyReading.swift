import Foundation
import SwiftData

/// A weight or blood pressure reading. SnoreLog never measures these itself: they come from
/// a scale or cuff through Apple Health, or the person types them in.
@Model
final class BodyReading {
    @Attribute(.unique) var id: UUID
    var date: Date
    /// Raw value of `BodyValue.Kind`.
    var kindRaw: String
    /// Kilograms for weight, systolic mmHg for blood pressure.
    var value: Double
    /// Diastolic mmHg for blood pressure.
    var secondValue: Double?
    /// True when read from Apple Health, false when typed in.
    var fromHealth: Bool
    /// The app or device that wrote it to Health, for example "Withings".
    var sourceName: String?

    init(date: Date, kind: BodyValue.Kind, value: Double, secondValue: Double? = nil, fromHealth: Bool, sourceName: String? = nil) {
        self.id = UUID()
        self.date = date
        self.kindRaw = kind.rawValue
        self.value = value
        self.secondValue = secondValue
        self.fromHealth = fromHealth
        self.sourceName = sourceName
    }

    var kind: BodyValue.Kind { BodyValue.Kind(rawValue: kindRaw) ?? .weight }

    var sourceText: String {
        guard fromHealth else { return "Entered by you" }
        if let sourceName, !sourceName.isEmpty { return "Apple Health · \(sourceName)" }
        return "Apple Health"
    }

    var asValue: BodyValue {
        BodyValue(id: id.uuidString, date: date, kind: kind, value: value, secondValue: secondValue, source: sourceText)
    }
}
