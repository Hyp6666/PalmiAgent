import SwiftUI
import PhotosUI
import UIKit

struct BionicModelBindingFields: View {
    @Bindable var store: BionicStore
    @Binding var binding: BionicObject
    @State private var modelHelp: ModelHelp?
    private enum ModelHelp: Identifiable {
        case primary, lightweight
        var id: Int { self == .primary ? 0 : 1 }
    }
    private var planOverride: ModelPlanSessionOverride { store.model.sessionOverride(binding) }
    private var plan: ModelPlanSnapshot? { store.model.plans.selectedPlan(for: planOverride) }
    private func candidate(_ key: String) -> Binding<String> {
        Binding(get: { binding.text(key) }, set: { binding[key] = $0.isEmpty ? .null : .string($0) })
    }
    // 未手动选择时直接显示方案当前生效的模型，而不是一个含糊的占位文案。
    private func resolvedTitle(_ slot: ModelPlanSlot, in plan: ModelPlanSnapshot) -> String? {
        store.model.plans.selectedCandidate(for: slot, in: plan, sessionOverride: planOverride)?.title
    }
    var body: some View {
        Section(PalmiL10n.tr("bionic.models")) {
            Picker(PalmiL10n.tr("bionic.modelPlan"), selection: Binding(get: { binding.text("plan_id") }, set: {
                binding["plan_id"] = $0.isEmpty ? .null : .string($0); binding["primary_candidate_id"] = .null; binding["lightweight_candidate_id"] = .null
            })) {
                Text(PalmiL10n.tr("bionic.followActivePlan")).tag("")
                ForEach(store.model.plans.plans) { Text($0.name).tag($0.id.uuidString.lowercased()) }
            }
            if let plan {
                modelRow(PalmiL10n.tr("bionic.primaryModel"), help: .primary, slot: .primary, key: "primary_candidate_id", plan: plan)
                modelRow(PalmiL10n.tr("bionic.lightweightModel"), help: .lightweight, slot: .lightweight, key: "lightweight_candidate_id", plan: plan)
            }
        }
        .alert(item: $modelHelp) { topic in
            Alert(title: Text(PalmiL10n.tr(topic == .primary ? "bionic.primaryModel" : "bionic.lightweightModel")),
                  message: Text(PalmiL10n.tr(topic == .primary ? "bionic.primaryModelHelp" : "bionic.lightweightModelHelp")),
                  dismissButton: .default(Text(PalmiL10n.tr("bionic.ok"))))
        }
    }
    @ViewBuilder private func modelRow(_ title: String, help: ModelHelp, slot: ModelPlanSlot, key: String, plan: ModelPlanSnapshot) -> some View {
        HStack {
            Text(title)
            Button { modelHelp = help } label: {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            Spacer()
            Picker(title, selection: candidate(key)) {
                Text(resolvedTitle(slot, in: plan) ?? PalmiL10n.tr("bionic.followActivePlan")).tag("")
                ForEach(plan.candidates) { Text($0.title).tag($0.id.uuidString.lowercased()) }
            }
            .labelsHidden()
        }
    }
}

struct BionicSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BionicStore
    let instance: String
    @State private var binding: BionicObject = [:]
    @State private var proactive = false
    @State private var evolution = false
    @State private var context = 200000
    @State private var output = 8192
    @State private var loaded = false
    @State private var busy = false
    @State private var editing = false
    @State private var deleting = false
    @State private var errorText: String?
    @FocusState private var focusedField: BionicSettingsField?
    private enum BionicSettingsField: Hashable { case context, output }
    private var role: BionicRole? { store.roles.first { $0.installationID == instance } }
    var body: some View {
        Form {
            if let role {
                Section(PalmiL10n.tr("bionic.profile")) {
                    LabeledContent(PalmiL10n.tr("bionic.nickname"), value: role.name)
                    LabeledContent(PalmiL10n.tr("bionic.nativeLanguage"), value: BionicPersonaCatalog.languageNames[role.persona.text("native_language")] ?? "")
                    LabeledContent(PalmiL10n.tr("bionic.birthDate"), value: role.persona.text("birth_date"))
                    Button(PalmiL10n.tr("bionic.editPersona")) { editing = true }
                }
            }
            Section {
                Toggle(PalmiL10n.tr("bionic.proactive"), isOn: $proactive)
                Toggle(PalmiL10n.tr("bionic.evolution"), isOn: $evolution)
                Text(PalmiL10n.tr("bionic.evolutionNotice")).font(.footnote).foregroundStyle(.secondary)
            }
            BionicModelBindingFields(store: store, binding: $binding)
            Section(PalmiL10n.tr("bionic.contextSettings")) {
                HStack { Text(PalmiL10n.tr("bionic.contextLimit")); Spacer(); TextField("200000", value: $context, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($focusedField, equals: .context).bionicInputField() }
                HStack { Text(PalmiL10n.tr("bionic.outputLimit")); Spacer(); TextField("8192", value: $output, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($focusedField, equals: .output).bionicInputField() }
                Text(PalmiL10n.tr("bionic.contextNotice")).font(.footnote).foregroundStyle(.secondary)
            }
            Section(PalmiL10n.tr("bionic.localPreferences")) {
                Toggle(PalmiL10n.tr("bionic.notifications"), isOn: Binding(get: { binding.flag("notifications_enabled") }, set: { value in
                    binding["notifications_enabled"] = .bool(value)
                    Task { do { try await store.notifications.enable(instance, enabled: value) } catch { errorText = BionicStore.errorText(error) } }
                }))
                Toggle(PalmiL10n.tr("bionic.showDeveloper"), isOn: Binding(get: { binding.flag("developer_visible") }, set: { binding["developer_visible"] = .bool($0) }))
                Button(PalmiL10n.tr("bionic.systemNotificationSettings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Section { Text(PalmiL10n.tr("bionic.disclosure")).font(.footnote).foregroundStyle(.secondary) }
            Section { Button(PalmiL10n.tr("bionic.deleteRole"), role: .destructive) { deleting = true } }
        }
        .scrollDismissesKeyboard(.interactively)
        .bionicKeyboardDismissOnOutsideTap()
        .disabled(!loaded || busy)
        .navigationTitle(PalmiL10n.tr("bionic.settings"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("bionic.close")) { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button(PalmiL10n.tr("bionic.save")) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await store.saveSettings(instance, proactive: proactive, evolution: evolution, context: context, output: output, binding: binding); dismiss() }
                        catch { errorText = BionicStore.errorText(error) }
                    }
                }.disabled(!loaded || busy)
            }
        }
        .task { await load() }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) { NavigationStack { BionicPersonaEditor(store: store, instance: instance) } }
        .confirmationDialog(PalmiL10n.tr("bionic.deleteRole"), isPresented: $deleting, titleVisibility: .visible) {
            Button(PalmiL10n.tr("bionic.delete"), role: .destructive) {
                busy = true
                Task {
                    defer { busy = false }
                    do { try await store.delete(instance); dismiss() } catch { errorText = BionicStore.errorText(error) }
                }
            }
        } message: { Text(PalmiL10n.tr("bionic.deleteRoleNotice")) }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} } message: { Text(errorText ?? "") }
    }
    private func load() async {
        do {
            let role = try await store.archive.loadRole(instance); binding = try await store.archive.binding(instance)
            proactive = role.persona.flag("proactive_enabled") && binding.flag("contact_resume_allowed") && (binding["contact_resume_allowed"]?.bool ?? true)
            evolution = role.persona.flag("evolution_enabled"); context = role.persona.int("context_limit"); output = role.persona.int("output_limit"); loaded = true
        } catch { errorText = BionicStore.errorText(error) }
    }
}

