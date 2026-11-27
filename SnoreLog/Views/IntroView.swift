import SwiftUI

struct IntroView: View {
    var onContinue: () -> Void

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 24)
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Find out how much you snore")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 16) {
                IntroRow(icon: "bed.double.fill", text: "Start a recording when you go to bed and leave your phone on the nightstand, plugged in.")
                IntroRow(icon: "waveform", text: "In the morning, SnoreLog finds your snoring on your iPhone and shows when and how loud it was.")
                IntroRow(icon: "lock.fill", text: "Audio never leaves your phone. Full recordings are deleted after analysis unless you choose to keep them.")
                IntroRow(icon: "cross.case.fill", text: "SnoreLog is not a medical device and doesn't diagnose any condition. If you're concerned about your snoring or sleep, talking to a healthcare professional may be helpful.")
            }
            Spacer(minLength: 24)
        }
        .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onContinue) {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.background)
        }
    }
}

private struct IntroRow: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(.tint)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
