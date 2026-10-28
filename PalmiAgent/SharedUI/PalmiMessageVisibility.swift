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
        let receipt = state.receipt
        return content.task(id: state) { @MainActor [receipt, onRead] in
            // Coalesce arrivals outside the current render frame. A receipt changes
            // its own task identity; synchronous mutation can hit SwiftUI's frame limit.
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled, !receipt.isEmpty else { return }
            onRead(receipt)
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