struct BionicMigrationScreen: View {
    private struct Share: Identifiable { let id = UUID(); let url: URL }
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BionicStore
    let instance: String
    @State private var exporting = false
    @State private var confirmation = false
    @State private var share: Share?
    @State private var sharedURL: URL?
    @State private var errorText: String?
    var body: some View {
        Form {
            Section { Text(PalmiL10n.tr("bionic.exportNotice")) }
            Section {
                if exporting { ProgressView(PalmiL10n.tr("bionic.exporting")) }
                Button(PalmiL10n.tr("bionic.export")) { confirmation = true }.disabled(exporting)
            }
            Section { Text(PalmiL10n.tr("bionic.importHomeNotice")).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.migration"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("bionic.close")) { dismiss() }.disabled(exporting) } }
        .confirmationDialog(PalmiL10n.tr("bionic.export"), isPresented: $confirmation, titleVisibility: .visible) {
            Button(PalmiL10n.tr("bionic.confirmExport")) {
                exporting = true
                Task {
                    defer { exporting = false }
                    do { let url = try await store.migration.export(instance); sharedURL = url; share = Share(url: url) }
                    catch { errorText = BionicStore.errorText(error) }
                }
            }
        } message: { Text(PalmiL10n.tr("bionic.exportNotice")) }
        .sheet(item: $share, onDismiss: {
            if let url = sharedURL { store.migration.finishSharing(url); sharedURL = nil }
        }) { item in BionicShareSheet(url: item.url) }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} } message: { Text(errorText ?? "") }
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

struct BionicDeveloperScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BionicStore
    let instance: String
    @State private var content = ""
    @State private var errorText: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(PalmiL10n.tr("bionic.developerNotice")).font(.footnote).foregroundStyle(.secondary)
                Text(verbatim: content).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16)
        }
        .navigationTitle(PalmiL10n.tr("bionic.developer"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("bionic.close")) { dismiss() } }
            ToolbarItem(placement: .primaryAction) { Button(PalmiL10n.tr("bionic.refresh"), systemImage: "arrow.clockwise") { Task { await load() } } }
        }
        .task {
            while !Task.isCancelled { await load(); try? await Task.sleep(for: .seconds(1)) }
        }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} } message: { Text(errorText ?? "") }
    }
    private func load() async { do { content = try await store.debugText(instance) } catch { errorText = BionicStore.errorText(error) } }
}

private struct BionicShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
