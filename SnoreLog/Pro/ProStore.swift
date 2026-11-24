import Foundation
import Observation
import StoreKit

/// The in-app purchase product IDs. They must match App Store Connect and
/// `SnoreLogTests/SnoreLog.storekit`. Change the prefix along with the bundle ID.
enum ProProducts {
    static let yearly = "com.example.snorelog.pro.yearly"
    static let monthly = "com.example.snorelog.pro.monthly"
    static let lifetime = "com.example.snorelog.pro.lifetime"
    static let all = [yearly, monthly, lifetime]
    /// Subscription group shown under Settings > Apple ID > Subscriptions.
    static let subscriptionGroupName = "SnoreLog Pro"
}

/// Loads the SnoreLog Pro products, buys them, and keeps track of whether Pro is unlocked.
/// Everything that was free before Pro stays free; only new extras check `isPro`.
@MainActor
@Observable
final class ProStore {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var products: [Product] = []
    private(set) var loadState: LoadState = .idle
    private(set) var purchasedProductIDs: Set<String> = []
    /// Whether the yearly plan's 7-day free trial is still available to this Apple ID.
    private(set) var isEligibleForTrial = true
    private(set) var isPurchasing = false

    /// Screenshots and demos can force Pro on with the launch argument `-proUnlocked`.
    private let forcedUnlock = ProcessInfo.processInfo.arguments.contains("-proUnlocked")
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    var isPro: Bool { forcedUnlock || !purchasedProductIDs.isEmpty }

    /// The plan that unlocked Pro, for the Settings screen.
    var activePlanName: String? {
        if purchasedProductIDs.contains(ProProducts.lifetime) { return "Lifetime" }
        if purchasedProductIDs.contains(ProProducts.yearly) { return "Yearly" }
        if purchasedProductIDs.contains(ProProducts.monthly) { return "Monthly" }
        return forcedUnlock ? "Demo" : nil
    }

    init(listenForTransactions: Bool = true) {
        if listenForTransactions {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update {
                        await transaction.finish()
                    }
                    await self?.refreshEntitlements()
                }
            }
        }
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    /// Loads products and current entitlements. Safe to call more than once.
    func load() async {
        if loadState == .loading { return }
        loadState = .loading
        do {
            let loaded = try await Product.products(for: ProProducts.all)
            products = ProProducts.all.compactMap { id in loaded.first { $0.id == id } }
            loadState = products.isEmpty ? .failed("SnoreLog Pro isn't available right now.") : .loaded
            if let yearly = product(ProProducts.yearly), let subscription = yearly.subscription {
                isEligibleForTrial = await subscription.isEligibleForIntroOffer
            }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
        await refreshEntitlements()
    }

    /// Re-reads which Pro products this Apple ID currently owns.
    func refreshEntitlements() async {
        var owned: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ProProducts.all.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < .now { continue }
            owned.insert(transaction.productID)
        }
        purchasedProductIDs = owned
    }

    enum PurchaseOutcome: Equatable { case purchased, pending, cancelled }

    @discardableResult
    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        isPurchasing = true
        defer { isPurchasing = false }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw StoreError.unverified
            }
            await transaction.finish()
            await refreshEntitlements()
            return .purchased
        case .pending:
            // Waiting on Ask to Buy or a payment problem. Transaction.updates unlocks Pro later.
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /// Restore Purchases. Syncs with the App Store, which may ask the person to sign in.
    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    enum StoreError: LocalizedError {
        case unverified
        var errorDescription: String? { "The App Store couldn't verify this purchase. Please try again." }
    }
}
