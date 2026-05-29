import SwiftUI

struct WebSearchProviderSettingsScreen: View {
    @State private var enabledProviderIDs = WebSearchProviderSettings.enabledProviderIDs()

    var body: some View {
        List {
            Section {
                ForEach(WebSearchProviderID.allCases) { providerID in
                    HStack(spacing: 14) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 28)

                        Text(providerID.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 12)

                        Toggle("", isOn: Binding(
                            get: { enabledProviderIDs.contains(providerID) },
                            set: { newValue in
                                WebSearchProviderSettings.setEnabled(newValue, providerID: providerID)
                                enabledProviderIDs = WebSearchProviderSettings.enabledProviderIDs()
                            }
                        ))
                        .labelsHidden()
                        .tint(.green)
                        .disabled(!canDisable(providerID))
                    }
                    .padding(.vertical, 6)
                    .opacity(canDisable(providerID) ? 1 : 0.72)
                }
            }
        }
        .navigationTitle("搜索源")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            enabledProviderIDs = WebSearchProviderSettings.enabledProviderIDs()
        }
    }

    private func canDisable(_ providerID: WebSearchProviderID) -> Bool {
        enabledProviderIDs.count > 1 || !enabledProviderIDs.contains(providerID)
    }
}
