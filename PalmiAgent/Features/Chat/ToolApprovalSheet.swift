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
            .navigationTitle("确认执行")
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
            Text(request.toolTitle)
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
            metadataRow("风险", request.riskLevel.title)
            metadataRow("动作", request.sideEffect.title)
            metadataRow("策略", request.confirmationPolicy.title)
            if !request.systemPermissions.isEmpty {
                metadataRow("系统权限", request.systemPermissions.map(\.title).joined(separator: "、"))
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
            Text("参数")
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
                Text("该会话始终同意该工具")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            HStack(spacing: 12) {
                Button(role: .cancel, action: onReject) {
                    Text("拒绝")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onApprove) {
                    Text("同意")
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

private extension ToolConfirmationPolicy {
    var title: String {
        switch self {
        case .allow:
            "允许"
        case .firstUse:
            "首次确认"
        case .always:
            "每次确认"
        }
    }
}
