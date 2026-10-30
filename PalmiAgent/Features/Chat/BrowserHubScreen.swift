import SwiftUI
import WebKit

/// The same WKWebView is shared by the user and agent; previews never replace its live state.
struct BrowserHubScreen: View {
    @Bindable var service: BrowserOperatorService
    @State private var address = ""
    @FocusState private var isEditingAddress: Bool

    private var liveRecord: BrowserTabRecord? { service.liveTabID.flatMap(service.record) }
    private var isHandoff: Bool { service.handoffTabID != nil && service.handoffTabID == service.liveTabID }
    private var isLiveBusy: Bool { service.liveTabID.map(service.busyTabIDs.contains) ?? false }
    private var isLiveControlled: Bool { service.liveTabID.map(service.isControlled) ?? false }
    private var navigation: BrowserNavigationState {
        service.liveTabID.flatMap { service.navigationStates[$0] } ?? .init()
    }

    var body: some View {
        VStack(spacing: 0) {
            PalmiBrowserChrome(
                title: liveRecord?.displayTitle ?? PalmiL10n.tr("browser.tabs"),
                leadingSystemImage: "chevron.down",
                leadingAccessibilityLabel: PalmiL10n.tr("browser.live.collapse"),
                safeAreaTop: 0,
                onLeading: {
                    isEditingAddress = false
                    service.dismissBrowser()
                }
            ) {
                if isHandoff {
                    Button(action: service.dismissBrowser) {
                        Text(PalmiL10n.tr("browser.handoff.done"))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 18)
                            .frame(height: 46)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                } else if liveRecord != nil {
                    PalmiBrowserChromeButton(systemImage: "square.on.square", accessibilityLabel: PalmiL10n.tr("browser.tabs")) {
                        isEditingAddress = false
                        service.showOverview()
                    }
                } else {
                    searchEngineMenu
                }
            }
            .background(PalmiBrowserChromeBackdrop())

            if liveRecord != nil, let session = service.liveSession() {
                // Explicitly flexible viewport: WKWebView's intrinsic sizing must not push the
                // entire stack upward when SwiftUI subtracts the keyboard's safe area.
                GeometryReader { viewport in
                    BrowserHubWebViewHost(webView: session.webView, isInteractive: isHandoff || !isLiveBusy)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .overlay {
                            if isLiveControlled && !isHandoff, let id = service.liveTabID {
                                BrowserPointerOverlay(pointer: service.pointers[id] ?? BrowserPointer())
                            }
                        }
                        .palmiAIGlow(Rectangle(), isActive: isLiveControlled && !isHandoff, lineWidth: 6)
                }
                .clipped()
            } else {
                BrowserTabOverview(service: service)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if liveRecord != nil && !isHandoff { bottomBar }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onChange(of: service.liveTabID, initial: true) { _, _ in
            isEditingAddress = false
            address = liveRecord?.url ?? ""
        }
        .onChange(of: liveRecord?.url) { _, url in
            if !isEditingAddress { address = url ?? "" }
        }
    }

    private var searchEngineMenu: some View {
        Menu {
            Picker(PalmiL10n.tr("browser.searchEngine"), selection: $service.searchEngine) {
                ForEach(BrowserSearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel(PalmiL10n.tr("browser.searchEngine"))
        .accessibilityValue(service.searchEngine.title)
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                PalmiBrowserChromeButton(systemImage: "chevron.left", accessibilityLabel: PalmiL10n.tr("browser.back")) {
                    isEditingAddress = false
                    service.userGoBack()
                }
                .disabled(isLiveBusy || !navigation.canGoBack)
                .opacity(navigation.canGoBack && !isLiveBusy ? 1 : 0.35)
                PalmiBrowserChromeButton(systemImage: "chevron.right", accessibilityLabel: PalmiL10n.tr("browser.forward")) {
                    isEditingAddress = false
                    service.userGoForward()
                }
                .disabled(isLiveBusy || !navigation.canGoForward)
                .opacity(navigation.canGoForward && !isLiveBusy ? 1 : 0.35)
                TextField(PalmiL10n.tr("browser.address.placeholder"), text: $address)
                    .font(.system(size: 15, design: .rounded))
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($isEditingAddress)
                    .disabled(isLiveBusy)
                    .onSubmit {
                        isEditingAddress = false
                        service.userNavigate(address)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .glassEffect(.regular.interactive(), in: .capsule)
                PalmiBrowserChromeButton(systemImage: "plus", accessibilityLabel: PalmiL10n.tr("browser.newTab")) {
                    isEditingAddress = false
                    service.userNewTab()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }
}

private struct BrowserTabOverview: View {
    let service: BrowserOperatorService
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(service.tabs) { tab in
                    BrowserTabCard(tab: tab, service: service)
                }
                Button(action: service.userNewTab) {
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PalmiL10n.tr("browser.newTab"))
            }
            .padding(16)
        }
    }
}

private struct BrowserTabCard: View {
    let tab: BrowserTabRecord
    let service: BrowserOperatorService
    @State private var preview: UIImage?
    @State private var isVisible = false

    private var title: String {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? PalmiL10n.tr(tab.url.isEmpty ? "browser.newTab" : "browser.untitled") : title
    }

    var body: some View {
        Button { service.showTab(tab.id) } label: {
            Color(.secondarySystemBackground)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: tab.url.isEmpty ? "plus.square.on.square" : "globe")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
                .overlay(alignment: .bottom) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .background(.ultraThinMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .palmiAIGlow(RoundedRectangle(cornerRadius: 22), isActive: service.isControlled(tab.id), lineWidth: 4)
                .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .overlay(alignment: .topTrailing) {
            Button { service.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(3)
            .accessibilityLabel(PalmiL10n.tr("browser.closeTab"))
            .disabled(service.isControlled(tab.id) || service.handoffTabID == tab.id)
        }
        .onAppear { isVisible = true; loadPreview() }
        .onDisappear { isVisible = false; preview = nil }
        .onChange(of: service.previewRevisions[tab.id]) { _, _ in
            if isVisible { loadPreview() }
        }
    }

    private func loadPreview() {
        service.loadPreview(tab.id) { image in
            if isVisible { preview = image }
        }
    }
}

private struct BrowserHubWebViewHost: UIViewRepresentable {
    let webView: WKWebView
    let isInteractive: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(webView)
        }
        webView.isUserInteractionEnabled = isInteractive
    }
}

/// 小手指浮层：叠在网页上方、不注入网页；不拦截触摸。
/// 点击/输入泛起涟漪，滚动做一次拖动，按键轻轻脉动，导航回到中央。
private struct BrowserPointerOverlay: View {
    let pointer: BrowserPointer
    @State private var rippleProgress: CGFloat = 1
    @State private var dragOffset: CGFloat = 0
    @State private var pressScale: CGFloat = 1

    private enum Style {
        static let size: CGFloat = 30
        /// 原图向右指，逆时针转 90° 后指向上方。
        static let rotation = Angle.degrees(-90)
        // SVG 的 100×100 坐标中指尖为 (93.85, 42.9)；绕中心逆时针转 90° 后为 (42.9, 6.15)。
        static let tip = UnitPoint(x: 0.429, y: 0.0615)
        static let fill = Color.white
        static let fillOpacity = 0.95
        static let outline = Color(white: 0.3)
        static let outlineOpacity = 0.95
        static let shadow = Color.black
        static let shadowOpacity = 0.18
        static let ripple = Color(white: 0.4)
        static let rippleOpacity = 0.7
        static let ripplePeakOpacity = 0.9
    }

    var body: some View {
        GeometryReader { proxy in
            let point = CGPoint(x: pointer.x * proxy.size.width, y: pointer.y * proxy.size.height)
            ZStack {
                Circle()
                    .stroke(Style.ripple.opacity(Style.rippleOpacity), lineWidth: 2)
                    .frame(width: 46, height: 46)
                    .scaleEffect(0.35 + rippleProgress * 1.1)
                    .opacity(Double(1 - rippleProgress) * Style.ripplePeakOpacity)
                    .position(point)
                ZStack {
                    Image("PalmiPointerFill")
                        .renderingMode(.template)
                        .resizable()
                        .foregroundStyle(Style.fill.opacity(Style.fillOpacity))
                    Image("PalmiPointerOutline")
                        .renderingMode(.template)
                        .resizable()
                        .foregroundStyle(Style.outline.opacity(Style.outlineOpacity))
                }
                .frame(width: Style.size, height: Style.size)
                .rotationEffect(Style.rotation)
                .shadow(color: Style.shadow.opacity(Style.shadowOpacity), radius: 5, y: 2)
                .scaleEffect(pressScale, anchor: Style.tip)
                // 图像中心与指尖之间的偏移精确抵消，涟漪仍以真实落点为中心。
                .position(
                    x: point.x + Style.size * (0.5 - Style.tip.x),
                    y: point.y + Style.size * (0.5 - Style.tip.y) + dragOffset
                )
            }
            .animation(.spring(duration: 0.3, bounce: 0.15), value: pointer.x)
            .animation(.spring(duration: 0.3, bounce: 0.15), value: pointer.y)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .onChange(of: pointer.sequence) { _, _ in play(pointer.gesture) }
    }

    private func play(_ gesture: BrowserPointer.Gesture) {
        switch gesture {
        case .tap, .type:
            rippleProgress = 0
            withAnimation(.easeOut(duration: 0.55).delay(0.22)) { rippleProgress = 1 }
        case .press:
            withAnimation(.easeInOut(duration: 0.12)) { pressScale = 0.86 }
            withAnimation(.spring(duration: 0.3).delay(0.12)) { pressScale = 1 }
        case .scrollUp, .scrollDown:
            let distance: CGFloat = gesture == .scrollUp ? 60 : -60
            dragOffset = -distance / 2
            withAnimation(.easeInOut(duration: 0.45)) { dragOffset = distance / 2 }
            withAnimation(.easeOut(duration: 0.2).delay(0.5)) { dragOffset = 0 }
        case .idle:
            break
        }
    }
}
