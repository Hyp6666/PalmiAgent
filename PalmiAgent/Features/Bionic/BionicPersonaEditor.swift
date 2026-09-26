import SwiftUI
import PhotosUI
import UIKit

struct BionicPersonaEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BionicStore
    let instance: String?
    @State private var persona: BionicObject
    @State private var original: BionicObject?
    @State private var binding: BionicObject
    @State private var participant: BionicObject
    @State private var assets: [String: Data] = [:]
    // 核验暂时停用（调试期）：audit 状态与 verify() 保留在下方注释中，恢复时连同保存门禁一起还原。
    // @State private var audit: BionicValidation?
    @State private var busy = false
    @State private var loaded = false
    @State private var originalEditorState: BionicObject?
    @State private var confirmLeaving = false
    private var editorState: BionicObject {
        ["persona": .object(persona), "binding": .object(binding), "participant": .object(participant)]
    }
    private var hasUnsavedChanges: Bool { loaded && originalEditorState != editorState }
    private func requestReturn() {
        guard !busy else { return }
        guard loaded else { dismiss(); return }
        focusedField = nil
        if hasUnsavedChanges { confirmLeaving = true } else { dismiss() }
    }
    @State private var deleting = false
    @State private var errorText: String?
    @State private var rolePhoto: PhotosPickerItem?
    @State private var userPhoto: PhotosPickerItem?
    @State private var roleAvatar: Data?
    @State private var userAvatar: Data?
    @State private var crop: CropRequest?
    @State private var promptPreview: PromptPreview?
    @FocusState private var focusedField: BionicEditField?

    private enum BionicEditField: Hashable { case nickname, genderCustom, identity, background, myName }
    private struct CropRequest: Identifiable { let id = UUID(); let image: UIImage; let role: Bool }
    private struct PromptPreview: Identifiable { let id = UUID(); let text: String }

    init(store: BionicStore, instance: String?) {
        self.store = store; self.instance = instance
        let old = store.roles.first { $0.installationID == instance }?.persona
        _persona = State(initialValue: old ?? BionicPersonaCatalog.draft(language: PalmiLanguage.current.rawValue))
        _original = State(initialValue: old)
        _binding = State(initialValue: store.model.defaultBinding())
        _participant = State(initialValue: ["participant_id": .string(BionicCodec.id()), "display_name": .string(""), "avatar_asset": .null, "created_at": .string(BionicCodec.instant())])
    }
    // private var fingerprint: String { (try? BionicPersonaCatalog.fingerprint(persona)) ?? "" }
    // private var accepted: Bool { audit?.receipt.flag("passed") == true && audit?.receipt.text("input_hash") == fingerprint }
    private func text(_ key: String) -> Binding<String> {
        Binding(get: { persona.text(key) }, set: { persona[key] = .string($0) })
    }
    private func nullable(_ key: String) -> Binding<String> {
        Binding(get: { persona.text(key) }, set: { persona[key] = $0.isEmpty ? .null : .string($0) })
    }
    private func toggle(_ key: String) -> Binding<Bool> {
        Binding(get: { persona.flag(key) }, set: { persona[key] = .bool($0) })
    }
    private var birthday: Binding<Date> {
        Binding(get: { (try? BionicPersonaCatalog.birth(persona.text("birth_date"))) ?? Date.now }, set: { persona["birth_date"] = .string(BionicPersonaCatalog.civil($0)) })
    }
    private var birthRange: ClosedRange<Date> {
        let ordinary = BionicPersonaCatalog.birthdayRange()
        let old = original.flatMap { try? BionicPersonaCatalog.birth($0.text("birth_date")) } ?? ordinary.lowerBound
        return min(old, ordinary.lowerBound)...ordinary.upperBound.addingTimeInterval(86399)
    }
    private func time(_ key: String) -> Binding<Date> {
        Binding(get: { BionicPersonaCatalog.time(on: .now, minute: persona.int(key)) }, set: {
            let c = BionicPersonaCatalog.calendar().dateComponents([.hour, .minute], from: $0)
            persona[key] = .count((c.hour ?? 0) * 60 + (c.minute ?? 0))
        })
    }
    var body: some View {
        Form {
            Section(PalmiL10n.tr("bionic.profile")) {
                HStack {
                    BionicAvatar(data: roleAvatar, name: persona.text("nickname"), size: 64)
                    PhotosPicker(selection: $rolePhoto, matching: .images) { Text(PalmiL10n.tr("bionic.chooseAvatar")) }
                }
                TextField(PalmiL10n.tr("bionic.nickname"), text: text("nickname"))
                    .focused($focusedField, equals: .nickname).bionicInputField()
                DatePicker(PalmiL10n.tr("bionic.birthDate"), selection: birthday, in: birthRange, displayedComponents: .date)
                    .environment(\.calendar, Calendar(identifier: .gregorian))
                if let age = try? BionicPersonaCatalog.age(persona.text("birth_date")) {
                    Text(PalmiL10n.tr("bionic.age", age)).font(.footnote).foregroundStyle(.secondary)
                }
                Picker(PalmiL10n.tr("bionic.gender"), selection: Binding(get: { persona.text("gender_kind") }, set: { persona["gender_kind"] = .string($0); persona["gender_text"] = $0 == "custom" ? .string("") : .null })) {
                    Text(PalmiL10n.tr("bionic.genderNone")).tag("none")
                    Text(PalmiL10n.tr("bionic.male")).tag("male")
                    Text(PalmiL10n.tr("bionic.female")).tag("female")
                    Text(PalmiL10n.tr("bionic.custom")).tag("custom")
                }
                if persona.text("gender_kind") == "custom" {
                    TextField(PalmiL10n.tr("bionic.genderCustom"), text: text("gender_text"))
                        .focused($focusedField, equals: .genderCustom).bionicInputField()
                }
                TextField(PalmiL10n.tr("bionic.identity"), text: text("identity"), axis: .vertical).lineLimit(1...4)
                    .focused($focusedField, equals: .identity).bionicInputField()
                TextField(PalmiL10n.tr("bionic.background"), text: text("background"), axis: .vertical).lineLimit(4...12)
                    .focused($focusedField, equals: .background).bionicInputField()
            }
            Section {
                Picker(PalmiL10n.tr("bionic.nativeLanguage"), selection: text("native_language")) {
                    ForEach(BionicPersonaCatalog.languages, id: \.self) { language in
                        Text(BionicPersonaCatalog.languageNames[language] ?? language).tag(language)
                    }
                }.disabled(instance != nil)
                if instance == nil {
                    Text(PalmiL10n.tr("bionic.nativeLanguageLocked")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(PalmiL10n.tr("bionic.personality")) {
                ForEach(BionicPersonaCatalog.dimensions, id: \.self) { dimension in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(PalmiL10n.tr("bionic.trait." + dimension)); Spacer()
                            Text(PalmiL10n.tr("bionic.trait.\(dimension).\(persona.object("baseline_traits").int(dimension))")).foregroundStyle(.secondary).font(.subheadline)
                        }
                        Slider(value: Binding(get: { Double(persona.object("baseline_traits").int(dimension)) }, set: {
                            var traits = persona.object("baseline_traits"); traits[dimension] = .count(Int($0.rounded()))
                            persona["baseline_traits"] = .object(traits)
                            if original == nil || original?["baseline_traits"] != persona["baseline_traits"] { persona["current_traits"] = .object(traits) }
                        }), in: 1...5, step: 1)
                        .accessibilityLabel(PalmiL10n.tr("bionic.trait." + dimension))
                    }.padding(.vertical, 5)
                }
                Picker("MBTI", selection: nullable("mbti")) {
                    Text(PalmiL10n.tr("bionic.unset")).tag("")
                    ForEach(BionicPersonaCatalog.types, id: \.self) { Text($0).tag($0) }
                }
            }
            Section(PalmiL10n.tr("bionic.sleep")) {
                DatePicker(PalmiL10n.tr("bionic.sleepStart"), selection: time("sleep_start_minute"), displayedComponents: .hourAndMinute)
                DatePicker(PalmiL10n.tr("bionic.sleepEnd"), selection: time("sleep_end_minute"), displayedComponents: .hourAndMinute)
                Toggle(PalmiL10n.tr("bionic.evolution"), isOn: toggle("evolution_enabled"))
                Toggle(PalmiL10n.tr("bionic.proactive"), isOn: toggle("proactive_enabled"))
            }
            if instance == nil {
                Section(PalmiL10n.tr("bionic.myProfile")) {
                    HStack { BionicAvatar(data: userAvatar, name: participant.text("display_name"), size: 44); PhotosPicker(selection: $userPhoto, matching: .images) { Text(PalmiL10n.tr("bionic.chooseAvatar")) } }
                    TextField(PalmiL10n.tr("bionic.myName"), text: Binding(get: { participant.text("display_name") }, set: { participant["display_name"] = .string($0) }))
                        .focused($focusedField, equals: .myName).bionicInputField()
                }
            }
            BionicModelBindingFields(store: store, binding: $binding)
            BionicRuntimeSettingsFields(persona: $persona, local: $binding)
            Section {
                if instance == nil {
                    Text(PalmiL10n.tr("bionic.disclosure")).font(.footnote).foregroundStyle(.secondary)
                }
                if busy { HStack { ProgressView(); Text(PalmiL10n.tr("bionic.processing")) } }
                Button(PalmiL10n.tr("bionic.preGenerate")) { pregenerate() }
            }
            if let instance, !BionicSystemPersona.isProtected(instance) {
                Section {
                    Button(PalmiL10n.tr("bionic.deleteRole"), role: .destructive) { deleting = true }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .bionicKeyboardDismissOnOutsideTap()
        .disabled(!loaded || busy)
        .navigationTitle(PalmiL10n.tr(instance == nil ? "bionic.create" : "bionic.settings"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(hasUnsavedChanges || busy)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { requestReturn() } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(PalmiL10n.tr("common.back")).disabled(busy)
                    .alert(PalmiL10n.tr("bionic.unsavedChanges"), isPresented: $confirmLeaving) {
                        Button(PalmiL10n.tr("bionic.saveAndReturn")) { Task { await save() } }
                        Button(PalmiL10n.tr("bionic.discardAndReturn"), role: .destructive) { dismiss() }
                        Button(PalmiL10n.tr("bionic.cancel"), role: .cancel) { confirmLeaving = false }
                    }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(PalmiL10n.tr(instance == nil ? "bionic.generate" : "bionic.save")) { Task { await save() } }
                    .disabled(!loaded || busy)
            }
        }
        // .onChange(of: fingerprint) { _, _ in audit = nil }
        .onChange(of: rolePhoto) { _, value in Task { await beginCrop(value, role: true) } }
        .onChange(of: userPhoto) { _, value in Task { await beginCrop(value, role: false) } }
        .sheet(item: $crop) { request in
            NavigationStack { BionicAvatarCropView(image: request.image) { data in applyAvatar(data, role: request.role) } }
        }
        .sheet(item: $promptPreview) { preview in
            NavigationStack {
                ScrollView {
                    Text(verbatim: preview.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .navigationTitle(PalmiL10n.tr("bionic.preGenerateTitle"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(PalmiL10n.tr("bionic.close")) { promptPreview = nil } } }
            }
        }
        .task {
            guard !loaded else { return }
            do {
                if let instance {
                    binding = try await store.archive.binding(instance)
                    let role = try await store.archive.loadRole(instance)
                    persona = role.persona; original = role.persona
                    participant = try await store.archive.read(instance, "participants/\(role.state.participantID).json")
                    roleAvatar = try await store.archive.asset(instance, role.persona.optionalText("avatar_asset"))
                }
                originalEditorState = editorState; loaded = true
            } catch { errorText = BionicStore.errorText(error) }
        }
        .confirmationDialog(PalmiL10n.tr("bionic.deleteRole"), isPresented: $deleting, titleVisibility: .visible) {
            Button(PalmiL10n.tr("bionic.delete"), role: .destructive) {
                guard let instance else { return }
                busy = true
                Task {
                    defer { busy = false }
                    do { try await store.delete(instance); dismiss() }
                    catch { errorText = BionicStore.errorText(error) }
                }
            }
        } message: { Text(PalmiL10n.tr("bionic.deleteRoleNotice")) }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} } message: { Text(errorText ?? "") }
    }
    // 核验暂时停用（调试期）。恢复时：取消本函数与上方 audit/accepted 的注释，
    // 保存按钮重新加 .disabled(!accepted)，save() 重新传入真实 audit。
    // private func verify() async {
    //     busy = true; defer { busy = false }
    //     do {
    //         try BionicPersonaCatalog.validate(persona, existing: original)
    //         let captured = fingerprint
    //         let result = try await store.model.validatePersona(persona, participant: participant, binding: binding, language: PalmiLanguage.current.rawValue, existing: original)
    //         if fingerprint == captured { audit = result }
    //     } catch { errorText = BionicStore.errorText(error) }
    // }
    private func pregenerate() {
        do {
            let state = BionicRuntimeState(raw: ["current_persona_revision_id": persona["persona_revision_id"] ?? .null,
                                                 "current_participant_id": participant["participant_id"] ?? .null,
                                                 "generation_id": .string(BionicCodec.id())])
            let role = BionicRole(installationID: "", manifest: ["character_id": persona["character_id"] ?? .null], persona: persona, state: state, throughSequence: 0)
            promptPreview = PromptPreview(text: try BionicPromptBuilder.personaPrefix(role))
        } catch { errorText = BionicStore.errorText(error) }
    }
    private func save() async {
        busy = true; defer { busy = false }
        do {
            if let instance { try await store.update(instance, persona: persona, assets: assets, binding: binding, audit: nil) }
            else {
                var p = participant
                let trimmed = participant.text("display_name").trimmingCharacters(in: .whitespacesAndNewlines)
                p["display_name"] = .string(trimmed.isEmpty ? PalmiL10n.tr("bionic.me") : trimmed)
                guard (1...40).contains(p.text("display_name").count) else { throw BionicFailure("invalidFields") }
                try await store.create(persona: persona, participant: p, assets: assets, binding: binding, audit: nil)
            }
            dismiss()
        } catch { errorText = BionicStore.errorText(error) }
    }
    private func beginCrop(_ value: PhotosPickerItem?, role: Bool) async {
        guard let value else { return }
        do {
            guard let raw = try await value.loadTransferable(type: Data.self),
                  let image = UIImage(data: raw), image.size.width > 0, image.size.height > 0 else { throw BionicFailure("invalidImage") }
            crop = CropRequest(image: image, role: role)
        } catch { errorText = BionicStore.errorText(error) }
    }
    private func applyAvatar(_ data: Data, role: Bool) {
        let path = "assets/\(BionicCodec.sha(data)).png"
        assets[path] = data
        if role { roleAvatar = data; persona["avatar_asset"] = .string(path) }
        else { userAvatar = data; participant["avatar_asset"] = .string(path) }
    }
}

extension View {
    // 文字输入处的统一视觉：灰色圆角矩形底，标明"这里可以填写"。
    func bionicInputField() -> some View {
        padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 10))
    }

    // 点表单空白处收起键盘。使用共享实现，不再单独维护窗口级探针。
    func bionicKeyboardDismissOnOutsideTap() -> some View {
        palmiKeyboardDismissOnOutsideTap()
    }
}
