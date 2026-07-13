// SPDX-License-Identifier: Apache-2.0
import Foundation
import StoreKit
import UIKit
import os

private let log = Logger(subsystem: "com.silvercommerce.halo", category: "reach.ios.store")

/// The in-app purchase surface (App Store guideline 3.1.1). Halo Cloud can be
/// bought here with StoreKit, alongside the web/BYOK paths — a purchase is
/// verified on-device by StoreKit, then its signed transaction is handed to the
/// relay (`HaloAccount.verifyAppleTransaction`), which validates it against
/// Apple and activates the account.
///
/// This object only knows how to talk to StoreKit; it calls back through
/// `onVerify` so it stays independent of the account/auth layer. A background
/// task watches `Transaction.updates` so renewals and restores entitle the
/// account without the user re-tapping anything.
@MainActor
final class StoreService: ObservableObject {

    /// The auto-renewable subscription that grants Halo Cloud. Must match the
    /// product id created in App Store Connect and the backend's
    /// `APPLE_IAP_PRODUCT_ID`.
    static let cloudProductID = "com.silvercommerce.halo.cloud.monthly"

    enum Phase: Equatable {
        case idle
        case loading      // fetching products from the App Store
        case purchasing   // a buy is in flight
        case restoring    // AppStore.sync() in flight
    }

    @Published private(set) var product: Product?
    @Published private(set) var phase: Phase = .idle
    @Published var lastError: String?

    /// Hands a StoreKit-verified transaction JWS to the account layer for
    /// server-side validation. Returns true once the account is active.
    var onVerify: (@MainActor (String) async -> Bool)?

    private var updatesTask: Task<Void, Never>?

    /// The displayable price, e.g. "$8.99". Nil until the product loads.
    var displayPrice: String? { product?.displayPrice }

    /// A short billing-period phrase, e.g. "month", for "<price> / <period>".
    var periodLabel: String? {
        guard let unit = product?.subscription?.subscriptionPeriod.unit else { return nil }
        switch unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        @unknown default: return nil
        }
    }

    func start() {
        // Watch for transactions that arrive outside an explicit purchase:
        // renewals, Ask-to-Buy approvals, restores on a new device.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(verification: update)
            }
        }
        Task { await loadProduct() }
    }

    deinit { updatesTask?.cancel() }

    func loadProduct() async {
        phase = .loading
        lastError = nil
        do {
            let products = try await Product.products(for: [Self.cloudProductID])
            product = products.first
            if product == nil {
                lastError = "Halo Cloud isn't available to purchase right now."
            }
        } catch {
            lastError = "Couldn't load the subscription. \(error.localizedDescription)"
        }
        phase = .idle
    }

    /// Buy the cloud subscription. On a verified success the transaction is sent
    /// to the relay and finished. Returns true when the account is active after.
    @discardableResult
    func purchase() async -> Bool {
        guard let product else {
            await loadProduct()
            guard product != nil else { return false }
            return false
        }
        phase = .purchasing
        lastError = nil
        defer { phase = .idle }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                return await handle(verification: verification)
            case .userCancelled:
                return false
            case .pending:
                // Ask-to-Buy / SCA — the transaction will arrive later via
                // Transaction.updates and entitle then.
                lastError = "Your purchase is pending approval. It'll unlock once approved."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "The purchase didn't complete. \(error.localizedDescription)"
            return false
        }
    }

    /// Restore purchases made on another device / after reinstall.
    func restore() async {
        phase = .restoring
        lastError = nil
        defer { phase = .idle }
        do {
            try await AppStore.sync()
        } catch {
            // sync() throws on user-cancel too; only surface real failures.
            log.notice("AppStore.sync failed: \(error.localizedDescription, privacy: .public)")
        }
        var entitled = false
        for await entitlement in Transaction.currentEntitlements {
            if await handle(verification: entitlement) { entitled = true }
        }
        if !entitled {
            lastError = "We didn't find an active subscription to restore."
        }
    }

    /// Open Apple's native manage-subscriptions sheet.
    func manageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            log.notice("showManageSubscriptions failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Validate a StoreKit transaction, hand its JWS to the relay, then finish
    /// it so StoreKit stops re-delivering it. Returns true when the account is
    /// active afterwards.
    @discardableResult
    private func handle(verification: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let transaction) = verification else {
            log.notice("Ignoring unverified StoreKit transaction")
            return false
        }
        let active = await onVerify?(verification.jwsRepresentation) ?? false
        await transaction.finish()
        return active
    }
}
