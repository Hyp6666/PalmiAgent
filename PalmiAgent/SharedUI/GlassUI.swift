import SwiftUI

struct StatusBadge: View {
    let availability: ToolAvailability

    var body: some View {
        Text(availability.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(badgeColor, in: Capsule())
    }

    private var badgeColor: Color {
        switch availability {
        case .live:
            return .green.opacity(0.28)
        case .partial:
            return .orange.opacity(0.28)
        case .deferred:
            return .gray.opacity(0.28)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct StatCapsule: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(value)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
