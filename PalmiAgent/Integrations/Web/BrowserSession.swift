import Foundation
import UIKit
import WebKit

// 使用单次完成的桥接，超时或取消后迟到的 WebKit 回调不会再次恢复 continuation。
@MainActor
private final class BrowserPendingResult<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class BrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let contentWorld = WKContentWorld.world(name: "PalmiBrowserOperator")
    let webView: WKWebView
    private let frameBridge = BrowserFrameBridge()
    var ledger = BrowserObservationLedger()
    var isBusy = false
    var isHandedOff = false
    weak var dialogPresenter: UIViewController?
    private(set) var disposed = false
    private var deadline = Date.distantFuture
    private var pendingAbort: ((Error) -> Void)?
    private var navigationCompletion: ((Result<Void, Error>) -> Void)?
    private var currentNavigation: WKNavigation?
    private var navigationError: Error?
    private var blockedMessages: [String] = []
    private var dismissDialog: (() -> Void)?
    /// 页面标题或地址变化时回调，用于更新标签页列表与持久化。
    var onPageChanged: ((URL?, String?) -> Void)?
    private var pageObservations: [NSKeyValueObservation] = []
    private var geolocationBridge: BrowserGeolocationBridge?

    init(dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        frameBridge.install(on: configuration.userContentController)
        if #unavailable(iOS 27.0) {
            let bridge = BrowserGeolocationBridge()
            bridge.install(on: webView)
            geolocationBridge = bridge
        }
        pageObservations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                let url = webView.url, title = webView.title
                Task { @MainActor in self?.onPageChanged?(url, title) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                let url = webView.url, title = webView.title
                Task { @MainActor in self?.onPageChanged?(url, title) }
            }
        ]
        frameBridge.onBlockedNavigation = { [weak self] message in
            guard let self, self.blockedMessages.count < 20 else { return }
            self.blockedMessages.append(message)
        }
    }

    func begin(timeout: TimeInterval = 30) throws {
        try checkForeground()
        guard !disposed else { throw BrowserToolError(code: "session_closed", message: "浏览器会话已关闭。") }
        guard !isBusy else { throw BrowserToolError(code: "browser_busy", message: "同一会话正在执行浏览器操作，请稍后根据新观察继续。") }
        guard !isHandedOff else { throw BrowserToolError(code: "handoff_pending", message: "用户正在接管浏览器，接管结束后会返回最新页面。") }
        isBusy = true
        deadline = Date().addingTimeInterval(timeout)
        navigationError = nil
    }

    func end() {
        isBusy = false
        pendingAbort = nil
        navigationCompletion = nil
        currentNavigation = nil
    }

    func checkForeground() throws {
        guard UIApplication.shared.applicationState == .active else { throw BrowserToolError.foreground }
        try Task.checkCancellation()
    }

    func abort(_ error: Error) {
        ledger.invalidate()
        navigationError = error
        pendingAbort?(error)
        dismissDialog?()
        navigationCompletion = nil
        currentNavigation = nil
        webView.stopLoading()
    }

    func dispose() {
        disposed = true
        pageObservations.removeAll()
        geolocationBridge?.uninstall()
        geolocationBridge = nil
        onPageChanged = nil
        abort(BrowserToolError(code: "session_closed", message: "浏览器会话已关闭。"))
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        frameBridge.dispose()
        webView.removeFromSuperview()
    }

    func awaitValue<Value>(timeout: TimeInterval, start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try checkForeground()
        guard !disposed else { throw BrowserToolError(code: "session_closed", message: "浏览器会话已关闭。") }
        let remaining = min(timeout, deadline.timeIntervalSinceNow)
        guard remaining > 0 else { throw BrowserToolError(code: "timeout", message: "浏览器操作已超时，请先 observe 确认当前页面。") }
        let pending = BrowserPendingResult<Value>()
        defer { pendingAbort = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                pendingAbort = { pending.finish(.failure($0)) }
                pending.timer = Task { @MainActor [weak pending] in
                    do {
                        try await Task.sleep(for: .seconds(remaining))
                        pending?.finish(.failure(BrowserToolError(code: "timeout", message: "浏览器操作已超时，请先 observe 确认当前页面。")))
                    } catch { }
                }
                if Task.isCancelled { pending.finish(.failure(CancellationError())); return }
                start { pending.finish($0) }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }

    func navigate(_ operation: BrowserOperation, url: URL? = nil) async throws {
        ledger.invalidate()
        try await awaitValue(timeout: 20) { completion in
            navigationCompletion = completion
            let navigation: WKNavigation?
            switch operation {
            case .open:
                guard let url else { completion(.failure(BrowserToolError(code: "invalid_arguments", message: "缺少网页地址。"))); return }
                navigation = webView.load(URLRequest(url: url, timeoutInterval: 20))
            case .back: navigation = webView.goBack()
            case .forward: navigation = webView.goForward()
            case .reload: navigation = webView.reload()
            default: navigation = nil
            }
            if navigation == nil { navigationCompletion = nil; completion(.success(())) }
            else { currentNavigation = navigation }
        }
        try await settle()
    }

    func script(_ arguments: [String: Any], frame: WKFrameInfo? = nil) async throws -> String {
        try await awaitValue(timeout: 6) { completion in
            webView.callAsyncJavaScript(BrowserDOMScript.body, arguments: ["request": arguments], in: frame,
                                        in: Self.contentWorld) { result in
                switch result {
                case .success(let value):
                    guard let text = value as? String else {
                        completion(.failure(BrowserToolError(code: "invalid_observation", message: "页面未返回可读取的观察。"))); return
                    }
                    completion(.success(text))
                case .failure(let error):
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    let parts = message.components(separatedBy: "|")
                    if parts.count >= 2 {
                        completion(.failure(BrowserToolError(code: parts[0].replacingOccurrences(of: "Error: ", with: ""), message: parts.dropFirst().joined(separator: "|"))))
                    } else { completion(.failure(error)) }
                }
            }
        }
    }

    func observe() async throws -> BrowserObservation {
        let id = ledger.issue()
        do {
            let json = try await script(["operation": "observe", "id": id])
            try checkForeground()
            guard ledger.latest == id else { throw BrowserToolError.stale }
            return try JSONDecoder().decode(BrowserObservation.self, from: Data(json.utf8))
        } catch { ledger.invalidate(); throw error }
    }

    func interact(_ request: BrowserRequest) async throws {
        if let id = request.observationID { try ledger.validate(id) }
        var payload: [String: Any] = ["operation": request.operation.rawValue]
        if let ref = request.ref { payload["ref"] = ref; payload["observation_id"] = request.observationID }
        if let x = request.x { payload["x"] = x; payload["y"] = request.y }
        if let text = request.text { payload["text"] = text; payload["clear"] = request.clear; payload["submit"] = request.submit }
        if let value = request.value { payload["value"] = value }
        if let key = request.key { payload["key"] = key }
        if let direction = request.direction { payload["direction"] = direction; payload["amount"] = request.amount }
        ledger.invalidate()
        var response = try await script(payload)
        // 跨域文档不能由主 frame 读 DOM；通过隔离脚本的 frame 句柄在目标文档里执行坐标动作。
        for depth in 0..<8 {
            guard response.hasPrefix("{"),
                  let route = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                  let token = route["routeFrame"] as? String else { break }
            guard depth < 7 else { throw BrowserToolError(code: "frame_depth", message: "iframe 嵌套超过操作上限。") }
            payload["x"] = route["x"]
            payload["y"] = route["y"]
            response = try await script(payload, frame: frameBridge.frame(for: token))
        }
        try await settle()
    }

    func settle() async throws {
        // 至少等待一个短窗口，再以 DOM 修订号和导航状态判断稳定；动态页面最多等 4 秒。
        let until = min(Date().addingTimeInterval(4), deadline)
        var previous: String?
        var stableSamples = 0
        repeat {
            try checkForeground()
            if let navigationError { throw navigationError }
            try await Task.sleep(for: .milliseconds(250))
            if webView.isLoading { stableSamples = 0; continue }
            let current = try await script(["operation": "settle"])
            stableSamples = current == previous ? stableSamples + 1 : 0
            previous = current
            if stableSamples >= 2 { return }
        } while Date() < until
        if webView.isLoading { throw BrowserToolError(code: "timeout", message: "页面加载尚未完成，请先 observe 确认页面状态。") }
        blockedMessages.append("页面仍有动态更新，观察反映当前状态。")
    }

    func snapshot() async throws -> UIImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.afterScreenUpdates = true
        return try await awaitValue(timeout: 8) { completion in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error { completion(.failure(error)) }
                else if let image { completion(.success(image)) }
                else { completion(.failure(BrowserToolError(code: "snapshot_failed", message: "无法获取当前视口截图。"))) }
            }
        }
    }

    var notices: String {
        let messages = Array(blockedMessages.prefix(5))
        blockedMessages.removeAll()
        return messages.isEmpty ? "" : "\nnotice: " + messages.joined(separator: "；")
    }

    func finishHandoff() {
        isHandedOff = false
        ledger.invalidate()
        dismissDialog?()
        dialogPresenter = nil
    }

    private func showDialog(message: String, defaultText: String? = nil, isPrompt: Bool = false,
                            cancellable: Bool = true, completion: @escaping (String?) -> Void) -> Bool {
        guard isHandedOff, UIApplication.shared.applicationState == .active,
              let presenter = dialogPresenter, presenter.presentedViewController == nil,
              presenter.viewIfLoaded?.window != nil else { return false }
        let alert = UIAlertController(title: PalmiL10n.tr("tool.facade.browser"), message: message, preferredStyle: .alert)
        if isPrompt { alert.addTextField { $0.text = defaultText } }
        var completed = false
        var timer: Task<Void, Never>?
        let finish: (String?) -> Void = { [weak self, weak alert] answer in
            guard !completed else { return }
            completed = true
            timer?.cancel()
            self?.dismissDialog = nil
            alert?.dismiss(animated: false)
            completion(answer)
        }
        alert.addAction(UIAlertAction(title: PalmiL10n.tr("common.ok"), style: .default) { [weak alert] _ in
            finish(isPrompt ? alert?.textFields?.first?.text ?? "" : "")
        })
        if cancellable { alert.addAction(UIAlertAction(title: PalmiL10n.tr("common.cancel"), style: .cancel) { _ in finish(nil) }) }
        dismissDialog = { finish(nil) }
        timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(60)); finish(nil) } catch { }
        }
        presenter.present(alert, animated: true)
        return true
    }

    /// iOS 27 起的网页定位授权：按用户一次性设置自动决定，不依赖系统弹窗（幕后窗口里的弹窗用户看不见）。
    @available(iOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        Task { @MainActor in
            decisionHandler(await BrowserGeolocation.shared.isAllowed() ? .grant : .deny)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !disposed else { return }
        currentNavigation = navigation
        ledger.invalidate()
        frameBridge.reset()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !disposed, navigation === currentNavigation else { return }
        navigationCompletion?(.success(()))
        navigationCompletion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === currentNavigation { navigationFailed(error) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === currentNavigation { navigationFailed(error) }
    }

    private func navigationFailed(_ error: Error) {
        // 被策略取消的请求已经记录为明确拦截，不覆盖它。
        let failure = error as NSError
        if !blockedMessages.isEmpty && (failure.code == NSURLErrorCancelled || (failure.domain == "WebKitErrorDomain" && failure.code == 102)) {
            navigationCompletion?(.success(()))
        } else {
            navigationError = error
            navigationCompletion?(.failure(error))
        }
        navigationCompletion = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        abort(BrowserToolError(code: "web_process_terminated", message: "网页进程已退出，请先 observe 或 reload。"))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard BrowserSafety.allowsNavigation(navigationAction.request.url), !navigationAction.shouldPerformDownload else {
            blockedMessages.append(navigationAction.shouldPerformDownload ? "已拦截下载。" : "已拦截非 http/https 导航。")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        guard BrowserSafety.allowsNavigation(navigationResponse.response.url),
              BrowserSafety.allowsResponse(isDownload: disposition.contains("attachment"), canShowMIMEType: navigationResponse.canShowMIMEType) else {
            blockedMessages.append("已拦截下载或不可显示的导航响应。")
            decisionHandler(.cancel)
            return
        }
        frameBridge.acceptPolicy(from: navigationResponse.response)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if BrowserSafety.allowsNavigation(navigationAction.request.url), !navigationAction.shouldPerformDownload {
            ledger.invalidate()
            webView.load(navigationAction.request)
        } else { blockedMessages.append("已拦截新窗口中的非 http/https 导航或下载。") }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        if showDialog(message: message, cancellable: false, completion: { _ in completionHandler() }) { return }
        blockedMessages.append("页面弹窗：\(BrowserObservation.line(message, limit: 160))")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        if showDialog(message: message, completion: { completionHandler($0 != nil) }) { return }
        blockedMessages.append("页面请求确认，请使用 handoff 让用户确认：\(BrowserObservation.line(message, limit: 160))")
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        if showDialog(message: prompt, defaultText: defaultText, isPrompt: true, completion: completionHandler) { return }
        blockedMessages.append("页面请求输入，请使用 handoff。")
        completionHandler(nil)
    }
}
