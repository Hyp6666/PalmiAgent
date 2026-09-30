import SwiftUI
import SafariServices
import UIKit

struct ChatGPTOAuthScreen: View {
    @Bindable var planStore: ModelPlanStore
    @State private var account = ChatGPTAccountStore.shared
    @State private var showBrowser = false
    @State private var busy = false
    @State private var copiedCode: String?
    @State private var signOutConfirmation = false
    @State private var error: String?
    var body: some View {
        List {
            if let active = account.account {
                Section {
                    LabeledContent("Codex OAuth", value: active.email.isEmpty ? active.accountID : active.email)
                    Button(PalmiL10n.tr("chatgpt.refreshModels")) { Task { await refresh() } }.disabled(busy)
                    Button(PalmiL10n.tr("chatgpt.signOut"), role: .destructive) { signOutConfirmation = true }.disabled(busy)
                }
            } else if !account.signingIn {
                Button(PalmiL10n.tr("chatgpt.signIn")) {
                    Task { await account.signIn(); if account.account != nil { await refresh() } }
                }
            }
            if let challenge = account.challenge {
                Section {
                    Text(challenge.code).font(.title2.monospaced().bold()).textSelection(.enabled)
                    Button(
                        PalmiL10n.tr(copiedCode == challenge.code ? "chat.code.copied" : "chatgpt.copyCode"),
                        systemImage: copiedCode == challenge.code ? "checkmark" : "doc.on.doc"
                    ) {
                        UIPasteboard.general.string = challenge.code
                        copiedCode = challenge.code
                    }
                    .buttonStyle(.borderless)
                    Button(PalmiL10n.tr("chatgpt.openSignIn")) { showBrowser = true }
                    Button(PalmiL10n.tr("common.cancel"), role: .cancel) { account.cancelSignIn() }
                }
            }
            if busy || account.signingIn { ProgressView().frame(maxWidth: .infinity) }
        }
        .navigationTitle("Codex OAuth").navigationBarTitleDisplayMode(.inline)
        .task(id: copiedCode) {
            guard copiedCode != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedCode = nil
        }
        .sheet(isPresented: $showBrowser) { ChatGPTSignInBrowser() }
        .onChange(of: account.account) { _, value in if value != nil { showBrowser = false } }
        .onDisappear { if !showBrowser && account.signingIn { account.cancelSignIn() } }
        .confirmationDialog(PalmiL10n.tr("chatgpt.signOut"), isPresented: $signOutConfirmation) {
            Button(PalmiL10n.tr("chatgpt.signOut"), role: .destructive) {
                do { try account.signOut() } catch { self.error = error.localizedDescription }
            }
        }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(
            get: { error != nil || account.errorMessage != nil },
            set: { if !$0 { error = nil; account.errorMessage = nil } }
        )) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} }
        message: { Text(error ?? account.errorMessage ?? "") }
    }
    private func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let list = try await account.refreshCatalog()
            guard let active = account.account else { return }
            try planStore.importChatGPTModels(list, account: active)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
private struct ChatGPTSignInBrowser: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: ChatGPTAccountStore.verificationURL) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
