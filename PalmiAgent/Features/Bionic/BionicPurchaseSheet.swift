import SwiftUI
import StoreKit

struct BionicPurchaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var purchases: BionicPurchaseStore
    var body: some View {
        NavigationStack {
            BionicProScreen(purchases: purchases)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(PalmiL10n.tr("common.done")) { dismiss() }
                    }
                }
        }
    }
}

/// The same destination is used by Settings, the add menu, and locked features.
struct BionicProScreen: View {
    @Bindable var purchases: BionicPurchaseStore
    @State private var selection = 1
    @State private var helpKey: String?
    @State private var helpTitle = ""
    @State private var showsIntroduction = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                planPage(pro: false).tag(0)
                planPage(pro: true).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilityIdentifier("bionic.pro.plans")

            Picker(PalmiL10n.tr("bionic.pro.title"), selection: $selection.animation(.easeInOut(duration: 0.25))) {
                Text(PalmiL10n.tr("bionic.pro.basic")).tag(0)
                Text(PalmiL10n.tr("bionic.pro.name")).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(6)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(PalmiL10n.tr("bionic.pro.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(helpTitle, isPresented: Binding(
            get: { helpKey != nil },
            set: { if !$0 { helpKey = nil } }
        )) {
            Button(PalmiL10n.tr("common.done"), role: .cancel) { helpKey = nil }
        } message: {
            Text(PalmiL10n.tr(helpKey ?? "bionic.pro.help.mode"))
        }
        .sheet(isPresented: $showsIntroduction) {
            NavigationStack {
                BionicIntroductionScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(PalmiL10n.tr("common.done")) { showsIntroduction = false }
                        }
                    }
            }
        }
        .task { await purchases.start(); await purchases.loadProducts() }
    }

    private func planPage(pro: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(PalmiL10n.tr(pro ? "bionic.pro.name" : "bionic.pro.basic"))
                    .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if pro {
                        if purchases.hasFullAccess {
                            Text(PalmiL10n.tr("bionic.pro.owned")).font(.headline).foregroundStyle(.blue)
                        } else {
                            if let product = purchases.unlockProduct {
                                Text(product.displayPrice).font(.title2.bold())
                            }
                            Text(PalmiL10n.tr("bionic.pro.oneTime"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(PalmiL10n.tr("bionic.pro.free")).font(.title2.bold())
                    }
                }
                .frame(minHeight: 32, alignment: .leading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(PalmiL10n.tr("bionic.pro.benefits"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    feature("bionic.pro.mode", symbol: "bubble.left.and.bubble.right", help: "mode")
                    feature(pro ? "bionic.pro.roles99" : "bionic.pro.roles2", symbol: "person.2", help: pro ? "roles99" : "roles2")
                    feature("bionic.pro.memory", symbol: "brain", help: "memory")
                    feature("bionic.pro.harness", symbol: "point.3.connected.trianglepath.dotted", help: "harness")
                    feature("bionic.pro.longChat", symbol: "infinity", help: "longChat")
                    if !pro {
                        feature("bionic.pro.memorySummary", symbol: "text.alignleft")
                    }
                    feature("bionic.pro.diaryGeneration", symbol: "book", help: "diaryGeneration")
                    if pro {
                        feature("bionic.pro.memoryDetails", symbol: "doc.text.magnifyingglass", help: "memoryDetails")
                        feature("bionic.pro.memoryJump", symbol: "arrow.turn.up.right", help: "memoryJump")
                        feature("bionic.pro.memoryEdit", symbol: "square.and.pencil")
                        feature("bionic.pro.diary", symbol: "book.closed", help: "diary")
                        feature("bionic.pro.developer", symbol: "slider.horizontal.3", help: "developer")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)

            if pro {
                purchaseControls
            } else {
                VStack(spacing: 14) {
                    entitlementStatus(purchases.hasFullAccess ? "bionic.pro.covered" : "bionic.pro.current")
                    // Match the restore row's space without presenting an inactive control.
                    Text(PalmiL10n.tr("bionic.purchase.restore")).font(.subheadline).hidden()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
        .padding(.horizontal, 20).padding(.top, 14)
        .frame(maxWidth: .infinity)
    }

    private func entitlementStatus(_ key: String) -> some View {
        Text(PalmiL10n.tr(key))
            .font(.headline)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(.blue, in: .capsule)
    }

    private func feature(_ key: String, symbol: String, help: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).resizable().scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24).accessibilityHidden(true)
            Text(PalmiL10n.tr(key)).font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let help {
                Button {
                    if help == "mode" {
                        showsIntroduction = true
                    } else {
                        helpTitle = PalmiL10n.tr(key)
                        helpKey = "bionic.pro.help." + help
                    }
                } label: {
                    Image(systemName: "questionmark.circle").font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PalmiL10n.tr("bionic.pro.help.label", PalmiL10n.tr(key)))
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue).frame(height: 24).accessibilityHidden(true)
        }.padding(.vertical, 9)
    }

    private var purchaseControls: some View {
        VStack(spacing: 14) {
            if purchases.hasFullAccess {
                entitlementStatus("bionic.pro.current")
            } else {
                Button {
                    Task { await purchases.purchaseUnlock() }
                } label: {
                    HStack {
                        if purchases.isPurchasing { ProgressView().tint(.white) }
                        Text(purchases.unlockProduct.map { PalmiL10n.tr("bionic.pro.buy", $0.displayPrice) }
                             ?? PalmiL10n.tr("bionic.pro.get"))
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .background(.blue, in: .capsule)
                    .opacity(purchases.unlockProduct == nil || !purchases.entitlementsLoaded || purchases.isPurchasing ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(purchases.unlockProduct == nil || !purchases.entitlementsLoaded || purchases.isPurchasing)
                .accessibilityIdentifier("bionic.pro.purchase")
            }
            Button(PalmiL10n.tr("bionic.purchase.restore")) { Task { await purchases.restore() } }
                .font(.subheadline).disabled(purchases.isPurchasing || !purchases.isConfigured)
            if purchases.isLoadingProducts { ProgressView() }
            if purchases.isPendingApproval { Text(PalmiL10n.tr("bionic.purchase.pending")).font(.footnote) }
            if let message = purchases.statusMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if let error = purchases.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button(PalmiL10n.tr("bionic.retry")) { Task { await purchases.loadProducts() } }
                    .font(.subheadline).disabled(purchases.isPurchasing)
            }
        }.frame(maxWidth: .infinity)
    }
}

/// A locked destination never loads its protected content before authorization.
struct BionicProGate<Content: View>: View {
    let purchases: BionicPurchaseStore
    @ViewBuilder let content: () -> Content
    var body: some View {
        if purchases.hasFullAccess { content() }
        else { BionicProScreen(purchases: purchases) }
    }
}
