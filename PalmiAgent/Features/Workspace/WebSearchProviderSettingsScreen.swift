import SwiftUI

struct WebSearchProviderSettingsScreen: View {
    @State private var selectedProviderID = WebSearchProviderSettings.selectedProviderID()

    var body: some View {
        List {
            Section {
                Picker("", selection: $selectedProviderID) {
                    ForEach(WebSearchProviderID.allCases) { providerID in
                        Text(providerID.localizedTitleForUI)
                            .tag(providerID)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle(PalmiL10n.tr("searchConfiguration.local.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedProviderID = WebSearchProviderSettings.selectedProviderID()
        }
        .onChange(of: selectedProviderID) { _, providerID in
            WebSearchProviderSettings.setSelectedProviderID(providerID)
        }
    }
}
