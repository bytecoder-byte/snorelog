import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import SnoreLog

/// Runs purchases against SnoreLog.storekit, the same local configuration the Xcode scheme uses.
@MainActor
@Suite(.serialized)
struct ProStoreTests {
    private final class BundleToken {}

    private func makeSession() throws -> SKTestSession {
        // Prefer the copy in the test bundle; fall back to the source file, which the simulator can read.
        let sourceCopy = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SnoreLog.storekit")
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "SnoreLog", withExtension: "storekit")
            ?? (FileManager.default.fileExists(atPath: sourceCopy.path) ? sourceCopy : nil))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        session.resetToDefaultState()
        return session
    }

    /// The test StoreKit daemon can take a moment to list a new purchase in current entitlements.
    private func refreshUntilPro(_ store: ProStore) async {
        for _ in 0..<20 {
            await store.refreshEntitlements()
            if store.isPro { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func loadsAllThreePlansWithTheRightPrices() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = ProStore(listenForTransactions: false)
        await store.load()

        #expect(store.products.map(\.id) == ProProducts.all)
        #expect(store.product(ProProducts.yearly)?.price == Decimal(string: "24.99"))
        #expect(store.product(ProProducts.monthly)?.price == Decimal(string: "3.99"))
        #expect(store.product(ProProducts.lifetime)?.price == Decimal(string: "49.99"))
        let trial = store.product(ProProducts.yearly)?.subscription?.introductoryOffer
        #expect(trial?.paymentMode == .freeTrial)
        let isOneWeek = trial.map { ($0.period.unit == .week && $0.period.value == 1) || ($0.period.unit == .day && $0.period.value == 7) }
        #expect(isOneWeek == true)
        #expect(store.isPro == false)
    }

    // Purchases go through SKTestSession.buyProduct rather than Product.purchase(), which waits for a
    // confirmation sheet that a headless test run never shows. ProStore then has to notice the new
    // entitlement on its own, the same way it does after a real purchase or a restore.
    @Test(.timeLimit(.minutes(1)))
    func lifetimePurchaseUnlocksPro() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = ProStore(listenForTransactions: false)
        await store.load()
        #expect(store.isPro == false)

        let transaction = try await session.buyProduct(identifier: ProProducts.lifetime)
        #expect(transaction.productID == ProProducts.lifetime)
        await refreshUntilPro(store)
        #expect(store.isPro)
        #expect(store.activePlanName == "Lifetime")
    }

    @Test(.timeLimit(.minutes(1)))
    func yearlySubscriptionUnlocksPro() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = ProStore(listenForTransactions: false)

        let transaction = try await session.buyProduct(identifier: ProProducts.yearly)
        #expect(transaction.productID == ProProducts.yearly)
        await refreshUntilPro(store)
        #expect(store.isPro)
        #expect(store.activePlanName == "Yearly")
    }
}
