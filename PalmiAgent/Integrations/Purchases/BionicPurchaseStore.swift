import Foundation
import Observation
import StoreKit

@MainActor @Observable
final class BionicPurchaseStore {
    let access: BionicAccessState
    private let unlockID: String
    private(set) var unlockProduct: Product?
    private(set) var hasFullAccess = false
    private(set) var entitlementsLoaded = false
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var isPendingApproval = false
    var errorMessage: String?
    private(set) var statusMessage: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(bundle: Bundle = .main, access: BionicAccessState = BionicAccessState()) {
        self.access = access
        unlockID = (bundle.object(forInfoDictionaryKey: "PalmiBionicUnlockProductID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var isConfigured: Bool { !unlockID.isEmpty }

    func start() async {
        guard !started else { return }
        started = true
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
                    guard transaction.productID == self.unlockID else { continue }
                    self.isPendingApproval = false
                    await self.refreshEntitlements()
                    await transaction.finish()
                case .unverified(let transaction, _):
                    guard transaction.productID == self.unlockID else { continue }
                    self.errorMessage = PalmiL10n.tr("bionic.purchase.verificationFailed")
                    await self.refreshEntitlements()
                }
            }
        }
        await refreshEntitlements()
        await loadProducts()
    }

    func loadProducts() async {
        guard isConfigured, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: [unlockID])
            guard let unlock = products.first(where: { $0.id == unlockID }),
                  unlock.type == .nonConsumable else {
                unlockProduct = nil
                errorMessage = PalmiL10n.tr("bionic.purchase.productsUnavailable")
                return
            }
            unlockProduct = unlock
            errorMessage = nil
        } catch {
            unlockProduct = nil
            errorMessage = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        refreshGeneration &+= 1
        let ticket = refreshGeneration
        var full = false
        if isConfigured {
            for await result in StoreKit.Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      transaction.productID == unlockID,
                      transaction.productType == .nonConsumable,
                      transaction.revocationDate == nil,
                      !transaction.isUpgraded else { continue }
                full = true
            }
        }
        guard ticket == refreshGeneration, !Task.isCancelled else { return }
        // An empty verified entitlement set revokes Pro; it never deletes roles.
        access.replaceVerifiedEntitlement(full)
        hasFullAccess = full
        entitlementsLoaded = true
    }

    func purchaseUnlock() async {
        guard isConfigured, entitlementsLoaded, !hasFullAccess,
              !isPurchasing, let product = unlockProduct else { return }
        isPurchasing = true
        isPendingApproval = false
        errorMessage = nil
        statusMessage = nil
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result,
                      transaction.productID == unlockID,
                      transaction.productType == .nonConsumable,
                      transaction.revocationDate == nil else {
                    errorMessage = PalmiL10n.tr("bionic.purchase.verificationFailed")
                    return
                }
                await refreshEntitlements()
                await transaction.finish()
            case .pending: isPendingApproval = true
            case .userCancelled: break
            @unknown default: errorMessage = PalmiL10n.tr("bionic.purchase.purchaseFailed")
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func restore() async {
        guard isConfigured, !isPurchasing else { return }
        isPurchasing = true
        errorMessage = nil
        statusMessage = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            statusMessage = PalmiL10n.tr(hasFullAccess ? "bionic.pro.restored" : "bionic.pro.noPurchase")
        } catch { errorMessage = error.localizedDescription }
    }
}
