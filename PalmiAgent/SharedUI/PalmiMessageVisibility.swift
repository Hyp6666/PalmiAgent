import SwiftUI

/// Unread badges represent unopened conversations, not measured reading progress.
/// All three modes acknowledge the current conversation with this one rule.
struct PalmiConversationReadState: Hashable {
    let scope: String
    let enabled: Bool
    let unreadIDs: Set<String>

    var receipt: Set<String> {
        enabled && !scope.isEmpty ? unreadIDs : []
    }
}

private struct PalmiConversationReadModifier: ViewModifier {
    let state: PalmiConversationReadState
    let onRead: (Set<String>) -> Void

    func body(content: Content) -> some View {
        content.task(id: state) { @MainActor in
            guard !Task.isCancelled, !state.receipt.isEmpty else { return }
            onRead(state.receipt)
        }
    }
}

extension View {
    func palmiReadConversation(scope: String, enabled: Bool, unreadIDs: Set<String>,
                               onRead: @escaping (Set<String>) -> Void) -> some View {
        modifier(PalmiConversationReadModifier(
            state: .init(scope: scope, enabled: enabled, unreadIDs: unreadIDs), onRead: onRead
        ))
    }
}
