import SwiftUI
import PhotosUI
import UIKit

struct BionicModelBindingFields: View {
    @Bindable var store: BionicStore
    @Binding var binding: BionicObject
    @State private var modelHelp: String?
    private var planOverride: ModelPlanSessionOverride { store.model.sessionOverride(binding) }
    private var plan: ModelPlanSnapshot? { store.model.plans.selectedPlan(for: planOverride) }
    private func candidate(_ key: String) -> Binding<String> {
        Binding(get: { binding.text(key) }, set: { binding[key] = $0.isEmpty ? .null : .string($0) })
    }
    var body: some View {
        Section(PalmiL10n.tr("bionic.models")) {
            Picker(PalmiL10n.tr("bionic.modelPlan"), selection: Binding(get: { binding.text("plan_id") }, set: {
                binding["plan_id"] = $0.isEmpty ? .null : .string($0)
                binding["primary_candidate_id"] = .null
                binding["multimodal_candidate_id"] = .null
                binding["lightweight_candidate_id"] = .null
            })) {
                Text(PalmiL10n.tr("bionic.followActivePlan")).tag("")
                ForEach(store.model.plans.plans) { Text($0.name).tag($0.id.uuidString.lowercased()) }
            }
            if let plan {
                modelRow(title: "bionic.primaryModel", help: "bionic.primaryModelHelp", slot: .primary, key: "primary_candidate_id", plan: plan)
                modelRow(title: "bionic.visionModel", help: "bionic.visionModelHelp", slot: .multimodal, key: "multimodal_candidate_id", plan: plan)
                modelRow(title: "bionic.lightweightModel", help: "bionic.lightweightModelHelp", slot: .lightweight, key: "lightweight_candidate_id", plan: plan)
            }
        }
        .alert(PalmiL10n.tr("bionic.models"), isPresented: Binding(get: { modelHelp != nil }, set: { if !$0 { modelHelp = nil } })) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {}
        } message: { Text(PalmiL10n.tr(modelHelp ?? "bionic.models")) }
    }
    private func modelRow(title: String, help: String, slot: ModelPlanSlot, key: String, plan: ModelPlanSnapshot) -> some View {
        HStack {
            Text(PalmiL10n.tr(title))
            Button { modelHelp = help } label: { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
                .buttonStyle(.plain).accessibilityLabel(PalmiL10n.tr(title))
            Spacer()
            Picker(PalmiL10n.tr(title), selection: candidate(key)) {
                Text(store.model.plans.selectedCandidate(for: slot, in: plan, sessionOverride: planOverride)?.title ?? PalmiL10n.tr("bionic.followActivePlan")).tag("")
                ForEach(plan.candidates) { Text($0.title).tag($0.id.uuidString.lowercased()) }
            }.labelsHidden()
        }
    }
}

struct BionicSettingsScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    var body: some View { BionicPersonaEditor(store: store, instance: instance) }
}

struct BionicMigrationScreen: View {
    private struct Share: Identifiable { let id = UUID(); let url: URL }
    @Bindable var store: BionicStore
    let instance: String
    @State private var exporting = false
    @State private var confirmation = false
    @State private var share: Share?
    @State private var sharedURL: URL?
    @State private var errorText: String?
    var body: some View {
        List {
            Button { confirmation = true } label: {
                HStack {
                    Label(PalmiL10n.tr("bionic.export"), systemImage: "square.and.arrow.up")
                    Spacer()
                    if exporting { ProgressView() }
                }
            }
            .disabled(exporting)
            .alert(PalmiL10n.tr("bionic.export"), isPresented: $confirmation) {
                Button(PalmiL10n.tr("bionic.confirmExport")) {
                    exporting = true
                    Task {
                        defer { exporting = false }
                        do {
                            let url = try await store.migration.export(instance)
                            sharedURL = url; share = Share(url: url)
                        } catch { errorText = BionicStore.errorText(error) }
                    }
                }
                Button(PalmiL10n.tr("bionic.cancel"), role: .cancel) { confirmation = false }
            } message: { Text(PalmiL10n.tr("bionic.exportPrivacy")) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.migration")).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share, onDismiss: {
            if let url = sharedURL { store.migration.finishSharing(url); sharedURL = nil }
        }) { item in BionicShareSheet(url: item.url) }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }
}

