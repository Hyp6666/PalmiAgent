import SwiftUI

// Shared with ChatScreen. State lives in each mode's small composer view, not its message list.
struct PalmiComposerSurface<Attachments: View, Editor: View, Controls: View>: View {
    let hasAttachments: Bool
    let dismissKeyboard: () -> Void
    @ViewBuilder let attachments: () -> Attachments
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let controls: () -> Controls
    var body: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                if hasAttachments { attachments() }
                VStack(alignment: .leading, spacing: 10) {
                    editor()
                    controls()
                }
                .simultaneousGesture(DragGesture(minimumDistance: 24, coordinateSpace: .local).onEnded {
                    if $0.translation.height > 0 { dismissKeyboard() }
                })
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1).allowsHitTesting(false))
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8).zIndex(1)
    }
}

struct PalmiComposerTextEditor: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let placeholder: String
    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...6).textFieldStyle(.plain).focused($isFocused)
            .font(.body).frame(minHeight: 28, alignment: .top)
            .padding(.horizontal, 4).padding(.top, 2)
            .onReceive(NotificationCenter.default.publisher(for: PalmiInputFocus.dismiss)) { _ in isFocused = false }
    }
}

struct PalmiComposerSendControl: View {
    let isLoading: Bool
    let canSend: Bool
    let accessibilityTitle: String
    let animation: Animation
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: isLoading ? "stop.fill" : "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isLoading || canSend ? Color.white : Color.secondary.opacity(0.45))
                .frame(width: 40, height: 40)
                .background { Circle().fill(isLoading || canSend ? Color.accentColor : Color.primary.opacity(0.06)) }
        }
        .buttonStyle(.plain).disabled(!isLoading && !canSend)
        .accessibilityLabel(accessibilityTitle)
        .animation(animation, value: canSend).animation(animation, value: isLoading)
    }
}
