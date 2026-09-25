import Foundation
import Observation
import StoreKit

@MainActor @Observable
final class BionicPurchaseStore {
    let isEnabled: Bool
    private let trialID: String
    private let unlockID: String
    private(set) var trialProduct: Product?
    private(set) var unlockProduct: Product?
    private(set) var hasFullAccess = false
    private(set) var trialWasClaimed = false
    private(set) var trialEndsAt: Date?
    private(set) var entitlementsLoaded = false
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var isPendingApproval = false
    var errorMessage: String?
    private(set) var accessRevision = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        isEnabled = bundle.object(forInfoDictionaryKey: "PalmiBionicCommerceEnabled") as? Bool ?? false
        trialID = (bundle.object(forInfoDictionaryKey: "PalmiBionicTrialProductID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        unlockID = (bundle.object(forInfoDictionaryKey: "PalmiBionicUnlockProductID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool { !trialID.isEmpty && !unlockID.isEmpty && trialID != unlockID }
    var canUse: Bool {
        _ = accessRevision
        if !isEnabled { return true }
        guard isConfigured, entitlementsLoaded else { return false }
        return hasFullAccess || (trialEndsAt.map { Date.now < $0 } ?? false)
    }
    var canClaimTrial: Bool {
        isEnabled && isConfigured && entitlementsLoaded && !trialWasClaimed
            && !hasFullAccess && trialProduct != nil && unlockProduct != nil
    }

    func start() async {
        guard !started else { return }
        started = true
        guard isEnabled else { entitlementsLoaded = true; return }
        guard isConfigured else {
            errorMessage = PalmiL10n.tr("bionic.purchase.configurationError")
            entitlementsLoaded = true
            return
        }
        updatesTask = Task { @MainActor [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled, let self else { return }
                switch result {
                case .verified(let transaction):
                    guard self.owns(transaction.productID) else { continue }
                    self.isPendingApproval = false
                    await self.refreshEntitlements()
                    await transaction.finish()
                case .unverified:
                    self.errorMessage = PalmiL10n.tr("bionic.purchase.verificationFailed")
                }
            }
        }
        await refreshEntitlements()
        await loadProducts()
    }

    private func owns(_ productID: String) -> Bool { productID == trialID || productID == unlockID }

    func loadProducts() async {
        guard isEnabled, isConfigured, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: [trialID, unlockID])
            guard let trial = products.first(where: { $0.id == trialID }),
                  let unlock = products.first(where: { $0.id == unlockID }),
                  trial.type == .nonConsumable, unlock.type == .nonConsumable,
                  trial.price == Decimal.zero, unlock.price > Decimal.zero else {
                trialProduct = nil
                unlockProduct = nil
                errorMessage = PalmiL10n.tr("bionic.purchase.productsUnavailable")
                return
            }
            trialProduct = trial
            unlockProduct = unlock
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        guard isEnabled else { entitlementsLoaded = true; return }
        guard isConfigured else {
            hasFullAccess = false
            trialEndsAt = nil
            entitlementsLoaded = true
            accessRevision &+= 1
            return
        }
        refreshGeneration &+= 1
        let ticket = refreshGeneration
        var full = false
        var trialEnd: Date?
        var claimed = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productType == .nonConsumable,
                  transaction.revocationDate == nil else { continue }
            if transaction.productID == unlockID { full = true }
            if transaction.productID == trialID {
                claimed = true
                trialEnd = transaction.originalPurchaseDate.addingTimeInterval(7 * 24 * 3600)
            }
        }
        if let latest = await StoreKit.Transaction.latest(for: trialID),
           case .verified(let transaction) = latest,
           transaction.productID == trialID {
            claimed = true
            if transaction.revocationDate != nil { trialEnd = nil }
        }
        guard ticket == refreshGeneration, !Task.isCancelled else { return }
        hasFullAccess = full
        trialWasClaimed = claimed
        trialEndsAt = trialEnd
        entitlementsLoaded = true
        accessRevision &+= 1
        scheduleExpiration()
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        expirationTask = nil
        guard !hasFullAccess, let end = trialEndsAt, end > Date.now else { return }
        expirationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.accessRevision &+= 1
        }
    }

    func claimTrial() async {
        guard canClaimTrial, let product = trialProduct else { return }
        await purchase(product)
    }
    func purchaseUnlock() async {
        guard !hasFullAccess, let product = unlockProduct else { return }
        await purchase(product)
    }
    private func purchase(_ product: Product) async {
        guard isEnabled, isConfigured, !isPurchasing, owns(product.id) else { return }
        isPurchasing = true
        isPendingApproval = false
        errorMessage = nil
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result,
                      transaction.productID == product.id,
                      transaction.productType == .nonConsumable else {
                    errorMessage = PalmiL10n.tr("bionic.purchase.verificationFailed")
                    return
                }
                await refreshEntitlements()
                await transaction.finish()
            case .pending:
                isPendingApproval = true
            case .userCancelled:
                break
            @unknown default:
                errorMessage = PalmiL10n.tr("bionic.purchase.purchaseFailed")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func restore() async {
        guard isEnabled, isConfigured, !isPurchasing else { return }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
