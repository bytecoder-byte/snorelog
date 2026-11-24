import SwiftData
import SwiftUI

/// A row of chips where at most one can be on. Tapping the chip that is on turns it off again.
struct ChoiceChips<Value: Hashable>: View {
    var options: [Value]
    var title: (Value) -> String
    @Binding var selection: Value?

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isOn = selection == option
                Button {
                    selection = isOn ? nil : option
                } label: {
                    Text(title(option))
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// "How's your nose tonight?" on a 0 to 3 scale.
struct NosePicker: View {
    var title = "How's your nose tonight?"
    @Binding var level: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ChoiceChips(
                options: NoseLevel.allCases,
                title: \.title,
                selection: Binding(
                    get: { level.flatMap(NoseLevel.init(rawValue:)) },
                    set: { level = $0?.rawValue }
                )
            )
        }
    }
}

/// "Your night" on the night report: the morning position question, the nose level and the weather.
struct NightContextSection: View {
    @Bindable var night: SleepSession
    @Environment(\.modelContext) private var context

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("How did you sleep?").font(.subheadline.weight(.semibold))
                ChoiceChips(
                    options: SleepPosition.allCases,
                    title: \.title,
                    selection: Binding(
                        get: { night.sleepPosition },
                        set: { night.sleepPosition = $0; try? context.save() }
                    )
                )
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your nose at bedtime").font(.subheadline.weight(.semibold))
                    if night.noseLevel == nil, night.daytime?.congestionLevel != nil {
                        Spacer()
                        Label("From Health", systemImage: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ChoiceChips(
                    options: NoseLevel.allCases,
                    title: \.title,
                    selection: Binding(
                        get: { (night.noseLevel ?? night.daytime?.congestionLevel).flatMap(NoseLevel.init(rawValue:)) },
                        set: { night.noseLevel = $0?.rawValue; try? context.save() }
                    )
                )
            }
            .padding(.vertical, 4)

            if let weather = night.weather {
                WeatherRow(weather: weather)
            }
        } header: {
            Text("Your night")
        } footer: {
            Text("Your phone can't tell how you lay, so note it here in the morning. Side, back and a blocked nose are some of the things that change snoring most from night to night.")
        }
    }
}

struct WeatherRow: View {
    var weather: NightWeather

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(summary)
            } icon: {
                Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor)
            }
            .font(.subheadline)
            WeatherAttributionView()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts: [String] = []
        if let temperature = weather.temperatureCelsius { parts.append(WeatherFetcher.temperatureText(temperature)) }
        if let condition = weather.condition { parts.append(condition) }
        if let humidity = weather.humidity { parts.append("\(Int((humidity * 100).rounded()))% humidity") }
        return "Outside at bedtime: " + parts.joined(separator: ", ")
    }
}
