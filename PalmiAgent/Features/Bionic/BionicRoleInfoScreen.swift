import SwiftUI

struct BionicRoleInfoScreen: View {
    @Bindable var store: BionicStore
    let instance: String

    private var role: BionicRole? {
        store.roles.first { $0.installationID == instance }
    }

    var body: some View {
        List {
            if let role {
                Section {
                    HStack(spacing: 18) {
                        BionicAvatar(data: store.avatars[instance + ":" + role.characterID],
                                     name: role.name, size: 76)
                        Text(role.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                }

                Section {
                    infoRow(PalmiL10n.tr("bionic.identity"), value: role.persona.text("identity"))
                    if let age = try? BionicPersonaCatalog.age(role.persona.text("birth_date")) {
                        infoRow(PalmiL10n.tr("bionic.profileAge"), value: String(age))
                    }
                    if let gender = gender(role.persona) {
                        infoRow(PalmiL10n.tr("bionic.gender"), value: gender)
                    }
                    infoRow(PalmiL10n.tr("bionic.nativeLanguage"), value:
                        BionicPersonaCatalog.languageNames[role.persona.text("native_language")] ?? "")
                    if let mbti = role.persona.optionalText("mbti"), !mbti.isEmpty {
                        infoRow("MBTI", value: mbti)
                    }
                }

                Section(PalmiL10n.tr("bionic.personality")) {
                    ForEach(BionicPersonaCatalog.dimensions, id: \.self) { dimension in
                        let level = min(5, max(1, role.persona.object("current_traits").int(dimension)))
                        infoRow(PalmiL10n.tr("bionic.trait." + dimension),
                                value: PalmiL10n.tr("bionic.trait.\(dimension).\(level)"))
                    }
                }

                if !role.persona.text("background").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(PalmiL10n.tr("bionic.background")) {
                        Text(role.persona.text("background"))
                            .font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }

                Section {
                    NavigationLink {
                        BionicSettingsScreen(store: store, instance: instance)
                    } label: {
                        Label(PalmiL10n.tr("bionic.settings"), systemImage: "person.crop.circle")
                    }
                }
            } else {
                ContentUnavailableView(PalmiL10n.tr("bionic.error.roleMissing"), systemImage: "person.crop.circle")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("bionic.roleInfo"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh(changed: instance) }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        } label: { Text(title) }
    }

    private func gender(_ persona: BionicObject) -> String? {
        switch persona.text("gender_kind") {
        case "male": PalmiL10n.tr("bionic.male")
        case "female": PalmiL10n.tr("bionic.female")
        case "custom": persona.text("gender_text")
        default: nil
        }
    }
}
