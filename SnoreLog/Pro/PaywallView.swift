import StoreKit
import SwiftUI

/// Links shown on the paywall. App Review requires a Terms of Use (EULA) and a privacy policy link.
enum AppLinks {
    /// Apple's standard EULA. Replace if you publish your own terms.
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// Set this to your hosted privacy policy before submitting. The link is hidden while it's nil.
    static let privacyPolicy: URL? = nil
}

/// The SnoreLog Pro upgrade screen. Lists the plans, buys one, and restores earlier purchases.
struct PaywallView: View {
    /// Optional line at the top explaining what led here, for example the PDF report.
    var reason: String?
    @Environment(ProStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ProProducts.yearly
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    features
                    plans
                    purchaseButton
                    finePrint
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { if store.loadState == .idle { await store.load() } }
            .onChange(of: store.isPro) { _, isPro in if isPro { dismiss() } }
            .alert("Purchase didn't go through", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("SnoreLog Pro", isPresented: Binding(get: { infoMessage != nil }, set: { if !$0 { infoMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(infoMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .padding(.top, 8)
            Text("SnoreLog Pro")
                .font(.largeTitle.bold())
            if let reason {
                Text(reason)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            Text("Recording, reports and history stay free. Pro adds extras for when you want to dig deeper.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            Feature(icon: "doc.richtext", title: "PDF report for your doctor",
                    detail: "A clear summary of your nights, scores and tags, ready to print or share.")
            Feature(icon: "sparkles", title: "New Pro features as they arrive",
                    detail: "Included in your plan at no extra cost.")
            Feature(icon: "heart", title: "Support an independent app",
                    detail: "Your plan keeps SnoreLog free for everyone and free of ads.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var plans: some View {
        let options = planOptions
        if options.isEmpty {
            VStack(spacing: 12) {
                if case .failed(let message) = store.loadState {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { Task { await store.load() } }
                } else {
                    ProgressView("Loading plans…")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: 10) {
                ForEach(options) { option in
                    PlanRow(option: option, isSelected: option.id == selectedID) { selectedID = option.id }
                }
            }
        }
    }

    private var purchaseButton: some View {
        Button {
            Task { await buy() }
        } label: {
            Group {
                if store.isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(callToAction)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(planOptions.isEmpty || store.isPurchasing)
    }

    private var finePrint: some View {
        VStack(spacing: 12) {
            Text(renewalText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 18) {
                Button("Restore purchases") { Task { await restore() } }
                Link("Terms of Use", destination: AppLinks.termsOfUse)
                if let privacy = AppLinks.privacyPolicy {
                    Link("Privacy Policy", destination: privacy)
                }
            }
            .font(.caption)
        }
    }

    // MARK: - Plans

    private var selected: PlanOption? { planOptions.first { $0.id == selectedID } }

    private var planOptions: [PlanOption] {
        if !store.products.isEmpty {
            return store.products.map { PlanOption(product: $0, trialAvailable: store.isEligibleForTrial) }
        }
        // The simulator in CI has no StoreKit configuration, so screenshots use sample plans.
        // Real builds never show these.
        return DemoData.isEnabled ? PlanOption.demo : []
    }

    private var callToAction: String {
        guard let selected else { return "Continue" }
        if selected.hasTrial { return "Try free for 7 days" }
        return selected.id == ProProducts.lifetime ? "Buy once for \(selected.price)" : "Subscribe for \(selected.price)\(selected.periodSuffix)"
    }

    private var renewalText: String {
        guard let selected else { return "" }
        if selected.id == ProProducts.lifetime {
            return "One payment of \(selected.price). No subscription."
        }
        let start = selected.hasTrial ? "Free for 7 days, then \(selected.price)\(selected.periodSuffix). " : "\(selected.price)\(selected.periodSuffix). "
        return start + "Renews automatically until cancelled. Cancel anytime in Settings at least 24 hours before the "
            + (selected.hasTrial ? "trial ends" : "end of the period") + " so you're not charged."
    }

    // MARK: - Actions

    private func buy() async {
        guard let selected else { return }
        guard let product = selected.product else {
            infoMessage = "Purchases aren't available in this preview build."
            return
        }
        do {
            if try await store.purchase(product) == .pending {
                infoMessage = "Your purchase is waiting for approval. Pro unlocks as soon as it's approved."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore() async {
        do {
            try await store.restore()
            if !store.isPro { infoMessage = "No earlier SnoreLog Pro purchase was found for this Apple ID." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One plan as shown on the paywall, from a StoreKit product or sample data.
struct PlanOption: Identifiable {
    var id: String
    var title: String
    var price: String
    var periodSuffix: String
    var detail: String?
    var badge: String?
    var hasTrial: Bool
    var product: Product?

    init(id: String, title: String, price: String, periodSuffix: String, detail: String?, badge: String?, hasTrial: Bool, product: Product? = nil) {
        self.id = id
        self.title = title
        self.price = price
        self.periodSuffix = periodSuffix
        self.detail = detail
        self.badge = badge
        self.hasTrial = hasTrial
        self.product = product
    }

    init(product: Product, trialAvailable: Bool) {
        let hasTrial = trialAvailable && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
        switch product.id {
        case ProProducts.yearly:
            let monthly = (product.price / 12).formatted(product.priceFormatStyle)
            self.init(id: product.id, title: "Yearly", price: product.displayPrice, periodSuffix: " a year",
                      detail: "Just \(monthly) a month", badge: hasTrial ? "7 days free" : "Best value", hasTrial: hasTrial, product: product)
        case ProProducts.monthly:
            self.init(id: product.id, title: "Monthly", price: product.displayPrice, periodSuffix: " a month",
                      detail: nil, badge: nil, hasTrial: hasTrial, product: product)
        default:
            self.init(id: product.id, title: "Lifetime", price: product.displayPrice, periodSuffix: "",
                      detail: "Pay once, keep Pro forever", badge: nil, hasTrial: false, product: product)
        }
    }

    static let demo: [PlanOption] = [
        PlanOption(id: ProProducts.yearly, title: "Yearly", price: "$24.99", periodSuffix: " a year",
                   detail: "Just $2.08 a month", badge: "7 days free", hasTrial: true),
        PlanOption(id: ProProducts.monthly, title: "Monthly", price: "$3.99", periodSuffix: " a month",
                   detail: nil, badge: nil, hasTrial: false),
        PlanOption(id: ProProducts.lifetime, title: "Lifetime", price: "$49.99", periodSuffix: "",
                   detail: "Pay once, keep Pro forever", badge: nil, hasTrial: false),
    ]
}

private struct PlanRow: View {
    var option: PlanOption
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(option.title).font(.headline)
                        if let badge = option.badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    if let detail = option.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(option.price).font(.headline).monospacedDigit()
                    if !option.periodSuffix.isEmpty {
                        Text(option.periodSuffix.trimmingCharacters(in: .whitespaces))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("once").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct Feature: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Small "PRO" label for features that need SnoreLog Pro.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}
