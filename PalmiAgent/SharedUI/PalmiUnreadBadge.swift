import SwiftUI

struct PalmiUnreadSnapshot: Equatable {
    var professional = 0
    var chat = 0
    var bionic = 0
    var readingAllowed = true
    var total: Int { professional + chat + bionic }
    func count(for mode: AppShellMode) -> Int {
        switch mode {
        case .professional: professional
        case .chat: chat
        case .bionic: bionic
        }
    }
    func countOutside(_ mode: AppShellMode) -> Int {
        max(0, total - count(for: mode))
    }
}
private struct PalmiUnreadEnvironmentKey: EnvironmentKey {
    static let defaultValue = PalmiUnreadSnapshot()
}
extension EnvironmentValues {
    var palmiUnread: PalmiUnreadSnapshot {
        get { self[PalmiUnreadEnvironmentKey.self] }
        set { self[PalmiUnreadEnvironmentKey.self] = newValue }
    }
}
struct PalmiUnreadBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : String(count))
                .font(.caption2.weight(.bold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, count > 9 ? 5 : 4)
                .frame(minWidth: 18, minHeight: 18)
                .background(.tint, in: Capsule())
                .accessibilityLabel(PalmiL10n.tr("chat.unread.count", count))
                .allowsHitTesting(false)
        }
    }
}
