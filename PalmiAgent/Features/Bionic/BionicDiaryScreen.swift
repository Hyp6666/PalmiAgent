import SwiftUI

struct BionicDiaryScreen: View {
    let store: BionicStore
    let instance: String
    @State private var entries: [BionicDiaryEntry] = []
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        BionicProGate(purchases: store.purchases) { diaryContent }
    }
    private var diaryContent: some View {
        List {
            if !loaded { ProgressView().frame(maxWidth: .infinity) }
            else if entries.isEmpty {
                ContentUnavailableView(PalmiL10n.tr("bionic.diary.empty"), systemImage: "book.closed")
            }
            ForEach(entries) { entry in
                NavigationLink {
                    ScrollView {
                        Text(entry.text).font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                    .navigationTitle(entry.day)
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Text(entry.day).font(.body)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("bionic.diary.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.diagnosticRevision) {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let values = try await store.archive.userDiaryEntries(instance)
                try Task.checkCancellation()
                entries = Array(values.reversed()); loaded = true
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = BionicStore.errorText(error); loaded = true } }
        }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) { } }
        message: { Text(error ?? "") }
    }
}
