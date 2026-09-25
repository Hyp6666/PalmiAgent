import SwiftUI
import StoreKit

struct BionicPurchaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var purchases: BionicPurchaseStore
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if purchases.hasFullAccess {
                        Label(PalmiL10n.tr("bionic.purchase.unlocked"), systemImage: "checkmark.seal.fill")
                    } else if let end = purchases.trialEndsAt, purchases.canUse {
                        LabeledContent(PalmiL10n.tr("bionic.purchase.trialEnds")) {
                            Text(end, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                    Text(PalmiL10n.tr("bionic.purchase.disclosure"))
                        .font(.body)
                    if let product = purchases.unlockProduct {
                        LabeledContent(PalmiL10n.tr("bionic.purchase.fullUnlock"), value: product.displayPrice)
                    }
                }
                Section {
                    if purchases.canClaimTrial {
                        Button(PalmiL10n.tr("bionic.purchase.startTrial")) {
                            Task { await purchases.claimTrial() }
                        }
                    }
                    if !purchases.hasFullAccess, let product = purchases.unlockProduct {
                        Button(PalmiL10n.tr("bionic.purchase.buy", product.displayPrice)) {
                            Task { await purchases.purchaseUnlock() }
                        }
                    }
                    Button(PalmiL10n.tr("bionic.purchase.restore")) {
                        Task { await purchases.restore() }
                    }
                    .disabled(!purchases.isConfigured)
                    if purchases.isPurchasing || purchases.isLoadingProducts { ProgressView() }
                    if purchases.isPendingApproval { Text(PalmiL10n.tr("bionic.purchase.pending")) }
                }
                .disabled(purchases.isPurchasing)
                if let error = purchases.errorMessage {
                    Section {
                        Text(error)
                        Button(PalmiL10n.tr("bionic.retry")) { Task { await purchases.loadProducts() } }
                    }
                }
            }
            .navigationTitle(PalmiL10n.tr("bionic.purchase.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(PalmiL10n.tr("bionic.purchase.done")) { dismiss() }
                }
            }
            .task { await purchases.start(); await purchases.loadProducts() }
            .onChange(of: purchases.canUse) { before, after in
                if !before && after { dismiss() }
            }
        }
    }
}
