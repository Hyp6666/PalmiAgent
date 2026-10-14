import SwiftUI
import WebKit

/// App 级浏览器界面：与内置浏览器同一套全屏顶部栏，支持多标签页。
/// 显示的是 Palmi 正在操作的同一个 WKWebView；收起后网页回到幕后，Palmi 继续静默操控。
struct BrowserHubScreen: View {
    @Bindable var service: BrowserOperatorService
    @State private var address = ""
    @FocusState private var isEditingAddress: Bool

    private var liveRecord: BrowserTabRecord? { service.liveTabID.flatMap(service.record) }
    private var isHandoff: Bool { service.handoffTabID != nil && service.handoffTabID == service.liveTabID }
    private var isLiveBusy: Bool { service.liveTabID.map(service.busyTabIDs.contains) ?? false }
    private var isLiveControlled: Bool { service.liveTabID.map(service.isControlled) ?? false }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                PalmiBrowserChrome(
                    title: liveRecord?.displayTitle ?? PalmiL10n.tr("browser.tabs"),
                    leadingSystemImage: "chevron.down",
                    leadingAccessibilityLabel: PalmiL10n.tr("browser.live.collapse"),
                    safeAreaTop: proxy.safeAreaInsets.top,
                    onLeading: service.dismissBrowser
                ) {
                    if isHandoff {
                        Button(action: service.dismissBrowser) {
                            Text(PalmiL10n.tr("browser.handoff.done"))
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 18)
                                .frame(height: 46)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    } else if liveRecord != nil {
                        PalmiBrowserChromeButton(systemImage: "square.on.square", accessibilityLabel: PalmiL10n.tr("browser.tabs")) {
                            service.showOverview()
                        }
                    }
                }
                .background(PalmiBrowserChromeBackdrop())
                .zIndex(1)

                if liveRecord != nil, let session = service.liveSession() {
                    BrowserHubWebViewHost(webView: session.webView, isInteractive: isHandoff || !isLiveBusy)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if isLiveControlled && !isHandoff, let id = service.liveTabID {
                                BrowserPointerOverlay(pointer: service.pointers[id] ?? BrowserPointer())
                            }
                        }
                        .palmiAIGlow(Rectangle(), isActive: isLiveControlled && !isHandoff, lineWidth: 6)
                    if !isHandoff {
                        bottomBar(webView: session.webView, safeAreaBottom: proxy.safeAreaInsets.bottom)
                    }
                } else {
                    BrowserTabOverview(service: service)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(.systemBackground))
            .ignoresSafeArea(.container)
        }
        .onChange(of: service.liveTabID, initial: true) { _, _ in
            address = liveRecord?.url ?? ""
        }
        .onChange(of: liveRecord?.url) { _, url in
            if !isEditingAddress { address = url ?? "" }
        }
    }

    private func bottomBar(webView: WKWebView, safeAreaBottom: CGFloat) -> some View {
        HStack(spacing: 10) {
            PalmiBrowserChromeButton(systemImage: "chevron.left", accessibilityLabel: PalmiL10n.tr("browser.back")) {
                if !isLiveBusy { webView.goBack() }
            }
            PalmiBrowserChromeButton(systemImage: "chevron.right", accessibilityLabel: PalmiL10n.tr("browser.forward")) {
                if !isLiveBusy { webView.goForward() }
            }
            TextField(PalmiL10n.tr("browser.address.placeholder"), text: $address)
                .font(.system(size: 15, design: .rounded))
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($isEditingAddress)
                .disabled(isLiveBusy)
                .onSubmit { service.userNavigate(address) }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .glassEffect(.regular.interactive(), in: .capsule)
            PalmiBrowserChromeButton(systemImage: "plus", accessibilityLabel: PalmiL10n.tr("browser.newTab")) {
                service.userNewTab()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, max(safeAreaBottom, 10))
        .background(Color(.systemBackground))
    }
}

/// 标签页总览：卡片网格，点按切换，可关闭、可新建。
private struct BrowserTabOverview: View {
    let service: BrowserOperatorService
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(service.tabs) { tab in
                    card(tab)
                }
                Button(action: service.userNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                        .contentShape(RoundedRectangle(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PalmiL10n.tr("browser.newTab"))
            }
            .padding(16)
        }
    }

    private func card(_ tab: BrowserTabRecord) -> some View {
        Button { service.showTab(tab.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if service.isControlled(tab.id) { palmiBadge }
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
                Text(tab.displayTitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(URL(string: tab.url)?.host ?? "")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            // 柔光在卡片底色之上、文字之下。
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 22).fill(Color(.secondarySystemBackground))
                    PalmiAIGlowLayer(shape: RoundedRectangle(cornerRadius: 22), isActive: service.isControlled(tab.id), lineWidth: 4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button { service.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .disabled(service.isControlled(tab.id) || service.handoffTabID == tab.id)
        }
    }

    /// “Palmi 正在处理”标记：文字用柔光配色渐变。
    private var palmiBadge: some View {
        Text(PalmiL10n.tr("browser.badge.busy"))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(LinearGradient(colors: PalmiAIGlowPalette.colors, startPoint: .leading, endPoint: .trailing))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color(.systemBackground).opacity(0.85)))
    }
}

/// 把已有的 WKWebView 挂进 SwiftUI；Palmi 正在操作时只看不点，避免与 Palmi 抢页面。
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
