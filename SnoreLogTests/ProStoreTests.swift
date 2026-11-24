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

    @Test func loadsAllThreePlansWithTheRightPrices() async throws {
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

    @Test func buyingLifetimeUnlocksPro() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = ProStore(listenForTransactions: false)
        await store.load()
        let lifetime = try #require(store.product(ProProducts.lifetime))

        let outcome = try await store.purchase(lifetime)
        #expect(outcome == .purchased)
        #expect(store.isPro)
        #expect(store.activePlanName == "Lifetime")
    }

    @Test func subscribingYearlyUnlocksPro() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = ProStore(listenForTransactions: false)
        await store.load()
        let yearly = try #require(store.product(ProProducts.yearly))

        #expect(try await store.purchase(yearly) == .purchased)
        #expect(store.isPro)
        #expect(store.activePlanName == "Yearly")
    }
}
