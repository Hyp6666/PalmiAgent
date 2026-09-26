import SwiftUI

private struct PalmiMessageVisibilityKey: Equatable {
    let visible: Bool
    let enabled: Bool
    let revision: Int
}

private struct PalmiMessageVisibilityModifier: ViewModifier {
    let viewport: CGRect
    let enabled: Bool
    let revision: Int
    let onVisibility: (Bool) -> Void
    @State private var geometricallyVisible = false

    private var key: PalmiMessageVisibilityKey {
        .init(visible: geometricallyVisible, enabled: enabled, revision: revision)
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { proxy in
                let frame = proxy.frame(in: .global)
                guard frame.width > 0, frame.height > 0,
                      viewport.width > 0, viewport.height > 0 else { return false }
                let intersection = frame.intersection(viewport)
                guard !intersection.isNull, !intersection.isEmpty else { return false }
                let requiredHeight = min(24, min(frame.height * 0.5, viewport.height * 0.5))
                let requiredWidth = min(16, frame.width * 0.5)
                return intersection.height >= requiredHeight
                    && intersection.width >= requiredWidth
            } action: { visible in
                if geometricallyVisible != visible { geometricallyVisible = visible }
            }
            .task(id: key) {
                let captured = key
                guard captured.enabled, captured.visible else {
                    onVisibility(false)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
                guard !Task.isCancelled, key == captured else { return }
                onVisibility(true)
            }
            .onDisappear { onVisibility(false) }
    }
}

extension View {
    func palmiMessageVisibility(
        in viewport: CGRect,
        enabled: Bool,
        revision: Int = 0,
        onVisibility: @escaping (Bool) -> Void
    ) -> some View {
        modifier(PalmiMessageVisibilityModifier(
            viewport: viewport, enabled: enabled, revision: revision,
            onVisibility: onVisibility
        ))
    }
}
