import SwiftUI
import UIKit

/// Shared by creation and editing; no second nested settings form.
struct BionicRuntimeSettingsFields: View {
    @Binding var persona: BionicObject
    @Binding var local: BionicObject
    private func number(_ key: String, fallback: Int) -> Binding<Int> {
        Binding(get: { persona[key]?.int ?? fallback }, set: { persona[key] = .count($0) })
    }
    private func flag(_ key: String, fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { local[key]?.bool ?? fallback }, set: { local[key] = .bool($0) })
    }
    var body: some View {
        Section(PalmiL10n.tr("bionic.replyTiming")) {
            Picker(PalmiL10n.tr("bionic.replyTiming"), selection: Binding(
                get: { BionicReplyTiming.resolve(persona).rawValue },
                set: { persona["reply_timing"] = .string($0) })) {
                Text(PalmiL10n.tr("bionic.replyTiming.instant")).tag(BionicReplyTiming.instant.rawValue)
                Text(PalmiL10n.tr("bionic.replyTiming.natural")).tag(BionicReplyTiming.natural.rawValue)
            }.pickerStyle(.segmented).labelsHidden()
        }
        Section(PalmiL10n.tr("bionic.contextSettings")) {
            HStack {
                Text(PalmiL10n.tr("bionic.contextLimit")); Spacer()
                TextField("200000", value: number("context_limit", fallback: 200000), format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 140).bionicInputField()
            }
            HStack {
                Text(PalmiL10n.tr("bionic.outputLimit")); Spacer()
                TextField("8192", value: number("output_limit", fallback: 8192), format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 140).bionicInputField()
            }
        }
        Section(PalmiL10n.tr("bionic.localPreferences")) {
            Toggle(PalmiL10n.tr("bionic.notifications"), isOn: flag("notifications_enabled"))
            Toggle(PalmiL10n.tr("bionic.showDeveloper"), isOn: flag("developer_visible", fallback: true))
            Button(PalmiL10n.tr("bionic.systemNotificationSettings")) {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        }
    }
}
