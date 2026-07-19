import SwiftUI

struct ToolApprovalSheet: View {
    let request: AgentApprovalRequest
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onReject: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    metadataGrid
                    argumentsBlock
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(PalmiL10n.tr("tool.approval.title"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(true)
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
            Button(action: onApproveForSession) {
                Text(PalmiL10n.tr("tool.approval.approveForSession"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            HStack(spacing: 12) {
                Button(role: .cancel, action: onReject) {
                    Text(PalmiL10n.tr("tool.approval.reject"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onApprove) {
                    Text(PalmiL10n.tr("tool.approval.approve"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.regularMaterial)
    }
}
