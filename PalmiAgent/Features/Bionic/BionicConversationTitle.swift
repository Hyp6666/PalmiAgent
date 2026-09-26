import SwiftUI

struct BionicConversationTitle: View {
    let name: String
    let windows: [BionicTypingWindow]
    let active: Bool
    @State private var typing = false

    private struct TaskKey: Equatable {
        let windows: [BionicTypingWindow]
        let active: Bool
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(name).font(.headline).lineLimit(1)
            if active && typing {
                Text(PalmiL10n.tr("bionic.typing"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: TaskKey(windows: windows, active: active)) {
            typing = false
            guard active else { return }
            do {
                while !Task.isCancelled {
                    let now = Date.now
                    let nextState = windows.contains { $0.startsAt <= now && now < $0.endsAt }
                    if typing != nextState { typing = nextState }
                    guard let next = windows.flatMap({ [$0.startsAt, $0.endsAt] })
                        .filter({ $0 > now }).min() else { return }
                    try await Task.sleep(for: .seconds(max(0.01, next.timeIntervalSinceNow)))
                }
            } catch { }
        }
    }
}