struct BionicImportScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BionicStore
    let prepared: BionicMigrationService.PreparedImport
    @State private var mode = "same_person"
    @State private var name = ""
    @State private var avatar: Data?
    @State private var photo: PhotosPickerItem?
    @State private var crop: CropInput?
    @State private var continueContact = false
    @State private var binding: BionicObject = [:]
    @State private var busy = false
    @State private var installed = false
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool
    private struct CropInput: Identifiable { let id = UUID(); let image: UIImage }
    var body: some View {
        Form {
            Section(PalmiL10n.tr("bionic.profile")) {
                LabeledContent(PalmiL10n.tr("bionic.nickname"), value: prepared.role.name)
                LabeledContent(PalmiL10n.tr("bionic.nativeLanguage"), value: BionicPersonaCatalog.languageNames[prepared.role.persona.text("native_language")] ?? "")
                LabeledContent(PalmiL10n.tr("bionic.messageCount"), value: String(prepared.role.state.order.count))
                LabeledContent(PalmiL10n.tr("bionic.memoryCount"), value: String(prepared.role.state.raw.object("confirmed_memory_revision_ids").count))
                Text(PalmiL10n.tr("bionic.importNotice")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker(PalmiL10n.tr("bionic.importMode"), selection: $mode) {
                    Text(PalmiL10n.tr("bionic.samePerson")).tag("same_person")
                    Text(PalmiL10n.tr("bionic.newPerson")).tag("new_person")
                }
                if mode == "new_person" {
                    TextField(PalmiL10n.tr("bionic.myName"), text: $name)
                        .focused($nameFocused).bionicInputField()
                    HStack { BionicAvatar(data: avatar, name: name, size: 44); PhotosPicker(selection: $photo, matching: .images) { Text(PalmiL10n.tr("bionic.chooseAvatar")) } }
                    Text(PalmiL10n.tr("bionic.newPersonNotice")).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle(PalmiL10n.tr("bionic.resumeContact"), isOn: $continueContact)
            }
            BionicModelBindingFields(store: store, binding: $binding)
            Section {
                if busy { ProgressView(PalmiL10n.tr("bionic.importing")) }
                Button(PalmiL10n.tr("bionic.validateAndImport")) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let role = try await store.migration.install(prepared, mode: mode, name: name, avatar: avatar, binding: binding, continueContact: continueContact, language: PalmiLanguage.current.rawValue)
                            installed = true; await store.refresh(); await store.open(role.installationID); dismiss()
                        } catch { errorText = BionicStore.errorText(error) }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .bionicKeyboardDismissOnOutsideTap()
        .disabled(busy)
        .navigationTitle(PalmiL10n.tr("bionic.import"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("bionic.cancel")) { dismiss() }.disabled(busy) } }
        .onAppear { if binding.isEmpty { binding = store.model.defaultBinding() } }
        .onDisappear { if !installed && !busy { store.migration.discard(prepared) } }
        .interactiveDismissDisabled(busy)
        .onChange(of: photo) { _, item in
            Task {
                do {
                    guard let raw = try await item?.loadTransferable(type: Data.self),
                          let image = UIImage(data: raw), image.size.width > 0, image.size.height > 0 else { return }
                    crop = CropInput(image: image)
                } catch { errorText = BionicStore.errorText(error) }
            }
        }
        .sheet(item: $crop) { input in
            NavigationStack { BionicAvatarCropView(image: input.image) { data in avatar = data } }
        }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} } message: { Text(errorText ?? "") }
    }
}

private struct BionicShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
