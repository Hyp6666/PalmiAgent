import SwiftUI

struct ToolApprovalSheet: View {
    let request: AgentApprovalRequest
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onReject: () -> Void

    private var isPersonaCreation: Bool { request.toolActionID == .createBionicPersona }
    @State private var persona: BionicObject?
    @State private var participant: BionicObject?
    @State private var avatarFilename: String?
    @State private var creationError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isPersonaCreation {
                        if let persona, let participant {
                            personaConfirmation(persona, participant: participant)
                        } else if let creationError {
                            Text(creationError).foregroundStyle(.red)
                        } else {
                            ProgressView()
                        }
                    } else {
                        header
                        metadataGrid
                        argumentsBlock
                    }
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(PalmiL10n.tr(isPersonaCreation
                ? "bionic.creation.confirmTitle" : "tool.approval.title"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(true)
        .task(id: request.id) {
            guard isPersonaCreation else { return }
            persona = nil
            participant = nil
            avatarFilename = nil
            creationError = nil
            do {
                let arguments = try ToolArguments(jsonString: request.argumentsJSON)
                let draft = try BionicPersonaCreation.make(
                    arguments, characterID: request.id.uuidString.lowercased()
                )
                let avatar = try BionicAvatarImportSpec.parse(arguments)
                persona = draft.persona
                participant = draft.participant
                avatarFilename = avatar.map { ($0.path as NSString).lastPathComponent }
            } catch {
                creationError = BionicStore.errorText(error)
            }
        }
    }

    private func personaConfirmation(
        _ persona: BionicObject, participant: BionicObject
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(persona.text("nickname")).font(.title2.weight(.semibold))
            Text(persona.text("identity")).font(.body)
            if !persona.text("background").isEmpty {
                Text(persona.text("background")).font(.body)
            }
            Divider()
            LabeledContent(PalmiL10n.tr("bionic.birthDate"), value: persona.text("birth_date"))
            LabeledContent(
                PalmiL10n.tr("bionic.nativeLanguage"),
                value: BionicPersonaCatalog.languageNames[persona.text("native_language")]
                    ?? persona.text("native_language")
            )
            LabeledContent(
                PalmiL10n.tr("bionic.myName"), value: participant.text("display_name")
            )
            LabeledContent(
                PalmiL10n.tr("bionic.gender"), value: creationGender(persona)
            )
            LabeledContent("MBTI", value: persona.optionalText("mbti") ?? PalmiL10n.tr("bionic.unset"))
            ForEach(BionicPersonaCatalog.dimensions, id: \.self) { dimension in
                LabeledContent(
                    PalmiL10n.tr("bionic.trait." + dimension),
                    value: PalmiL10n.tr("bionic.trait.\(dimension).\(persona.object("baseline_traits").int(dimension))")
                )
            }
            LabeledContent(PalmiL10n.tr("bionic.sleepStart"), value: creationTime(persona.int("sleep_start_minute")))
            LabeledContent(PalmiL10n.tr("bionic.sleepEnd"), value: creationTime(persona.int("sleep_end_minute")))
            LabeledContent(
                PalmiL10n.tr("bionic.replyTiming"),
                value: PalmiL10n.tr(BionicReplyTiming.resolve(persona) == .instant
                    ? "bionic.replyTiming.instant" : "bionic.replyTiming.natural")
            )
            LabeledContent(PalmiL10n.tr("bionic.proactive"), value: creationSwitch(persona.flag("proactive_enabled")))
            LabeledContent(PalmiL10n.tr("bionic.evolution"), value: creationSwitch(persona.flag("evolution_enabled")))
            LabeledContent(
                PalmiL10n.tr("bionic.creation.avatar"),
                value: avatarFilename ?? PalmiL10n.tr("common.none")
            )
        }
    }

    private func creationTime(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
    private func creationSwitch(_ enabled: Bool) -> String {
        PalmiL10n.tr(enabled ? "common.on" : "common.off")
    }
    private func creationGender(_ persona: BionicObject) -> String {
        switch persona.text("gender_kind") {
        case "male": PalmiL10n.tr("bionic.male")
        case "female": PalmiL10n.tr("bionic.female")
        case "custom": persona.text("gender_text")
        default: PalmiL10n.tr("bionic.genderNone")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                AgentExternalToolFacadeCatalog.localizedTitle(for: request.toolName)
                    ?? request.toolActionID.localizedTitleForUI
            )
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text(request.toolName)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadataGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            metadataRow(PalmiL10n.tr("tool.approval.risk"), request.riskLevel.localizedTitle)
            metadataRow(PalmiL10n.tr("tool.approval.action"), request.sideEffect.localizedTitle)
            metadataRow(PalmiL10n.tr("tool.approval.policy"), request.confirmationPolicy.localizedTitle)
            if !request.systemPermissions.isEmpty {
                metadataRow(
                    PalmiL10n.tr("tool.approval.systemPermission"),
                    request.systemPermissions.map(\.localizedTitleForUI).joined(separator: PalmiL10n.tr("common.listSeparator"))
                )
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
        }
    }

    private var argumentsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PalmiL10n.tr("tool.approval.arguments"))
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(request.argumentsJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if !isPersonaCreation {
                Button(action: onApproveForSession) {
                    Text(PalmiL10n.tr("tool.approval.approveForSession"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(spacing: 12) {
                Button(role: .cancel, action: onReject) {
                    Text(PalmiL10n.tr(isPersonaCreation
                        ? "bionic.creation.revise" : "tool.approval.reject"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onApprove) {
                    Text(PalmiL10n.tr(isPersonaCreation
                        ? "bionic.creation.confirm" : "tool.approval.approve"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isPersonaCreation && (persona == nil || participant == nil || creationError != nil))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.regularMaterial)
    }
}
